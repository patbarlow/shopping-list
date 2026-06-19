import type { Env } from "./env";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_HEADERS = (key: string) => ({
  "content-type": "application/json",
  "x-api-key": key,
  "anthropic-version": "2023-06-01",
});

// ---------------------------------------------------------------------------
// Generic helpers
// ---------------------------------------------------------------------------

async function callClaude(
  env: Env,
  messages: { role: "user" | "assistant"; content: string | object[] }[],
  maxTokens: number,
): Promise<string | null> {
  if (!env.ANTHROPIC_API_KEY) return null;
  try {
    const res = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: ANTHROPIC_HEADERS(env.ANTHROPIC_API_KEY),
      body: JSON.stringify({ model: "claude-haiku-4-5-20251001", max_tokens: maxTokens, messages }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) return null;
    const json = await res.json<{ content?: { text?: string }[] }>();
    return (json.content?.[0]?.text ?? "").trim() || null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Categorisation
// ---------------------------------------------------------------------------

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

export const CATEGORY_NAMES = Object.keys(CATEGORIES);

export async function categorise(
  env: Env,
  itemName: string,
): Promise<{ category: string; aisleOrder: number }> {
  const categoryNames = CATEGORY_NAMES.filter((c) => c !== "Other").join(", ");
  const text = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `Categorise this grocery item into exactly one Woolworths supermarket aisle.\n` +
          `Item: "${itemName}"\n\n` +
          `Reply with ONLY the category name, nothing else. Choose from:\n` +
          `${categoryNames}, Other`,
      },
    ],
    20,
  );
  if (!text) return { category: "Other", aisleOrder: 19 };
  const aisleOrder = CATEGORIES[text];
  if (!aisleOrder) return { category: "Other", aisleOrder: 19 };
  return { category: text, aisleOrder };
}

// ---------------------------------------------------------------------------
// Product deduplication — fuzzy semantic matching
// ---------------------------------------------------------------------------

/**
 * Given a new product name and a list of existing candidate names (from a
 * LIKE-based pre-filter), ask Claude whether any candidate is the same product.
 * Returns the matching candidate name, or null if none match.
 */
export async function findMatchingProduct(
  env: Env,
  newName: string,
  candidates: string[],
): Promise<string | null> {
  if (candidates.length === 0) return null;
  const list = candidates.map((c) => `"${c}"`).join(", ");
  const text = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `You're helping deduplicate grocery products for a shopping app.\n` +
          `New product: "${newName}"\n` +
          `Existing products: ${list}\n\n` +
          `Is the new product the same physical grocery item as any of the existing products?\n` +
          `"greek yoghurt" and "vanilla yoghurt" are DIFFERENT. "yoghurt" and "yogurt" are SAME.\n` +
          `Reply with NONE, or the exact name of the single matching existing product.`,
      },
    ],
    50,
  );
  if (!text || text === "NONE") return null;
  // Verify the returned name actually exists in our candidate list
  return candidates.find((c) => c.toLowerCase() === text.toLowerCase()) ?? null;
}

// ---------------------------------------------------------------------------
// Recipe parsing — URL
// ---------------------------------------------------------------------------

export interface ParsedIngredient {
  name: string;
  quantity: string | null;
}

export interface ParsedRecipe {
  recipe_name: string;
  default_servings: number | null;
  ingredients: ParsedIngredient[];
}

interface RawJsonLdRecipe {
  recipe_name: string;
  default_servings: number | null;
  ingredients: string[]; // raw strings, not yet cleaned
}

/**
 * Try to extract Recipe schema.org JSON-LD from HTML.
 * Returns raw ingredient strings — caller must clean via Claude.
 */
function extractJsonLdRecipe(html: string): RawJsonLdRecipe | null {
  const scriptMatches = html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi);
  for (const match of scriptMatches) {
    try {
      const raw = JSON.parse(match[1]);
      const nodes: object[] = Array.isArray(raw)
        ? raw
        : raw["@graph"]
          ? raw["@graph"]
          : [raw];

      for (const node of nodes) {
        const n = node as Record<string, unknown>;
        const type = n["@type"];
        const isRecipe =
          type === "Recipe" ||
          (Array.isArray(type) && (type as string[]).includes("Recipe"));
        if (!isRecipe) continue;

        const name = String(n["name"] ?? "Recipe");
        const yieldRaw = n["recipeYield"];
        const yieldStr = Array.isArray(yieldRaw) ? yieldRaw[0] : String(yieldRaw ?? "");
        const servings = parseInt(yieldStr) || null;

        const rawIngredients: string[] = Array.isArray(n["recipeIngredient"])
          ? (n["recipeIngredient"] as string[])
          : [];

        // Return raw strings — caller will clean them via Claude
        return { recipe_name: name, default_servings: servings, ingredients: rawIngredients };
      }
    } catch {
      // ignore parse errors, try next script tag
    }
  }
  return null;
}

