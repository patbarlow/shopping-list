import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO } from "../db";
import { parseReceiptFromImage, matchReceiptItems } from "../ai";
import { upsertProduct } from "./items";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

async function assertMember(env: Env, householdId: string, userId: string): Promise<boolean> {
  const row = await env.DB
    .prepare("SELECT id FROM household_members WHERE household_id = ? AND user_id = ?")
    .bind(householdId, userId)
    .first();
  return row !== null;
}

function normalizeReceiptDescription(s: string): string {
  return s
    .trim()
    .toLowerCase()
    .replace(/^(ww|woolworths|coles|aldi|iga|spc)\s+/i, "")
    .replace(/\s+/g, " ");
}

async function lookupAliases(
  db: D1Database,
  householdId: string,
  normalizedDescriptions: string[],
): Promise<Record<string, { product_id: string; product_name: string }>> {
  if (normalizedDescriptions.length === 0) return {};
  const placeholders = normalizedDescriptions.map(() => "?").join(", ");
  const { results } = await db
    .prepare(
      `SELECT pa.raw_description, pa.product_id, p.name AS product_name
       FROM product_aliases pa
       JOIN products p ON pa.product_id = p.id
       WHERE pa.household_id = ? AND pa.raw_description IN (${placeholders})`,
    )
    .bind(householdId, ...normalizedDescriptions)
    .all<{ raw_description: string; product_id: string; product_name: string }>();
  return Object.fromEntries(results.map((r) => [r.raw_description, { product_id: r.product_id, product_name: r.product_name }]));
}

function aliasUpsertStatement(
  db: D1Database,
  householdId: string,
  rawDescription: string,
  productId: string,
  now: string,
): D1PreparedStatement {
  const normalized = normalizeReceiptDescription(rawDescription);
  return db
    .prepare(
      `INSERT INTO product_aliases (id, household_id, raw_description, product_id, match_count, last_seen_at, created_at)
       VALUES (?, ?, ?, ?, 1, ?, ?)
       ON CONFLICT(household_id, raw_description)
       DO UPDATE SET product_id = excluded.product_id,
                     match_count = match_count + 1,
                     last_seen_at = excluded.last_seen_at`,
    )
    .bind(crypto.randomUUID(), householdId, normalized, productId, now, now);
}

// GET /v1/receipts/products — product search for the picker UI
app.get("/products", async (c) => {
  const householdId = c.req.query("household_id");
  const q = (c.req.query("q") ?? "").trim();
  if (!householdId) return c.json({ error: "missing_fields" }, 400);
  if (!(await assertMember(c.env, householdId, c.var.user.id))) return c.json({ error: "forbidden" }, 403);

  const { results } = await c.env.DB
    .prepare(
      `SELECT id, name, category FROM products
       WHERE household_id = ? AND LOWER(name) LIKE '%' || LOWER(?) || '%'
       ORDER BY name ASC LIMIT 20`,
    )
    .bind(householdId, q)
    .all<{ id: string; name: string; category: string }>();

  return c.json({ products: results });
});

