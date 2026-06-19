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

export default app;
