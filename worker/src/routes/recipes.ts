import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO, type RecipeIngredient } from "../db";
import { categorise, parseRecipeFromUrl, parseRecipeFromImage } from "../ai";
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

// POST /v1/recipes/parse-url
// Fetches a recipe URL and returns structured ingredients. Does NOT save anything.
app.post("/parse-url", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{ household_id?: string; url?: string }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id || !body.url) return c.json({ error: "missing_fields" }, 400);

  if (!(await assertMember(c.env, body.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const parsed = await parseRecipeFromUrl(c.env, body.url);
  if (!parsed) return c.json({ error: "could_not_parse" }, 422);

  // Categorise all ingredients in parallel
  const ingredients = await Promise.all(
    parsed.ingredients.map(async (ing) => {
      const { category, aisleOrder } = await categorise(c.env, ing.name);
      return { ...ing, category, aisle_order: aisleOrder };
    }),
  );

  return c.json({
    recipe_name: parsed.recipe_name,
    default_servings: parsed.default_servings,
    ingredients,
  });
});

// POST /v1/recipes/parse-image
// Parses a recipe from a base64 image. Does NOT save anything.
app.post("/parse-image", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{ household_id?: string; image_base64?: string; media_type?: string }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id || !body.image_base64) return c.json({ error: "missing_fields" }, 400);

  if (!(await assertMember(c.env, body.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const parsed = await parseRecipeFromImage(c.env, body.image_base64, body.media_type);
  if (!parsed) return c.json({ error: "could_not_parse" }, 422);

  const ingredients = await Promise.all(
    parsed.ingredients.map(async (ing) => {
      const { category, aisleOrder } = await categorise(c.env, ing.name);
      return { ...ing, category, aisle_order: aisleOrder };
    }),
  );

  return c.json({
    recipe_name: parsed.recipe_name,
    default_servings: parsed.default_servings,
    ingredients,
  });
});

// POST /v1/recipes/save
// Saves a recipe + ingredients to the DB for history/memory tracking.
app.post("/save", async (c) => {
  const user = c.var.user;
  const body = await c.req
    .json<{
      household_id?: string;
      name?: string;
      source_url?: string;
      default_servings?: number;
      ingredients?: { name: string; quantity: string | null }[];
    }>()
    .catch(() => ({} as Record<string, never>));

  if (!body.household_id || !body.name) return c.json({ error: "missing_fields" }, 400);

  if (!(await assertMember(c.env, body.household_id, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const now = nowISO();
  const recipeId = crypto.randomUUID();

  await c.env.DB
    .prepare(
      `INSERT INTO recipes (id, household_id, name, source_url, default_servings, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .bind(recipeId, body.household_id, body.name, body.source_url ?? null, body.default_servings ?? null, now)
    .run();

  if (Array.isArray(body.ingredients) && body.ingredients.length > 0) {
    const ingredientRows: RecipeIngredient[] = await Promise.all(
      body.ingredients.map(async (ing) => {
        const product = await upsertProduct(c.env, body.household_id!, ing.name);
        return {
          id: crypto.randomUUID(),
          recipe_id: recipeId,
          product_id: product?.id ?? null,
          name: ing.name,
          quantity: ing.quantity,
          created_at: now,
        };
      }),
    );

    await c.env.DB.batch(
      ingredientRows.map((row) =>
        c.env.DB
          .prepare(
            `INSERT INTO recipe_ingredients (id, recipe_id, product_id, name, quantity, created_at)
             VALUES (?, ?, ?, ?, ?, ?)`,
          )
          .bind(row.id, row.recipe_id, row.product_id, row.name, row.quantity, row.created_at),
      ),
    );
  }

  return c.json({ recipe_id: recipeId }, 201);
});

export default app;
