import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO } from "../db";
import { parseReceiptFromImage, resolveReceiptItems } from "../ai";
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

  // Stage 1 — alias lookup (zero AI cost): descriptions we've matched before resolve instantly.
  const aliasMap = await lookupAliases(c.env.DB, body.household_id, normalizedDescs);
  const aliasResolved = new Map<string, { product_id: string; product_name: string }>();
  const needsResolve: string[] = [];
  for (let i = 0; i < descriptions.length; i++) {
    const hit = aliasMap[normalizedDescs[i]];
    if (hit) aliasResolved.set(descriptions[i], hit);
    else needsResolve.push(descriptions[i]);
  }

  // The full product catalogue (recency-ordered) is the pool we match against.
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
  const nameToProductId = new Map(productPool.map((p) => [p.name.toLowerCase(), p.id]));

  // Unpriced purchase_history rows are "things ticked off the list but not yet priced".
  // If a matched product has one, we offer to backfill its price instead of inserting a duplicate.
  const { results: unpricedHistory } = await c.env.DB
    .prepare(
      `SELECT ph.id, ph.product_id
       FROM purchase_history ph
       WHERE ph.household_id = ? AND ph.price_paid IS NULL
       ORDER BY ph.purchased_at DESC`,
    )
    .bind(body.household_id)
    .all<{ id: string; product_id: string }>();
  const phByProductId = new Map<string, string>();
  for (const ph of unpricedHistory) {
    if (!phByProductId.has(ph.product_id)) phByProductId.set(ph.product_id, ph.id);
  }

  // Resolve everything not already pinned by an alias: existing-match + clean name in one call.
  const resolved = await resolveReceiptItems(c.env, needsResolve, productPool.map((p) => p.name));

  // Assemble one proposed action per receipt line.
  const items = receipt.line_items.map((lineItem) => {
    const aliasHit = aliasResolved.get(lineItem.description);
    let productId: string | null = aliasHit?.product_id ?? null;
    let productName: string = aliasHit?.product_name ?? "";

    if (!productId) {
      const r = resolved[lineItem.description];
      if (r?.existingName) {
        productId = nameToProductId.get(r.existingName.toLowerCase()) ?? null;
        productName = r.existingName;
      }
      if (!productName) productName = r?.cleanName ?? lineItem.description;
    }

    return {
      description: lineItem.description,
      quantity: lineItem.quantity,
      unit_price: lineItem.unit_price,
      total_price: lineItem.total_price,
      product_id: productId,
      product_name: productName,
      is_new: productId === null,
      purchase_history_id: productId ? phByProductId.get(productId) ?? null : null,
    };
  });

  return c.json({
    store_name: receipt.store_name,
    total_amount: receipt.total_amount,
    receipt_date: receipt.receipt_date ?? null,
    items,
  });
});

// One reviewed receipt line the client wants to save.
type ConfirmItem = {
  receipt_description: string;
  /** Link to this existing product… */
  product_id?: string;
  /** …or create a new product with this clean name. Exactly one of the two is set. */
  new_product_name?: string;
  quantity?: string | number | null;
  price_paid?: number | null;
  /** If set, backfill this already-existing (unpriced) purchase_history row instead of inserting. */
  purchase_history_id?: string | null;
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
      items?: ConfirmItem[];
    }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id) return c.json({ error: "missing_fields" }, 400);
  if (!(await assertMember(c.env, body.household_id, user.id))) return c.json({ error: "forbidden" }, 403);

  const now = nowISO();
  const receiptId = crypto.randomUUID();
  const purchasedAt = body.receipt_date ?? now.slice(0, 10);

  // Resolve each item to a concrete product id, creating new products (clean-named) as needed.
  // upsertProduct may call AI, so do this before building the batch.
  type Resolved = ConfirmItem & { productId: string; isNew: boolean };
  const resolvedItems: Resolved[] = [];
  for (const item of body.items ?? []) {
    if (item.product_id) {
      resolvedItems.push({ ...item, productId: item.product_id, isNew: false });
    } else if (item.new_product_name?.trim()) {
      const product = await upsertProduct(c.env, body.household_id, item.new_product_name.trim());
      resolvedItems.push({ ...item, productId: product.id, isNew: true });
    }
  }

  const statements: D1PreparedStatement[] = [];

  statements.push(
    c.env.DB.prepare(
      `INSERT INTO receipts (id, household_id, scanned_at, receipt_date, store_name, total_amount, currency)
       VALUES (?, ?, ?, ?, ?, ?, 'AUD')`,
    ).bind(receiptId, body.household_id, now, body.receipt_date ?? null, body.store_name ?? null, body.total_amount ?? null),
  );

  for (const item of resolvedItems) {
    const price = item.price_paid ?? null;
    const quantity = item.quantity == null ? null : String(item.quantity);

    // Either backfill an existing unpriced purchase, or record a fresh one.
    let phId: string;
    if (item.purchase_history_id) {
      phId = item.purchase_history_id;
      statements.push(
        c.env.DB.prepare(
          `UPDATE purchase_history SET price_paid = ?, currency = 'AUD', source = 'receipt_import'
           WHERE id = ? AND household_id = ?`,
        ).bind(price, phId, body.household_id),
      );
    } else {
      phId = crypto.randomUUID();
      statements.push(
        c.env.DB.prepare(
          `INSERT INTO purchase_history (id, household_id, product_id, quantity, purchased_by, purchased_at, price_paid, currency, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'AUD', 'receipt_import')`,
        ).bind(phId, body.household_id, item.productId, quantity, user.id, purchasedAt, price),
      );
    }

    // Learn the raw-description → product mapping so next time it matches instantly.
    statements.push(aliasUpsertStatement(c.env.DB, body.household_id, item.receipt_description, item.productId, now));

    statements.push(
      c.env.DB.prepare(
        `INSERT INTO receipt_line_items (id, receipt_id, household_id, raw_description, quantity, total_price, product_id, match_source, confirmed, purchase_history_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
      ).bind(
        crypto.randomUUID(), receiptId, body.household_id, item.receipt_description,
        quantity, price, item.productId, item.isNew ? "new" : "existing", phId, now,
      ),
    );
  }

  // Execute in chunks (D1 batch limit is 100 statements)
  for (let i = 0; i < statements.length; i += 100) {
    await c.env.DB.batch(statements.slice(i, i + 100));
  }

  return c.json({ receipt_id: receiptId, saved: resolvedItems.length }, 201);
});

export default app;
