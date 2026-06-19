import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO, type ShoppingItem, type Product } from "../db";
import { categorise, findMatchingProduct } from "../ai";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

// SQLite stores booleans as 0/1 integers; convert to JSON boolean for Swift
function toResponse(item: ShoppingItem): object {
  return { ...item, checked: item.checked === 1 };
}

async function broadcastToHousehold(
  env: Env,
  householdId: string,
  action: string,
  record: ShoppingItem,
): Promise<void> {
  try {
    const id = env.HOUSEHOLD_ROOMS.idFromName(householdId);
    const stub = env.HOUSEHOLD_ROOMS.get(id);
    const message = `data: ${JSON.stringify({ action, record })}\n\n`;
    await stub.fetch(
      new Request("http://do/broadcast", { method: "POST", body: message }),
    );
  } catch (e) {
    console.error("[broadcast] failed:", e);
  }
}

async function assertMember(env: Env, householdId: string, userId: string): Promise<boolean> {
  const row = await env.DB
    .prepare("SELECT id FROM household_members WHERE household_id = ? AND user_id = ?")
    .bind(householdId, userId)
    .first();
  return row !== null;
}

/**
 * Look up or create a canonical product for this household.
 * 1. Exact case-insensitive match → reuse immediately.
 * 2. Fuzzy LIKE candidates → ask Claude if any is the same product.
 * 3. No match → categorise + insert.
 */
export async function upsertProduct(env: Env, householdId: string, name: string): Promise<Product> {
  // 1. Exact match (NOCASE collation handles case differences)
  const exact = await env.DB
    .prepare("SELECT * FROM products WHERE household_id = ? AND name = ?")
    .bind(householdId, name)
    .first<Product>();
  if (exact) return exact;

  // 2. Fuzzy candidates: names that contain or are contained by the new name
  const { results: candidates } = await env.DB
    .prepare(
      `SELECT * FROM products
       WHERE household_id = ?
         AND (LOWER(name) LIKE '%' || LOWER(?) || '%' OR LOWER(?) LIKE '%' || LOWER(name) || '%')
       LIMIT 10`,
    )
    .bind(householdId, name, name)
    .all<Product>();

  if (candidates.length > 0) {
    const match = await findMatchingProduct(env, name, candidates.map((c) => c.name));
    if (match) {
      return candidates.find((c) => c.name.toLowerCase() === match.toLowerCase())!;
    }
  }

  // 3. New product — categorise and insert
  const { category, aisleOrder } = await categorise(env, name);
  const now = nowISO();
  const id = crypto.randomUUID();

  await env.DB
    .prepare(
      `INSERT INTO products (id, household_id, name, category, aisle_order, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(household_id, name) DO NOTHING`,
    )
    .bind(id, householdId, name, category, aisleOrder, now, now)
    .run();

  const created = await env.DB
    .prepare("SELECT * FROM products WHERE household_id = ? AND name = ?")
    .bind(householdId, name)
    .first<Product>();

  return created!;
}