/**
 * Use Claude to clean raw JSON-LD ingredient strings into structured name/quantity pairs.
 * Handles sites that embed notes, alternatives, and preparation hints in the ingredient strings.
 */
async function cleanIngredients(env: Env, rawIngredients: string[]): Promise<ParsedIngredient[]> {
  if (rawIngredients.length === 0) return [];

  const list = rawIngredients.map((s, i) => `${i + 1}. ${s}`).join("\n");
  const reply = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `Parse these recipe ingredient strings into clean name/quantity pairs.\n` +
          `Rules:\n` +
          `- Strip parenthetical notes, alternatives, and hints (e.g. "(Note 1)", "((mince))", "(or yellow onion)", "(finely chopped)")\n` +
          `- Keep only the core ingredient name (e.g. "ground beef", "garlic cloves", "onion", "olive oil")\n` +
          `- Quantity is the primary amount — prefer metric if both are given; keep unit with number (e.g. "400g", "1/4 cup", "2")\n` +
          `- Strip leading slashes, commas, or other punctuation from names\n` +
          `- Use null for quantity if genuinely absent\n` +
          `- Return EXACTLY ${rawIngredients.length} objects in the same order as input\n\n` +
          `Return ONLY valid JSON array: [{"name":"...","quantity":"..."}]\n\n` +
          `Ingredients:\n${list}`,
      },
    ],
    2000,
  );

  if (!reply) {
    // Fallback: strip obvious parentheticals with regex
    return rawIngredients.map((raw) => ({
      name: raw.replace(/\s*\(+[^)]*\)+/g, "").replace(/^[/,;\s]+/, "").trim(),
      quantity: null,
    }));
  }

  try {
    const parsed = JSON.parse(reply.replace(/```json\n?|```/g, "").trim()) as ParsedIngredient[];
    // Ensure we got the right count; pad or trim if needed
    while (parsed.length < rawIngredients.length) parsed.push({ name: rawIngredients[parsed.length], quantity: null });
    return parsed.slice(0, rawIngredients.length);
  } catch {
    return rawIngredients.map((raw) => ({
      name: raw.replace(/\s*\(+[^)]*\)+/g, "").replace(/^[/,;\s]+/, "").trim(),
      quantity: null,
    }));
  }
}

/** Strip HTML tags and collapse whitespace for Claude fallback parsing */
function htmlToText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 6000); // keep prompt size reasonable
}

export async function parseRecipeFromUrl(env: Env, url: string): Promise<ParsedRecipe | null> {
  let html: string;
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; ShoppingListBot/1.0)" },
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) return null;
    html = await res.text();
  } catch {
    return null;
  }

  // Prefer structured JSON-LD data, then clean ingredient strings via Claude
  const jsonLd = extractJsonLdRecipe(html);
  if (jsonLd && jsonLd.ingredients.length > 0) {
    const ingredients = await cleanIngredients(env, jsonLd.ingredients);
    return { recipe_name: jsonLd.recipe_name, default_servings: jsonLd.default_servings, ingredients };
  }

  // Fallback: ask Claude to extract from page text
  const text = htmlToText(html);
  const reply = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `Extract the recipe from this webpage text. Return ONLY valid JSON matching this shape:\n` +
          `{"recipe_name":"...","default_servings":4,"ingredients":[{"name":"...","quantity":"..."}]}\n` +
          `For each ingredient: use a clean core name only (no preparation notes, no alternatives in parentheses), ` +
          `and extract the primary quantity with its unit. Use null for quantity if absent.\n` +
          `If this is not a recipe page, return {"error":"not_a_recipe"}.\n\n` +
          `Page text:\n${text}`,
      },
    ],
    1000,
  );

  if (!reply) return null;
  try {
    const parsed = JSON.parse(reply.replace(/```json\n?|```/g, "").trim());
    if (parsed.error) return null;
    return parsed as ParsedRecipe;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Recipe parsing — image (camera or photo)
// ---------------------------------------------------------------------------

export async function parseRecipeFromImage(
  env: Env,
  imageBase64: string,
  mediaType: string = "image/jpeg",
): Promise<ParsedRecipe | null> {
  if (!env.ANTHROPIC_API_KEY) return null;
  try {
    const res = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: ANTHROPIC_HEADERS(env.ANTHROPIC_API_KEY),
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1000,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: mediaType, data: imageBase64 },
              },
              {
                type: "text",
                text:
                  `Extract the recipe from this image. Return ONLY valid JSON matching this shape:\n` +
                  `{"recipe_name":"...","default_servings":4,"ingredients":[{"name":"...","quantity":"..."}]}\n` +
                  `Use null for quantity if unknown. If this is not a recipe, return {"error":"not_a_recipe"}.`,
              },
            ],
          },
        ],
      }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) return null;
    const json = await res.json<{ content?: { text?: string }[] }>();
    const text = (json.content?.[0]?.text ?? "").trim();
    const parsed = JSON.parse(text.replace(/```json\n?|```/g, "").trim());
    if (parsed.error) return null;
    return parsed as ParsedRecipe;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Receipt OCR
