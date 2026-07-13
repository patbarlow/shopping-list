#!/usr/bin/env npx tsx
/**
 * Backfills size_value/size_unit/unit_price on old receipt_line_items rows —
 * the ones saved before unit pricing existed, so they're missing the data
 * ProductDetailView needs to show a $/100g baseline.
 *
 * No re-scanning needed: every row already has `raw_description` (e.g.
 * "Kettle Chips Sea Salt 165g"), which almost always still has the printed
 * package size in it — and for loose weight-sold items, `unit_price` ($/kg)
 * can be reconstructed directly as total_price ÷ quantity. Anything that
 * doesn't clearly match one of those two patterns is left alone rather than
 * guessed at.
 *
 * Usage:
 *   npx tsx scripts/backfill-unit-pricing.ts
 *
 * This only reads from the remote DB and writes a local SQL file — it does
 * not touch the database. Review backfill-unit-pricing.sql, then apply it:
 *   cd worker && npx wrangler d1 execute shopping-list --remote --file=../backfill-unit-pricing.sql
 */

import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WORKER_DIR = path.join(__dirname, "..", "worker");
const DB_NAME = "shopping-list";

interface Row {
  id: string;
  raw_description: string;
  quantity: number | null;
  total_price: number | null;
}

// Same unit vocabulary/order as heuristicCleanName() in worker/src/ai.ts, so
// this recognizes exactly what the receipt-scan prompt already knows to print.
const SIZE_UNITS = "kg|g|gm|ml|l|ltr|lt";

// "6x250ml", "4 x 250g" — total content of the multipack.
const MULTIPACK_RE = new RegExp(`(?:^|\\s)(\\d+)\\s?x\\s?(\\d+(?:\\.\\d+)?)\\s?(${SIZE_UNITS})\\b`, "i");
// "165g", "2l", "500ml", "1kg"
const SIMPLE_SIZE_RE = new RegExp(`(?:^|\\s)(\\d+(?:\\.\\d+)?)\\s?(${SIZE_UNITS})\\b`, "i");

function extractSize(description: string): { value: number; unit: string } | null {
  const s = description.toLowerCase();

  const multi = s.match(MULTIPACK_RE);
  if (multi) {
    const count = parseFloat(multi[1]);
    const each = parseFloat(multi[2]);
    const value = count * each;
    if (isPlausible(value, multi[3])) return { value, unit: multi[3] };
  }

  const simple = s.match(SIMPLE_SIZE_RE);
  if (simple) {
    const value = parseFloat(simple[1]);
    if (isPlausible(value, simple[2])) return { value, unit: simple[2] };
  }

  return null;
}

// Reject sizes outside a sane range for groceries — almost always a stray
// number (a product code, a price fragment) rather than a real pack size.
function isPlausible(value: number, unit: string): boolean {
  if (unit === "kg" || unit === "l" || unit === "ltr" || unit === "lt") return value > 0.05 && value <= 25;
  return value > 1 && value <= 5000; // g, gm, ml
}

// Loose weight-sold items (produce, deli, meat) are priced per kg and rung up
// with a fractional quantity (e.g. 0.65 for 0.65kg) — count-based items are
// always whole numbers. Reconstruct the $/kg rate the receipt originally showed.
function backfillWeightUnitPrice(row: Row): number | null {
  if (row.quantity == null || row.total_price == null) return null;
  if (Number.isInteger(row.quantity) || row.quantity <= 0) return null;
  const unitPrice = row.total_price / row.quantity;
  return unitPrice > 0.5 && unitPrice <= 200 ? unitPrice : null;
}

function runWrangler(sqlCommand: string): unknown {
  const out = execSync(
    `npx wrangler d1 execute ${DB_NAME} --remote --json --command ${JSON.stringify(sqlCommand)}`,
    { cwd: WORKER_DIR, maxBuffer: 1024 * 1024 * 64, encoding: "utf-8" },
  );
  // wrangler sometimes prints update-check banners before the JSON payload.
  const start = out.search(/[[{]/);
  return JSON.parse(out.slice(start));
}

function escapeSql(value: string): string {
  return value.replace(/'/g, "''");
}

async function main() {
  console.log(`Fetching receipt_line_items missing unit pricing from the remote ${DB_NAME} database…`);
  const result = runWrangler(
    `SELECT id, raw_description, quantity, total_price FROM receipt_line_items ` +
    `WHERE size_value IS NULL AND unit_price IS NULL AND total_price IS NOT NULL`,
  );
  const rows: Row[] = Array.isArray(result) ? result[0]?.results ?? [] : (result as { results: Row[] }).results ?? [];
  console.log(`✓ Found ${rows.length} rows without unit pricing`);

  if (rows.length === 0) {
    console.log("Nothing to backfill.");
    return;
  }

  const statements: string[] = [];
  let sizeCount = 0;
  let weightCount = 0;

  for (const row of rows) {
    const size = extractSize(row.raw_description);
    if (size) {
      sizeCount++;
      const value = Math.round(size.value * 1000) / 1000;
      statements.push(
        `UPDATE receipt_line_items SET size_value = ${value}, size_unit = '${escapeSql(size.unit)}' WHERE id = '${escapeSql(row.id)}';`,
      );
      continue;
    }

    const unitPrice = backfillWeightUnitPrice(row);
    if (unitPrice != null) {
      weightCount++;
      statements.push(
        `UPDATE receipt_line_items SET unit_price = ${Math.round(unitPrice * 100) / 100} WHERE id = '${escapeSql(row.id)}';`,
      );
    }
  }

  const skipped = rows.length - sizeCount - weightCount;
  console.log(`✓ ${sizeCount} package sizes extracted from descriptions`);
  console.log(`✓ ${weightCount} per-kg rates reconstructed for weight-sold items`);
  console.log(`- ${skipped} left alone (no confident match)`);

  if (statements.length === 0) {
    console.log("No confident matches — nothing written.");
    return;
  }

  const sql = [
    `-- Unit pricing backfill — generated ${new Date().toISOString()}`,
    `-- ${statements.length} rows`,
    ``,
    ...statements,
    ``,
  ].join("\n");

  const outPath = path.join(__dirname, "..", "backfill-unit-pricing.sql");
  writeFileSync(outPath, sql);
  console.log(`\n✓ Written ${outPath}`);
  console.log(`
Review it, then apply:
  cd worker && npx wrangler d1 execute ${DB_NAME} --remote --file=../backfill-unit-pricing.sql
`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