// POST /v1/receipts/scan
app.post("/scan", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{ household_id?: string; image_base64?: string; media_type?: string }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id || !body.image_base64) return c.json({ error: "missing_fields" }, 400);
  if (!(await assertMember(c.env, body.household_id, user.id))) return c.json({ error: "forbidden" }, 403);

  const receipt = await parseReceiptFromImage(c.env, body.image_base64, body.media_type);
  if (!receipt || receipt.line_items.length === 0) return c.json({ error: "could_not_parse" }, 422);

  const descriptions = receipt.line_items.map((i) => i.description);
  const normalizedDescs = descriptions.map(normalizeReceiptDescription);

  // Stage 1 — alias lookup (zero AI cost)
  const aliasMap = await lookupAliases(c.env.DB, body.household_id, normalizedDescs);

  const aliasResolved = new Map<string, { product_id: string; product_name: string }>();
  const needsClaude: string[] = [];

  for (let i = 0; i < descriptions.length; i++) {
    const hit = aliasMap[normalizedDescs[i]];
    if (hit) {
      aliasResolved.set(descriptions[i], hit);
    } else {
      needsClaude.push(descriptions[i]);
    }
  }

  // Stage 2 — broadened product pool (all products, recency-ordered, no time cutoff)
  const { results: productPool } = await c.env.DB
    .prepare(
      `SELECT p.id, p.name, MAX(ph.purchased_at) AS last_purchased_at
       FROM products p
       LEFT JOIN purchase_history ph ON ph.product_id = p.id AND ph.household_id = ?
       WHERE p.household_id = ?
       GROUP BY p.id
       ORDER BY last_purchased_at DESC NULLS LAST, p.name ASC
       LIMIT 200`,
    )
    .bind(body.household_id, body.household_id)
    .all<{ id: string; name: string; last_purchased_at: string | null }>();

  // Fetch all unpriced purchase_history entries — these are "this week's" unchecked purchases
  const { results: unpricedHistory } = await c.env.DB
    .prepare(
      `SELECT ph.id, ph.product_id, p.name AS product_name
       FROM purchase_history ph
       JOIN products p ON ph.product_id = p.id
       WHERE ph.household_id = ? AND ph.price_paid IS NULL
       ORDER BY ph.purchased_at DESC`,
    )
    .bind(body.household_id)
    .all<{ id: string; product_id: string; product_name: string }>();

  // Map: product_id → most recent unpriced ph entry
  const phByProductId = new Map<string, { id: string; product_name: string }>();
  for (const ph of unpricedHistory) {
    if (!phByProductId.has(ph.product_id)) {
      phByProductId.set(ph.product_id, { id: ph.id, product_name: ph.product_name });
    }
  }

  // Stage 3 — Claude matching for unresolved items
  const claudeMatchMap: Record<string, string | null> = {};
  if (needsClaude.length > 0 && productPool.length > 0) {
    const productNames = productPool.map((p) => p.name);
    const raw = await matchReceiptItems(c.env, needsClaude, productNames);
    Object.assign(claudeMatchMap, raw);
  }

  // Build product name → id map for Claude results
  const nameToProductId = new Map(productPool.map((p) => [p.name.toLowerCase(), p.id]));

  // Assemble matches and unmatched
  const matches: {
    receipt_item: (typeof receipt.line_items)[0];
    purchase_history_id: string;
    product_id: string;
    product_name: string;
  }[] = [];
  const unmatched: (typeof receipt.line_items)[0][] = [];

  for (const lineItem of receipt.line_items) {
    const aliasHit = aliasResolved.get(lineItem.description);
    const claudeName = claudeMatchMap[lineItem.description];
    const claudeProductId = claudeName ? nameToProductId.get(claudeName.toLowerCase()) : undefined;

    const matchedProductId = aliasHit?.product_id ?? (claudeProductId || undefined);
    const matchedProductName = aliasHit?.product_name ?? claudeName ?? null;

    if (matchedProductId && matchedProductName) {
      const ph = phByProductId.get(matchedProductId);
      if (ph) {
        matches.push({
          receipt_item: lineItem,
          purchase_history_id: ph.id,
          product_id: matchedProductId,
          product_name: matchedProductName,
        });
        continue;
      }
    }
    unmatched.push(lineItem);
  }

  return c.json({
    store_name: receipt.store_name,
    total_amount: receipt.total_amount,
    receipt_date: receipt.receipt_date ?? null,
    matches,
    unmatched,
  });
});

type MatchConfirmItem = {
  purchase_history_id: string;
  price_paid: number;
  receipt_description?: string;
  product_id?: string;
};

type CorrectionItem = {
  receipt_description: string;
  product_id?: string;
  new_product_name?: string;
  price_paid: number;
};

type UnplannedItem = {
  receipt_description: string;
  product_id?: string;
  new_product_name?: string;
  price_paid: number;
  quantity?: string;
};

