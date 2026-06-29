import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";

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
              MAX(ph.purchased_at) AS last_purchased_at
       FROM products p
       JOIN purchase_history ph
         ON ph.product_id = p.id AND ph.household_id = ? AND ${RECEIPT_SOURCE}
       WHERE p.household_id = ?
       GROUP BY p.id
       ORDER BY times_purchased DESC, total_spend DESC, p.name ASC`,
    )
    .bind(householdId, householdId)
    .all<{
      id: string;
      name: string;
      category: string;
      aisle_order: number;
      times_purchased: number;
      avg_price: number | null;
      total_spend: number | null;
      last_purchased_at: string;
    }>();

  return c.json({ products: results });
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
  const { results: purchases } = await c.env.DB
    .prepare(
      `SELECT ph.id, ph.purchased_at, ph.price_paid, ph.quantity,
              rli.raw_description AS variant,
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
      store_name: string | null;
    }>();

  // Aggregate stats. avg_interval_days is the typical gap between purchases —
  // groundwork for future "you usually buy this every N days" suggestions.
  const prices = purchases.map((p) => p.price_paid).filter((v): v is number => v != null);
  const dates = purchases.map((p) => p.purchased_at).filter(Boolean).sort();
  const totalSpend = prices.reduce((a, b) => a + b, 0);
  let avgIntervalDays: number | null = null;
  if (dates.length >= 2) {
    const first = Date.parse(dates[0]);
    const last = Date.parse(dates[dates.length - 1]);
    if (!Number.isNaN(first) && !Number.isNaN(last) && last > first) {
      avgIntervalDays = Math.round((last - first) / 86_400_000 / (dates.length - 1));
    }
  }

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

export default app;
