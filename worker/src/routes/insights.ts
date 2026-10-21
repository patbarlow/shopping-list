import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { SHOPPING_FREQUENCY_DAYS, type Household } from "../db";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

async function assertMember(env: Env, householdId: string, userId: string): Promise<boolean> {
  const row = await env.DB
    .prepare("SELECT id FROM household_members WHERE household_id = ? AND user_id = ?")
    .bind(householdId, userId)
    .first();
  return row !== null;
}

// GET /v1/insights?household_id=xxx
app.get("/", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);

  if (!(await assertMember(c.env, householdId, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  // Most frequently purchased products
  const { results: frequently_purchased } = await c.env.DB
    .prepare(
      `SELECT p.name as product_name,
              p.category,
              COUNT(ph.id) as purchase_count,
              AVG(ph.price_paid) as avg_price,
              MAX(ph.purchased_at) as last_purchased_at
       FROM purchase_history ph
       JOIN products p ON ph.product_id = p.id
       WHERE ph.household_id = ?
       GROUP BY ph.product_id
       ORDER BY purchase_count DESC
       LIMIT 20`,
    )
    .bind(householdId)
    .all<{
      product_name: string;
      category: string;
      purchase_count: number;
      avg_price: number | null;
      last_purchased_at: string;
    }>();

  // Recent recipes
  const { results: recent_recipes } = await c.env.DB
    .prepare(
      `SELECT r.id, r.name, r.source_url, r.default_servings, r.created_at,
              COUNT(ri.id) as ingredient_count
       FROM recipes r
       LEFT JOIN recipe_ingredients ri ON ri.recipe_id = r.id
       WHERE r.household_id = ?
       GROUP BY r.id
       ORDER BY r.created_at DESC
       LIMIT 10`,
    )
    .bind(householdId)
    .all<{
      id: string;
      name: string;
      source_url: string | null;
      default_servings: number | null;
      created_at: string;
      ingredient_count: number;
    }>();

  return c.json({ frequently_purchased, recent_recipes });
});

// GET /v1/insights/history/days?household_id=xxx
app.get("/history/days", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const { results } = await c.env.DB
    .prepare(
      `SELECT DATE(purchased_at) AS date, COUNT(*) AS item_count
       FROM purchase_history
       WHERE household_id = ?
       GROUP BY date
       ORDER BY date DESC
       LIMIT 90`,
    )
    .bind(householdId)
    .all<{ date: string; item_count: number }>();

  return c.json({ days: results });
});

// GET /v1/insights/history/day/:date?household_id=xxx
app.get("/history/day/:date", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  const date = c.req.param("date");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const { results } = await c.env.DB
    .prepare(
      `SELECT ph.id,
              p.name        AS product_name,
              ph.quantity,
              p.category,
              p.aisle_order,
              ph.purchased_at,
              ph.price_paid
       FROM purchase_history ph
       JOIN products p ON ph.product_id = p.id
       WHERE ph.household_id = ? AND DATE(ph.purchased_at) = ?
       ORDER BY p.aisle_order, p.name`,
    )
    .bind(householdId, date)
    .all<{
      id: string;
      product_name: string;
      quantity: string | null;
      category: string;
      aisle_order: number;
      purchased_at: string;
      price_paid: number | null;
    }>();

  return c.json({ date, items: results });
});

// Only purchases that came from a scanned receipt count toward product insights —
// ticking items off the shopping list (source 'manual') is excluded by design.
const RECEIPT_SOURCE = "ph.source LIKE 'receipt%'";

// Typical gap between shopping trips for a product, in days. Multiple line
// items (e.g. two chip flavours) bought on the same trip are one purchase
// occasion, not two — dedupe to distinct calendar days first so the interval
// reflects trip frequency rather than items-per-trip.
function avgIntervalFromDates(purchasedAts: string[]): { avgIntervalDays: number | null; distinctDays: string[] } {
  const distinctDays = Array.from(new Set(purchasedAts.filter(Boolean).map((d) => d.slice(0, 10)))).sort();
  let avgIntervalDays: number | null = null;
  if (distinctDays.length >= 2) {
    const first = Date.parse(distinctDays[0]);
    const last = Date.parse(distinctDays[distinctDays.length - 1]);
    if (!Number.isNaN(first) && !Number.isNaN(last) && last > first) {
      avgIntervalDays = Math.round((last - first) / 86_400_000 / (distinctDays.length - 1));
    }
  }
  return { avgIntervalDays, distinctDays };
}