// GET /v1/items?household_id=xxx
app.get("/", async (c) => {
  const user = c.var.user;
  const householdId = c.req.query("household_id");
  if (!householdId) return c.json({ error: "missing_household_id" }, 400);

  if (!(await assertMember(c.env, householdId, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const { results } = await c.env.DB
    .prepare(
      `SELECT * FROM shopping_items
       WHERE household_id = ? AND checked = 0
       ORDER BY aisle_order ASC, name ASC`,
    )
    .bind(householdId)
    .all<ShoppingItem>();

  return c.json({ items: (results ?? []).map(toResponse) });
});

// POST /v1/items
app.post("/", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{
      id?: string;
      household_id?: string;
      name?: string;
      quantity?: string;
      notes?: string;
    }>()
    .catch(() => ({} as Record<string, never>));

  const householdId = body.household_id;
  const name = body.name?.trim();
  if (!householdId || !name) return c.json({ error: "missing_fields" }, 400);

  if (!(await assertMember(c.env, householdId, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  // Look up or create the canonical product for this name.
  // This deduplicates across the household and only categorises once.
  const product = await upsertProduct(c.env, householdId, name);

  const id = body.id ?? crypto.randomUUID();
  const now = nowISO();

  const item: ShoppingItem = {
    id,
    household_id: householdId,
    product_id: product.id,
    name: product.name,
    quantity: body.quantity ?? null,
    notes: body.notes ?? null,
    category: product.category,
    aisle_order: product.aisle_order,
    checked: 0,
    added_by: user.id,
    created_at: now,
    updated_at: now,
  };

  await c.env.DB
    .prepare(
      `INSERT INTO shopping_items
         (id, household_id, product_id, name, quantity, notes, category, aisle_order, checked, added_by, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
       ON CONFLICT(id) DO NOTHING`,
    )
    .bind(id, householdId, product.id, product.name, item.quantity, item.notes, product.category, product.aisle_order, user.id, now, now)
    .run();

  void broadcastToHousehold(c.env, householdId, "create", item);

  return c.json(toResponse(item), 201);
});

// POST /v1/items/:id/complete — records a purchase and removes the list entry
app.post("/:id/complete", async (c) => {
  const user = c.var.user;
  const itemId = c.req.param("id");

  const existing = await c.env.DB
    .prepare("SELECT * FROM shopping_items WHERE id = ?")
    .bind(itemId)
    .first<ShoppingItem>();

  if (!existing) return c.json({ error: "not_found" }, 404);

  if (!(await assertMember(c.env, existing.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  if (existing.product_id) {
    const historyId = crypto.randomUUID();
    await c.env.DB
      .prepare(
        `INSERT INTO purchase_history (id, household_id, product_id, quantity, purchased_by, purchased_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      )
      .bind(historyId, existing.household_id, existing.product_id, existing.quantity, user.id, nowISO())
      .run();
  }

  await c.env.DB.prepare("DELETE FROM shopping_items WHERE id = ?").bind(itemId).run();

  void broadcastToHousehold(c.env, existing.household_id, "delete", existing);

  return c.body(null, 204);
});

// PATCH /v1/items/:id
app.patch("/:id", async (c) => {
  const user = c.var.user;
  const itemId = c.req.param("id");

  const existing = await c.env.DB
    .prepare("SELECT * FROM shopping_items WHERE id = ?")
    .bind(itemId)
    .first<ShoppingItem>();

  if (!existing) return c.json({ error: "not_found" }, 404);

  if (!(await assertMember(c.env, existing.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  type PatchBody = Partial<Pick<ShoppingItem, "name" | "quantity" | "notes" | "category" | "aisle_order">>;
  const body: PatchBody = await c.req.json<PatchBody>().catch(() => ({}));

  const updated: ShoppingItem = {
    ...existing,
    name: body.name ?? existing.name,
    quantity: body.quantity !== undefined ? body.quantity : existing.quantity,
    notes: body.notes !== undefined ? body.notes : existing.notes,
    category: body.category ?? existing.category,
    aisle_order: body.aisle_order ?? existing.aisle_order,
    updated_at: nowISO(),
  };

  await c.env.DB
    .prepare(
      `UPDATE shopping_items
       SET name=?, quantity=?, notes=?, category=?, aisle_order=?, updated_at=?
       WHERE id=?`,
    )
    .bind(
      updated.name, updated.quantity, updated.notes,
      updated.category, updated.aisle_order,
      updated.updated_at, itemId,
    )
    .run();

  void broadcastToHousehold(c.env, existing.household_id, "update", updated);

  return c.json(toResponse(updated));
});

// DELETE /v1/items/:id — removes item without recording a purchase ("didn't buy it")
app.delete("/:id", async (c) => {
  const user = c.var.user;
  const itemId = c.req.param("id");

  const existing = await c.env.DB
    .prepare("SELECT * FROM shopping_items WHERE id = ?")
    .bind(itemId)
    .first<ShoppingItem>();

  if (!existing) return c.json({ error: "not_found" }, 404);

  if (!(await assertMember(c.env, existing.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  await c.env.DB.prepare("DELETE FROM shopping_items WHERE id = ?").bind(itemId).run();

  void broadcastToHousehold(c.env, existing.household_id, "delete", existing);

  return c.body(null, 204);
});

// POST /v1/items/bulk — create multiple items in one request (used by recipe import)
app.post("/bulk", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{
      household_id?: string;
      items?: { id?: string; name?: string; quantity?: string; notes?: string; category?: string; aisle_order?: number }[];
    }>()
    .catch(() => ({} as Record<string, never>));

  const householdId = body.household_id;
  if (!householdId || !Array.isArray(body.items) || body.items.length === 0) {
    return c.json({ error: "missing_fields" }, 400);
  }

  if (!(await assertMember(c.env, householdId, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  // Upsert products and build items in parallel
  const now = nowISO();
  const resolvedItems: (ShoppingItem | null)[] = await Promise.all(
    body.items.map(async (input) => {
      const name = input.name?.trim();
      if (!name) return null;

      // If category is provided by the caller (from recipe parse), skip upsertProduct's
      // categorise call by inserting a product directly if it doesn't exist yet.
      let product: Product;
      if (input.category && input.aisle_order) {
        const exact = await c.env.DB
          .prepare("SELECT * FROM products WHERE household_id = ? AND name = ?")
          .bind(householdId, name)
          .first<Product>();
        if (exact) {
          product = exact;
        } else {
          const pid = crypto.randomUUID();
          await c.env.DB
            .prepare(
              `INSERT INTO products (id, household_id, name, category, aisle_order, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(household_id, name) DO NOTHING`,
            )
            .bind(pid, householdId, name, input.category, input.aisle_order, now, now)
            .run();
          product = (await c.env.DB
            .prepare("SELECT * FROM products WHERE household_id = ? AND name = ?")
            .bind(householdId, name)
            .first<Product>())!;
        }
      } else {
        product = await upsertProduct(c.env, householdId, name);
      }

      const id = input.id ?? crypto.randomUUID();
      return {
        id,
        household_id: householdId,
        product_id: product.id,
        name: product.name,
        quantity: input.quantity ?? null,
        notes: input.notes ?? null,
        category: product.category,
        aisle_order: product.aisle_order,
        checked: 0,
        added_by: user.id,
        created_at: now,
        updated_at: now,
      } satisfies ShoppingItem;
    }),
  );

  const validItems = resolvedItems.filter((i): i is ShoppingItem => i !== null);
  if (validItems.length === 0) return c.json({ error: "no_valid_items" }, 400);

  await c.env.DB.batch(
    validItems.map((item) =>
      c.env.DB.prepare(
        `INSERT INTO shopping_items
           (id, household_id, product_id, name, quantity, notes, category, aisle_order, checked, added_by, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      ).bind(
        item.id, item.household_id, item.product_id, item.name,
        item.quantity, item.notes, item.category, item.aisle_order,
        item.added_by, item.created_at, item.updated_at,
      ),
    ),
  );

  for (const item of validItems) {
    void broadcastToHousehold(c.env, householdId, "create", item);
  }

  return c.json({ items: validItems.map(toResponse) }, 201);
});

export default app;