// POST /v1/receipts/confirm
app.post("/confirm", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{
      household_id?: string;
      store_name?: string;
      total_amount?: number;
      receipt_date?: string;
      matches?: MatchConfirmItem[];
      corrections?: CorrectionItem[];
      unplanned?: UnplannedItem[];
    }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id) return c.json({ error: "missing_fields" }, 400);
  if (!(await assertMember(c.env, body.household_id, user.id))) return c.json({ error: "forbidden" }, 403);

  const now = nowISO();
  const receiptId = crypto.randomUUID();
  const purchasedAt = body.receipt_date ?? now.slice(0, 10);

  // Resolve products for unplanned items (may call AI for new products)
  type ResolvedUnplanned = UnplannedItem & { productId: string; isNew: boolean };
  const resolvedUnplanned: ResolvedUnplanned[] = [];
  for (const u of body.unplanned ?? []) {
    if (u.product_id) {
      resolvedUnplanned.push({ ...u, productId: u.product_id, isNew: false });
    } else if (u.new_product_name?.trim()) {
      const product = await upsertProduct(c.env, body.household_id, u.new_product_name.trim());
      resolvedUnplanned.push({ ...u, productId: product.id, isNew: true });
    }
  }

  // Resolve products for corrections (may call AI for new products)
  type ResolvedCorrection = CorrectionItem & { productId: string };
  const resolvedCorrections: ResolvedCorrection[] = [];
  for (const corr of body.corrections ?? []) {
    if (corr.product_id) {
      resolvedCorrections.push({ ...corr, productId: corr.product_id });
    } else if (corr.new_product_name?.trim()) {
      const product = await upsertProduct(c.env, body.household_id, corr.new_product_name.trim());
      resolvedCorrections.push({ ...corr, productId: product.id });
    }
  }

  // For each correction, find the most recent purchase_history entry for the correct product
  type CorrectionWithPh = ResolvedCorrection & { phId: string; phIsNew: boolean };
  const correctionsWithPh: CorrectionWithPh[] = await Promise.all(
    resolvedCorrections.map(async (corr) => {
      const existing = await c.env.DB
        .prepare(
          `SELECT id FROM purchase_history
           WHERE household_id = ? AND product_id = ?
           ORDER BY (price_paid IS NULL) DESC, purchased_at DESC LIMIT 1`,
        )
        .bind(body.household_id, corr.productId)
        .first<{ id: string }>();
      return { ...corr, phId: existing?.id ?? crypto.randomUUID(), phIsNew: !existing };
    }),
  );

  // Build batch statements
  const statements: D1PreparedStatement[] = [];

  // Insert receipt row
  statements.push(
    c.env.DB.prepare(
      `INSERT INTO receipts (id, household_id, scanned_at, receipt_date, store_name, total_amount, currency)
       VALUES (?, ?, ?, ?, ?, ?, 'AUD')`,
    ).bind(receiptId, body.household_id, now, body.receipt_date ?? null, body.store_name ?? null, body.total_amount ?? null),
  );

  // Process confirmed matches
  for (const match of body.matches ?? []) {
    statements.push(
      c.env.DB.prepare(
        `UPDATE purchase_history SET price_paid = ?, currency = 'AUD', source = 'receipt_match'
         WHERE id = ? AND household_id = ?`,
      ).bind(match.price_paid, match.purchase_history_id, body.household_id),
    );
    if (match.receipt_description && match.product_id) {
      statements.push(
        aliasUpsertStatement(c.env.DB, body.household_id, match.receipt_description, match.product_id, now),
      );
    }
    statements.push(
      c.env.DB.prepare(
        `INSERT INTO receipt_line_items (id, receipt_id, household_id, raw_description, total_price, product_id, match_source, confirmed, purchase_history_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, 'ai', 1, ?, ?)`,
      ).bind(
        crypto.randomUUID(), receiptId, body.household_id,
        match.receipt_description ?? "", match.price_paid, match.product_id ?? null,
        match.purchase_history_id, now,
      ),
    );
  }

  // Process corrections
  for (const corr of correctionsWithPh) {
    statements.push(aliasUpsertStatement(c.env.DB, body.household_id, corr.receipt_description, corr.productId, now));

    if (corr.phIsNew) {
      statements.push(
        c.env.DB.prepare(
          `INSERT INTO purchase_history (id, household_id, product_id, quantity, purchased_by, purchased_at, price_paid, currency, source)
           VALUES (?, ?, ?, NULL, ?, ?, ?, 'AUD', 'receipt_match')`,
        ).bind(corr.phId, body.household_id, corr.productId, user.id, purchasedAt, corr.price_paid),
      );
    } else {
      statements.push(
        c.env.DB.prepare(
          `UPDATE purchase_history SET price_paid = ?, currency = 'AUD', source = 'receipt_match' WHERE id = ?`,
        ).bind(corr.price_paid, corr.phId),
      );
    }

    statements.push(
      c.env.DB.prepare(
        `INSERT INTO receipt_line_items (id, receipt_id, household_id, raw_description, total_price, product_id, match_source, confirmed, purchase_history_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, 'manual', 1, ?, ?)`,
      ).bind(crypto.randomUUID(), receiptId, body.household_id, corr.receipt_description, corr.price_paid, corr.productId, corr.phId, now),
    );
  }

  // Process unplanned purchases
  for (const u of resolvedUnplanned) {
    const phId = crypto.randomUUID();
    statements.push(
      c.env.DB.prepare(
        `INSERT INTO purchase_history (id, household_id, product_id, quantity, purchased_by, purchased_at, price_paid, currency, source)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'AUD', 'receipt_unplanned')`,
      ).bind(phId, body.household_id, u.productId, u.quantity ?? null, user.id, purchasedAt, u.price_paid),
    );
    statements.push(aliasUpsertStatement(c.env.DB, body.household_id, u.receipt_description, u.productId, now));
    statements.push(
      c.env.DB.prepare(
        `INSERT INTO receipt_line_items (id, receipt_id, household_id, raw_description, total_price, product_id, match_source, confirmed, purchase_history_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
      ).bind(
        crypto.randomUUID(), receiptId, body.household_id, u.receipt_description, u.price_paid, u.productId,
        u.isNew ? "unplanned_new" : "unplanned_existing", phId, now,
      ),
    );
  }

  // Execute in chunks (D1 batch limit is 100 statements)
  for (let i = 0; i < statements.length; i += 100) {
    await c.env.DB.batch(statements.slice(i, i + 100));
  }

  return c.json({ receipt_id: receiptId }, 201);
});

export default app;