// A baseline price ($/100g or $/100mL) so different pack sizes of the same
// product can be compared on value, the way supermarket shelf tags do.
function unitPriceFor(input: {
  pricePaid: number | null;
  quantity: number | null;
  unitPrice: number | null;
  sizeValue: number | null;
  sizeUnit: string | null;
}): { value: number; unit: "100g" | "100mL" } | null {
  // Packaged goods with a printed size: derive the baseline from what was
  // actually paid. Receipts often put a per-each or pre-discount figure in
  // unit_price ("2 for $5" prints 5), so it can't be trusted when a size is known.
  if (input.pricePaid != null && input.sizeValue && input.sizeUnit) {
    const qty = input.quantity && input.quantity > 0 ? input.quantity : 1;
    const perPackage = input.pricePaid / qty;
    const unit = input.sizeUnit.trim().toLowerCase();
    if (unit === "g" || unit === "gm") return { value: (perPackage / input.sizeValue) * 100, unit: "100g" };
    if (unit === "kg") return { value: (perPackage / (input.sizeValue * 1000)) * 100, unit: "100g" };
    if (unit === "ml") return { value: (perPackage / input.sizeValue) * 100, unit: "100mL" };
    if (unit === "l" || unit === "lt" || unit === "ltr") return { value: (perPackage / (input.sizeValue * 1000)) * 100, unit: "100mL" };
    return null;
  }

  // No printed size: unit_price is only a $/kg rate when the item was weighed,
  // which shows up as a fractional quantity (0.227 onions). An integer quantity
  // means unit_price is a per-each price (packs, catchweight lines where it
  // just mirrors the total) — no size, no comparable baseline.
  if (
    input.unitPrice != null && input.unitPrice > 0 &&
    input.quantity != null && input.quantity > 0 && !Number.isInteger(input.quantity)
  ) {
    return { value: input.unitPrice / 10, unit: "100g" };
  }
  return null;
}

// GET /v1/insights/products?household_id=xxx — every product you've bought on a receipt, with stats
app.get("/products", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const { results } = await c.env.DB
    .prepare(
      `SELECT p.id, p.name, p.category, p.aisle_order,
              COUNT(ph.id)        AS times_purchased,
              AVG(ph.price_paid)  AS avg_price,
              SUM(ph.price_paid)  AS total_spend,
              MAX(ph.purchased_at) AS last_purchased_at,
              (SELECT ph2.price_paid FROM purchase_history ph2
               WHERE ph2.product_id = p.id AND ph2.household_id = ?
                 AND ph2.source LIKE 'receipt%' AND ph2.price_paid IS NOT NULL
               ORDER BY ph2.purchased_at DESC LIMIT 1) AS last_price
       FROM products p
       JOIN purchase_history ph
         ON ph.product_id = p.id AND ph.household_id = ? AND ${RECEIPT_SOURCE}
       WHERE p.household_id = ?
       GROUP BY p.id
       ORDER BY times_purchased DESC, total_spend DESC, p.name ASC`,
    )
    .bind(householdId, householdId, householdId)
    .all<{
      id: string;
      name: string;
      category: string;
      aisle_order: number;
      times_purchased: number;
      avg_price: number | null;
      total_spend: number | null;
      last_purchased_at: string;
      last_price: number | null;
    }>();

  // A $/100g or $/100mL baseline per product — the shelf-tag-style figure
  // that's actually useful for "is this a good price" while standing in the
  // aisle, since it's comparable across pack sizes. Same unitPriceFor() logic
  // as the per-product detail route, aggregated across every line item.
  const { results: lineItems } = await c.env.DB
    .prepare(
      `SELECT ph.product_id, ph.price_paid,
              rli.quantity AS rli_quantity, rli.unit_price AS rli_unit_price,
              rli.size_value AS rli_size_value, rli.size_unit AS rli_size_unit
       FROM purchase_history ph
       JOIN receipt_line_items rli ON rli.purchase_history_id = ph.id
       WHERE ph.household_id = ? AND ${RECEIPT_SOURCE}`,
    )
    .bind(householdId)
    .all<{
      product_id: string;
      price_paid: number | null;
      rli_quantity: number | null;
      rli_unit_price: number | null;
      rli_size_value: number | null;
      rli_size_unit: string | null;
    }>();

  const unitPriceByProduct = new Map<string, { sum: number; count: number; unit: "100g" | "100mL" }>();
  for (const row of lineItems) {
    const unitPrice = unitPriceFor({
      pricePaid: row.price_paid,
      quantity: row.rli_quantity,
      unitPrice: row.rli_unit_price,
      sizeValue: row.rli_size_value,
      sizeUnit: row.rli_size_unit,
    });
    if (!unitPrice) continue;
    const existing = unitPriceByProduct.get(row.product_id);
    if (!existing) {
      unitPriceByProduct.set(row.product_id, { sum: unitPrice.value, count: 1, unit: unitPrice.unit });
    } else if (existing.unit === unitPrice.unit) {
      existing.sum += unitPrice.value;
      existing.count += 1;
    }
  }

  const productsWithUnitPrice = results.map((p) => {
    const agg = unitPriceByProduct.get(p.id);
    return {
      ...p,
      avg_unit_price: agg ? agg.sum / agg.count : null,
      avg_unit_price_unit: agg?.unit ?? null,
    };
  });

  return c.json({ products: productsWithUnitPrice });
});

