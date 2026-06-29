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

const HAIKU = "claude-haiku-4-5-20251001";
const SONNET = "claude-sonnet-4-6"; // receipts: accuracy matters more than cost

async function callClaude(
  env: Env,
  messages: { role: "user" | "assistant"; content: string | object[] }[],
  maxTokens: number,
  model: string = HAIKU,
): Promise<string | null> {
  if (!env.ANTHROPIC_API_KEY) return null;
  try {
    const res = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: ANTHROPIC_HEADERS(env.ANTHROPIC_API_KEY),
      body: JSON.stringify({ model, max_tokens: maxTokens, messages }),
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

const RECEIPT_RULES =
  `Return ONLY valid JSON:\n` +
  `{"store_name":"...","total_amount":12.34,"receipt_date":"2026-06-20","line_items":[{"description":"...","quantity":1,"unit_price":2.50,"total_price":2.50}]}\n` +
  `Rules:\n` +
  `- Transcribe EXACTLY what is on the receipt. Never invent, guess, or "correct" a product, size, brand or price. If a value is unclear, use null — do NOT fill it in from what is typical.\n` +
  `- "description" is the raw product text exactly as printed, including the size/volume if shown (e.g. "WW FUL CRM MILK 2L" stays 2L, not 3L).\n` +
  `- "quantity" is the number of units (e.g. 2 for "2 @ $3.00"); use 1 for a single unit; for items sold by weight use the weight number (e.g. 0.65 for "0.65kg").\n` +
  `- "unit_price" is the per-unit/per-kg price; "total_price" is what was actually charged for that line.\n` +
  `- receipt_date must be ISO format (YYYY-MM-DD) or null.\n` +
  `- EXCLUDE non-product rows: subtotal, total, tax/GST, rounding, change, tender/EFTPOS/cash, loyalty/points, savings, and store header/footer text.\n` +
  `- A discount line that reduces the price of the item above it should be folded into that item's total_price, not listed separately.\n` +
  `- Include EVERY product line that is actually printed, and ONLY lines that are actually printed.`;

function parseReceiptJson(text: string): ParsedReceipt | null {
  try {
    const parsed = JSON.parse(text.replace(/```json\n?|```/g, "").trim()) as ParsedReceipt;
    if (!parsed || !Array.isArray(parsed.line_items)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/**
 * Parse a digital receipt's extracted text layer. Far more accurate than OCR'ing
 * a rasterised PDF — there is nothing to misread, so the model cannot invent items.
 */
export async function parseReceiptFromText(env: Env, receiptText: string): Promise<ParsedReceipt | null> {
  const reply = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `This is the exact text extracted from a supermarket receipt. Extract every purchased product.\n` +
          `${RECEIPT_RULES}\n\n` +
          `Receipt text:\n${receiptText.slice(0, 12000)}`,
      },
    ],
    3000,
    SONNET,
  );
  return reply ? parseReceiptJson(reply) : null;
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
        model: SONNET,
        max_tokens: 3000,
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
                text: `Extract every purchased product from this supermarket receipt image.\n${RECEIPT_RULES}`,
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
    return parseReceiptJson(text);
  } catch {
    return null;
  }
}

export interface ResolvedReceiptItem {
  /** Exact name of an existing catalogue product this matches, or null if it is new. */
  existingName: string | null;
  /** Clean, simple, normal-case product name — used for display and for creating a new product. */
  cleanName: string;
}

/**
 * Turn a raw receipt description into a clean, simple product name without any AI —
 * strips store prefixes, sizes/weights, pack counts and prices, then title-cases.
 * Used as a fallback when Claude is unavailable or returns nothing usable.
 */
export function heuristicCleanName(raw: string): string {
  let s = ` ${raw.toLowerCase()} `;
  s = s.replace(/\s(ww|woolworths|coles|aldi|iga|spc|homebrand|essentials|select)\s/g, " ");
  s = s.replace(/\s\d+(\.\d+)?\s?(kg|g|gm|ml|l|ltr|lt|pk|pack|pkt|ea|each|ct|x\d+)\b/g, " ");
  s = s.replace(/\bx\s?\d+\b/g, " ");
  s = s.replace(/\$?\d+(\.\d+)?/g, " ");
  s = s.replace(/[^a-z&'\s]/g, " ").replace(/\s+/g, " ").trim();
  if (!s) return raw.trim();
  return s
    .split(" ")
    .map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w))
    .join(" ");
}

/**
 * For each receipt line, decide whether it is the same physical grocery item as an
 * existing catalogue product, and produce a clean simple name to use either way.
 * One Claude call does both jobs (matching + naming) over the whole receipt.
 */
export async function resolveReceiptItems(
  env: Env,
  receiptDescriptions: string[],
  existingProductNames: string[],
): Promise<Record<string, ResolvedReceiptItem>> {
  const fallback = (): Record<string, ResolvedReceiptItem> =>
    Object.fromEntries(
      receiptDescriptions.map((d) => [d, { existingName: null, cleanName: heuristicCleanName(d) }]),
    );

  if (receiptDescriptions.length === 0) return {};

  const receiptList = receiptDescriptions.map((d, i) => `${i + 1}. "${d}"`).join("\n");
  const productList = existingProductNames.length > 0
    ? existingProductNames.map((p, i) => `${i + 1}. "${p}"`).join("\n")
    : "(none yet)";

  const reply = await callClaude(
    env,
    [
      {
        role: "user",
        content:
          `You are importing a supermarket receipt into a shopping app. For EACH raw receipt line, do two things:\n` +
          `1. Decide if it is the same physical grocery item as one of the existing products. The existing list is ordered most-recently-purchased first — prefer earlier entries when ambiguous. If none clearly match, it is new.\n` +
          `2. Give a clean simple product name written in normal everyday language: Title Case, NO brand, NO size/weight/pack count, NO abbreviations. It should be the generic everyday name a person would say.\n` +
          `   Examples: "BIRDS EYE THCT CHIPS 750G" -> "Frozen Chips"; "WW FUL CRM MILK 2L" -> "Milk"; "CADBURY DAIRY MILK 180G" -> "Chocolate"; "BANANA CAVENDISH" -> "Bananas"; "CHOBANI GREEK YOG VAN 4PK" -> "Greek Yoghurt".\n` +
          `   If the line matches an existing product, reuse that product's EXACT existing name as the clean name.\n\n` +
          `Receipt lines:\n${receiptList}\n\n` +
          `Existing products (most recent first):\n${productList}\n\n` +
          `Reply with ONLY a JSON object keyed by the exact raw receipt line. Each value is\n` +
          `{"match": "<exact existing product name>" or null, "name": "<clean simple name>"}.\n` +
          `Example: {"WW FUL CRM MILK 2L": {"match": "Milk", "name": "Milk"}, "BIRDS EYE THCT CHIPS 750G": {"match": null, "name": "Frozen Chips"}}`,
      },
    ],
    1500,
  );

  if (!reply) return fallback();
  try {
    const parsed = JSON.parse(reply.replace(/```json\n?|```/g, "").trim()) as Record<
      string,
      { match?: string | null; name?: string }
    >;
    const productByLower = new Map(existingProductNames.map((p) => [p.toLowerCase(), p]));
    return Object.fromEntries(
      receiptDescriptions.map((d) => {
        const entry = parsed[d];
        const matchedName =
          entry && typeof entry.match === "string"
            ? productByLower.get(entry.match.toLowerCase()) ?? null
            : null;
        const clean =
          (entry && typeof entry.name === "string" && entry.name.trim()) ||
          matchedName ||
          heuristicCleanName(d);
        return [d, { existingName: matchedName, cleanName: clean }];
      }),
    );
  } catch {
    return fallback();
  }
}
