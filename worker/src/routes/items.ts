import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO, type ShoppingItem } from "../db";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

const CATEGORIES: Record<string, number> = {
  "Fruit & Veg": 1,
  "Meat & Seafood": 2,
  "Deli": 3,
  "Bakery": 4,
  "Dairy & Eggs": 5,
  "Frozen": 6,
  "Pantry": 7,
  "Breakfast": 8,
  "Snacks & Confectionery": 9,
  "Drinks": 10,
  "Condiments & Sauces": 11,
  "Baking": 12,
  "International": 13,
  "Health & Beauty": 14,
  "Cleaning & Laundry": 15,
  "Household": 16,
  "Pet": 17,
  "Baby": 18,
  "Other": 19,
};

async function categorise(env: Env, itemName: string): Promise<{ category: string; aisleOrder: number }> {
  if (!env.ANTHROPIC_API_KEY) return { category: "Other", aisleOrder: 19 };

  const categoryNames = Object.keys(CATEGORIES).filter((c) => c !== "Other").join(", ");
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 20,
        messages: [
          {
            role: "user",
            content:
              `Categorise this grocery item into exactly one Woolworths supermarket aisle.\n` +
              `Item: "${itemName}"\n\n` +
              `Reply with ONLY the category name, nothing else. Choose from:\n` +
              `${categoryNames}, Other`,
          },
        ],
      }),
      signal: AbortSignal.timeout(15_000),
    });

    if (!res.ok) return { category: "Other", aisleOrder: 19 };

    const json = await res.json<{ content?: { text?: string }[] }>();
    const text = (json.content?.[0]?.text ?? "").trim();
    const aisleOrder = CATEGORIES[text];
    if (!aisleOrder) return { category: "Other", aisleOrder: 19 };
    return { category: text, aisleOrder };
  } catch {
    return { category: "Other", aisleOrder: 19 };
  }
}

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
       WHERE household_id = ?
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

  const id = body.id ?? crypto.randomUUID();
  const now = nowISO();

  // Categorise inline — the response already has the correct category (same
  // behaviour as the old PocketBase hook mutating e.record before returning).
  const { category, aisleOrder } = await categorise(c.env, name);

  const item: ShoppingItem = {
    id,
    household_id: householdId,
    name,
    quantity: body.quantity ?? null,
    notes: body.notes ?? null,
    category,
    aisle_order: aisleOrder,
    checked: 0,
    added_by: user.id,
    created_at: now,
    updated_at: now,
  };

  await c.env.DB
    .prepare(
      `INSERT INTO shopping_items
         (id, household_id, name, quantity, notes, category, aisle_order, checked, added_by, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
       ON CONFLICT(id) DO NOTHING`,
    )
    .bind(id, householdId, name, item.quantity, item.notes, category, aisleOrder, user.id, now, now)
    .run();

  // Broadcast to household partners (non-blocking — don't delay the response)
  void broadcastToHousehold(c.env, householdId, "create", item);

  return c.json(toResponse(item), 201);
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

  type PatchBody = Partial<Pick<ShoppingItem, "name" | "quantity" | "notes" | "checked" | "category" | "aisle_order">>;
  const body: PatchBody = await c.req.json<PatchBody>().catch(() => ({}));

  const updated: ShoppingItem = {
    ...existing,
    name: body.name ?? existing.name,
    quantity: body.quantity !== undefined ? body.quantity : existing.quantity,
    notes: body.notes !== undefined ? body.notes : existing.notes,
    checked: body.checked !== undefined ? (body.checked ? 1 : 0) : existing.checked,
    category: body.category ?? existing.category,
    aisle_order: body.aisle_order ?? existing.aisle_order,
    updated_at: nowISO(),
  };

  await c.env.DB
    .prepare(
      `UPDATE shopping_items
       SET name=?, quantity=?, notes=?, checked=?, category=?, aisle_order=?, updated_at=?
       WHERE id=?`,
    )
    .bind(
      updated.name, updated.quantity, updated.notes,
      updated.checked, updated.category, updated.aisle_order,
      updated.updated_at, itemId,
    )
    .run();

  void broadcastToHousehold(c.env, existing.household_id, "update", updated);

  return c.json(toResponse(updated));
});

// DELETE /v1/items/:id
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

export default app;