// GET /v1/insights/products/:id?household_id=xxx — one product's stats + full purchase log
app.get("/products/:id", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  const productId = c.req.param("id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const product = await c.env.DB
    .prepare(`SELECT id, name, category FROM products WHERE id = ? AND household_id = ?`)
    .bind(productId, householdId)
    .first<{ id: string; name: string; category: string }>();
  if (!product) return c.json({ error: "not_found" }, 404);

  // Each receipt purchase, newest first, with the actual variant bought and the store.
  const { results: rawPurchases } = await c.env.DB
    .prepare(
      `SELECT ph.id, ph.purchased_at, ph.price_paid, ph.quantity,
              rli.raw_description AS variant,
              rli.quantity        AS rli_quantity,
              rli.unit_price      AS rli_unit_price,
              rli.size_value      AS rli_size_value,
              rli.size_unit       AS rli_size_unit,
              r.store_name        AS store_name
       FROM purchase_history ph
       LEFT JOIN receipt_line_items rli ON rli.purchase_history_id = ph.id
       LEFT JOIN receipts r ON r.id = rli.receipt_id
       WHERE ph.household_id = ? AND ph.product_id = ? AND ${RECEIPT_SOURCE}
       ORDER BY ph.purchased_at DESC, ph.id DESC`,
    )
    .bind(householdId, productId)
    .all<{
      id: string;
      purchased_at: string;
      price_paid: number | null;
      quantity: string | null;
      variant: string | null;
      rli_quantity: number | null;
      rli_unit_price: number | null;
      rli_size_value: number | null;
      rli_size_unit: string | null;
      store_name: string | null;
    }>();

  const purchases = rawPurchases.map((p) => {
    const unitPrice = unitPriceFor({
      pricePaid: p.price_paid,
      quantity: p.rli_quantity,
      unitPrice: p.rli_unit_price,
      sizeValue: p.rli_size_value,
      sizeUnit: p.rli_size_unit,
    });
    return {
      id: p.id,
      purchased_at: p.purchased_at,
      price_paid: p.price_paid,
      quantity: p.quantity,
      variant: p.variant,
      store_name: p.store_name,
      unit_price: unitPrice?.value ?? null,
      unit_price_unit: unitPrice?.unit ?? null,
    };
  });

  // Aggregate stats. avg_interval_days is the typical gap between purchases —
  // groundwork for future "you usually buy this every N days" suggestions.
  const prices = purchases.map((p) => p.price_paid).filter((v): v is number => v != null);
  const dates = purchases.map((p) => p.purchased_at).filter(Boolean).sort();
  const totalSpend = prices.reduce((a, b) => a + b, 0);
  const { avgIntervalDays } = avgIntervalFromDates(dates);

  return c.json({
    product,
    stats: {
      times_purchased: purchases.length,
      avg_price: prices.length ? totalSpend / prices.length : null,
      total_spend: prices.length ? totalSpend : null,
      min_price: prices.length ? Math.min(...prices) : null,
      max_price: prices.length ? Math.max(...prices) : null,
      first_purchased_at: dates[0] ?? null,
      last_purchased_at: dates[dates.length - 1] ?? null,
      avg_interval_days: avgIntervalDays,
    },
    purchases,
  });
});

