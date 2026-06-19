import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO, type PurchaseHistory } from "../db";
import { parseReceiptFromImage, matchReceiptItems } from "../ai";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

async function assertMember(env: Env, householdId: string, userId: string): Promise<boolean> {
  const row = await env.DB
    .prepare("SELECT id FROM household_members WHERE household_id = ? AND user_id = ?")
    .bind(householdId, userId)
    .first();
  return row !== null;
}

// POST /v1/receipts/scan
// OCR a receipt image and match line items against recent purchase history.
app.post("/scan", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{ household_id?: string; image_base64?: string; media_type?: string }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id || !body.image_base64) return c.json({ error: "missing_fields" }, 400);

  if (!(await assertMember(c.env, body.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  // Parse receipt with Claude Vision
  const receipt = await parseReceiptFromImage(c.env, body.image_base64, body.media_type);
  if (!receipt || receipt.line_items.length === 0) {
    return c.json({ error: "could_not_parse" }, 422);
  }

  // Fetch recent purchase history for this household (last 14 days)
  const cutoff = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();
  const { results: recentHistory } = await c.env.DB
    .prepare(
      `SELECT ph.id, ph.product_id, ph.quantity, ph.purchased_at, ph.price_paid,
              p.name as product_name
       FROM purchase_history ph
       JOIN products p ON ph.product_id = p.id
       WHERE ph.household_id = ? AND ph.purchased_at >= ?
       ORDER BY ph.purchased_at DESC`,
    )
    .bind(body.household_id, cutoff)
    .all<PurchaseHistory & { product_name: string }>();

  if (recentHistory.length === 0) {
    // No history to match against — return receipt items unmatched
    return c.json({
      store_name: receipt.store_name,
      total_amount: receipt.total_amount,
      matches: [],
      unmatched: receipt.line_items,
    });
  }

  // Ask Claude to match receipt line items → product names
  const descriptions = receipt.line_items.map((i) => i.description);
  const productNames = [...new Set(recentHistory.map((h) => h.product_name))];
  const matchMap = await matchReceiptItems(c.env, descriptions, productNames);

  const matches: {
    receipt_item: (typeof receipt.line_items)[0];
    purchase_history_id: string;
    product_name: string;
  }[] = [];
  const unmatched: (typeof receipt.line_items)[0][] = [];

  for (const lineItem of receipt.line_items) {
    const matchedProductName = matchMap[lineItem.description];
    if (matchedProductName) {
      // Find the most recent purchase_history entry for this product
      const historyEntry = recentHistory.find(
        (h) => h.product_name.toLowerCase() === matchedProductName.toLowerCase(),
      );
      if (historyEntry) {
        matches.push({
          receipt_item: lineItem,
          purchase_history_id: historyEntry.id,
          product_name: historyEntry.product_name,
        });
        continue;
      }
    }
    unmatched.push(lineItem);
  }

  return c.json({
    store_name: receipt.store_name,
    total_amount: receipt.total_amount,
    matches,
    unmatched,
  });
});

// POST /v1/receipts/confirm
// Records a receipt and saves price_paid on matched purchase_history rows.
app.post("/confirm", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{
      household_id?: string;
      store_name?: string;
      total_amount?: number;
      matches?: { purchase_history_id: string; price_paid: number }[];
    }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id) return c.json({ error: "missing_fields" }, 400);

  if (!(await assertMember(c.env, body.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const now = nowISO();
  const receiptId = crypto.randomUUID();

  await c.env.DB
    .prepare(
      `INSERT INTO receipts (id, household_id, scanned_at, store_name, total_amount)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(receiptId, body.household_id, now, body.store_name ?? null, body.total_amount ?? null)
    .run();

  if (Array.isArray(body.matches) && body.matches.length > 0) {
    await c.env.DB.batch(
      body.matches.map(({ purchase_history_id, price_paid }) =>
        c.env.DB
          .prepare(
            `UPDATE purchase_history
             SET price_paid = ?, currency = 'AUD'
             WHERE id = ? AND household_id = ?`,
          )
          .bind(price_paid, purchase_history_id, body.household_id),
      ),
    );
  }

  return c.json({ receipt_id: receiptId }, 201);
});

export default app;