// ---------------------------------------------------------------------------

export interface ReceiptLineItem {
  description: string;
  quantity: number | null;
  unit_price: number | null;
  total_price: number | null;
}

export interface ParsedReceipt {
  store_name: string | null;
  total_amount: number | null;
  receipt_date: string | null;
  line_items: ReceiptLineItem[];
}

export async function parseReceiptFromImage(
  env: Env,
  imageBase64: string,
  mediaType: string = "image/jpeg",
): Promise<ParsedReceipt | null> {
  if (!env.ANTHROPIC_API_KEY) return null;
  try {
    const res = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: ANTHROPIC_HEADERS(env.ANTHROPIC_API_KEY),
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 2000,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: mediaType, data: imageBase64 },
              },
              {
                type: "text",
                text:
                  `Extract all line items from this receipt. Return ONLY valid JSON:\n` +
                  `{"store_name":"...","total_amount":12.34,"receipt_date":"2026-06-20","line_items":[{"description":"...","quantity":1,"unit_price":2.50,"total_price":2.50}]}\n` +
                  `Use null for any field you cannot read clearly. receipt_date must be ISO format (YYYY-MM-DD) or null. Exclude tax/subtotal/total rows from line_items.`,
              },
            ],
          },
        ],
      }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) return null;
    const json = await res.json<{ content?: { text?: string }[] }>();
    const text = (json.content?.[0]?.text ?? "").trim();
    return JSON.parse(text.replace(/```json\n?|```/g, "").trim()) as ParsedReceipt;
  } catch {
    return null;
  }
}

/**
 * Match receipt line items to purchase history product names.
 * Returns a map of receipt description → product name (or null if no match).
 */
export async function matchReceiptItems(
  env: Env,
  receiptDescriptions: string[],
  productNames: string[],
): Promise<Record<string, string | null>> {
  if (receiptDescriptions.length === 0 || productNames.length === 0) {
    return Object.fromEntries(receiptDescriptions.map((d) => [d, null]));
  }

  const receiptList = receiptDescriptions.map((d, i) => `${i + 1}. "${d}"`).join("\n");
  const productList = productNames.map((p, i) => `${i + 1}. "${p}"`).join("\n");

  const reply = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `Match each receipt item to the most likely product from the recently purchased list.\n` +
          `Receipt items:\n${receiptList}\n\n` +
          `Recently purchased products:\n${productList}\n\n` +
          `Reply with ONLY a JSON object where each key is a receipt item description and the value is\n` +
          `the exact matching product name, or null if there is no clear match.\n` +
          `Example: {"Full Cream Milk 2L": "milk", "Woolworths Greek Yoghurt": "greek yoghurt"}`,
      },
    ],
    500,
  );

  if (!reply) return Object.fromEntries(receiptDescriptions.map((d) => [d, null]));
  try {
    const parsed = JSON.parse(reply.replace(/```json\n?|```/g, "").trim());
    // Validate that matched names actually exist in our product list
    const productSet = new Set(productNames.map((p) => p.toLowerCase()));
    return Object.fromEntries(
      receiptDescriptions.map((d) => {
        const match = parsed[d];
        const valid = typeof match === "string" && productSet.has(match.toLowerCase()) ? match : null;
        return [d, valid];
      }),
    );
  } catch {
    return Object.fromEntries(receiptDescriptions.map((d) => [d, null]));
  }
}