// GET /v1/insights/trips?household_id=xxx — every scanned receipt as a shopping
// trip, plus per-day category spend. Range filtering happens client-side; the
// dataset is one row per receipt, so it stays tiny.
app.get("/trips", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const { results: trips } = await c.env.DB
    .prepare(
      `SELECT r.id,
              COALESCE(r.receipt_date, DATE(r.scanned_at)) AS date,
              r.store_name,
              r.total_amount,
              (SELECT COUNT(*) FROM receipt_line_items rli WHERE rli.receipt_id = r.id) AS item_count
       FROM receipts r
       WHERE r.household_id = ?
       ORDER BY date ASC`,
    )
    .bind(householdId)
    .all<{ id: string; date: string; store_name: string | null; total_amount: number | null; item_count: number }>();

  const { results: category_spend } = await c.env.DB
    .prepare(
      `SELECT DATE(ph.purchased_at) AS date, p.category, SUM(ph.price_paid) AS total
       FROM purchase_history ph
       JOIN products p ON ph.product_id = p.id
       WHERE ph.household_id = ? AND ${RECEIPT_SOURCE} AND ph.price_paid IS NOT NULL
       GROUP BY DATE(ph.purchased_at), p.category
       ORDER BY date ASC`,
    )
    .bind(householdId)
    .all<{ date: string; category: string; total: number }>();

  return c.json({ trips, category_spend });
});

// GET /v1/insights/receipts/:id?household_id=xxx — one scanned receipt's line
// items, in scan order, for a receipt-style detail view of that trip.
app.get("/receipts/:id", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  const receiptId = c.req.param("id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const receipt = await c.env.DB
    .prepare(
      `SELECT id, COALESCE(receipt_date, DATE(scanned_at)) AS date, store_name, total_amount
       FROM receipts WHERE id = ? AND household_id = ?`,
    )
    .bind(receiptId, householdId)
    .first<{ id: string; date: string; store_name: string | null; total_amount: number | null }>();
  if (!receipt) return c.json({ error: "not_found" }, 404);

  const { results: items } = await c.env.DB
    .prepare(
      `SELECT id, raw_description, quantity, total_price
       FROM receipt_line_items
       WHERE receipt_id = ? AND household_id = ?
       ORDER BY created_at ASC, rowid ASC`,
    )
    .bind(receiptId, householdId)
    .all<{ id: string; raw_description: string; quantity: number | null; total_price: number | null }>();

  return c.json({ receipt, items });
});

// PATCH /v1/insights/products/:id — rename a product. If the new name matches
// another product in the household, the two are merged: all history moves to
// the existing product and the renamed one is deleted.
app.patch("/products/:id", async (c) => {
  const user = c.var.user;
  const productId = c.req.param("id");
  const body = await c.req.json<{ household_id?: string; name?: string }>().catch(() => ({}) as { household_id?: string; name?: string });
  const householdId = body.household_id;
  const name = body.name?.trim();
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!name) return c.json({ error: "missing_name" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const product = await c.env.DB
    .prepare(`SELECT id, name, category FROM products WHERE id = ? AND household_id = ?`)
    .bind(productId, householdId)
    .first<{ id: string; name: string; category: string }>();
  if (!product) return c.json({ error: "not_found" }, 404);

  const now = new Date().toISOString();

  // products.name is COLLATE NOCASE + UNIQUE per household, so a case-insensitive
  // clash means merge rather than rename.
  const existing = await c.env.DB
    .prepare(`SELECT id, name, category FROM products WHERE household_id = ? AND name = ? AND id != ?`)
    .bind(householdId, name, productId)
    .first<{ id: string; name: string; category: string }>();

  if (existing) {
    await c.env.DB.batch([
      c.env.DB.prepare(`UPDATE purchase_history SET product_id = ? WHERE product_id = ?`).bind(existing.id, productId),
      c.env.DB.prepare(`UPDATE receipt_line_items SET product_id = ? WHERE product_id = ?`).bind(existing.id, productId),
      c.env.DB.prepare(`UPDATE shopping_items SET product_id = ? WHERE product_id = ?`).bind(existing.id, productId),
      c.env.DB.prepare(`UPDATE recipe_ingredients SET product_id = ? WHERE product_id = ?`).bind(existing.id, productId),
      c.env.DB.prepare(`DELETE FROM products WHERE id = ?`).bind(productId),
      c.env.DB.prepare(`UPDATE products SET updated_at = ? WHERE id = ?`).bind(now, existing.id),
    ]);
    return c.json({ product: existing, merged: true });
  }

  await c.env.DB
    .prepare(`UPDATE products SET name = ?, updated_at = ? WHERE id = ?`)
    .bind(name, now, productId)
    .run();
  return c.json({ product: { id: product.id, name, category: product.category }, merged: false });
});

// Minimum number of distinct shopping trips before a product's cadence is
// considered reliable enough to predict from.
const MIN_OCCASIONS_FOR_PREDICTION = 3;

// GET /v1/insights/predictions?household_id=xxx — items likely due before the
// household's next big shop, sized by their shopping_frequency setting.
app.get("/predictions", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);
  if (!(await assertMember(c.env, householdId, user.id))) return c.json({ error: "forbidden" }, 403);

  const household = await c.env.DB
    .prepare("SELECT * FROM households WHERE id = ?")
    .bind(householdId)
    .first<Household>();
  const horizonDays = SHOPPING_FREQUENCY_DAYS[household?.shopping_frequency ?? "weekly"] ?? 7;

  const { results: rows } = await c.env.DB
    .prepare(
      `SELECT p.id, p.name, p.category, ph.purchased_at, ph.price_paid
       FROM purchase_history ph
       JOIN products p ON ph.product_id = p.id
       WHERE ph.household_id = ? AND ${RECEIPT_SOURCE}
       ORDER BY p.id, ph.purchased_at`,
    )
    .bind(householdId)
    .all<{ id: string; name: string; category: string; purchased_at: string; price_paid: number | null }>();

  const byProduct = new Map<string, { name: string; category: string; purchasedAt: string[]; prices: number[] }>();
  for (const row of rows) {
    let group = byProduct.get(row.id);
    if (!group) {
      group = { name: row.name, category: row.category, purchasedAt: [], prices: [] };
      byProduct.set(row.id, group);
    }
    group.purchasedAt.push(row.purchased_at);
    if (row.price_paid != null) group.prices.push(row.price_paid);
  }

  const todayMs = Date.parse(new Date().toISOString().slice(0, 10));

  // "Weekly" is anchored to a Monday–Sunday calendar week (through Sunday)
  // rather than a rolling 7 days, so a weekend shopper always sees the full
  // week ahead regardless of which day they happen to check the forecast.
  let horizonEnd: number;
  if ((household?.shopping_frequency ?? "weekly") === "weekly") {
    const isoWeekday = new Date(todayMs).getUTCDay() || 7; // Sun(0) -> 7
    const daysUntilSunday = 7 - isoWeekday;
    horizonEnd = todayMs + daysUntilSunday * 86_400_000;
  } else {
    horizonEnd = todayMs + horizonDays * 86_400_000;
  }

  const items: {
    product_id: string;
    name: string;
    category: string;
    predicted_date: string;
    predicted_price: number | null;
    avg_interval_days: number;
    times_purchased: number;
    last_purchased_at: string;
  }[] = [];

  for (const [productId, group] of byProduct) {
    const { avgIntervalDays, distinctDays } = avgIntervalFromDates(group.purchasedAt);
    if (avgIntervalDays == null || distinctDays.length < MIN_OCCASIONS_FOR_PREDICTION) continue;

    const lastDay = distinctDays[distinctDays.length - 1];
    const predictedMs = Date.parse(lastDay) + avgIntervalDays * 86_400_000;
    if (predictedMs > horizonEnd) continue;

    items.push({
      product_id: productId,
      name: group.name,
      category: group.category,
      predicted_date: new Date(predictedMs).toISOString().slice(0, 10),
      predicted_price: group.prices.length ? group.prices.reduce((a, b) => a + b, 0) / group.prices.length : null,
      avg_interval_days: avgIntervalDays,
      times_purchased: group.purchasedAt.length,
      last_purchased_at: lastDay,
    });
  }

  items.sort((a, b) => a.predicted_date.localeCompare(b.predicted_date));
  const predictedTotal = items.reduce((sum, item) => sum + (item.predicted_price ?? 0), 0);

  return c.json({
    range: { start: new Date(todayMs).toISOString().slice(0, 10), end: new Date(horizonEnd).toISOString().slice(0, 10) },
    items,
    predicted_total: predictedTotal,
  });
});

export default app;
