#!/usr/bin/env npx tsx
/**
 * Migration script — exports shopping_items from PocketBase and writes a SQL
 * file you can import into D1.
 *
 * Usage:
 *   PB_EMAIL=you@example.com PB_PASSWORD=yourpassword npx tsx scripts/migrate.ts
 *
 * Then after creating your household in the new app, get its ID from the app's
 * Settings screen and run:
 *   HOUSEHOLD_ID=<id> npx tsx scripts/migrate.ts
 *
 * Finally apply to D1:
 *   cd worker && wrangler d1 execute shopping-list --remote --file=../migration.sql
 */

const PB_URL = process.env.PB_URL ?? "http://tetsu.me:8090";
const DB_NAME = "shopping-list";

async function main() {
  const email = process.env.PB_EMAIL;
  const password = process.env.PB_PASSWORD;
  const householdId = process.env.HOUSEHOLD_ID;

  if (!email || !password) {
    console.error("Set PB_EMAIL and PB_PASSWORD environment variables.");
    process.exit(1);
  }

  // 1. Login to PocketBase
  const authRes = await fetch(`${PB_URL}/api/collections/users/auth-with-password`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ identity: email, password }),
  });
  if (!authRes.ok) {
    console.error("PocketBase login failed:", await authRes.text());
    process.exit(1);
  }
  const { token } = (await authRes.json()) as { token: string };
  console.log("✓ Logged in to PocketBase");

  // 2. Fetch all shopping items
  let allItems: Record<string, unknown>[] = [];
  let page = 1;
  while (true) {
    const res = await fetch(
      `${PB_URL}/api/collections/shopping_items/records?perPage=500&page=${page}&sort=created`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    const data = (await res.json()) as { items: Record<string, unknown>[]; totalPages: number };
    allItems = allItems.concat(data.items);
    if (page >= data.totalPages) break;
    page++;
  }
  console.log(`✓ Fetched ${allItems.length} items from PocketBase`);

  if (allItems.length === 0) {
    console.log("No items to migrate.");
    return;
  }

  if (!householdId) {
    console.log(`
Items found. Now:
  1. Open the new Shopping List app
  2. Sign in and create your household
  3. Go to Settings to find your household ID
  4. Re-run with: HOUSEHOLD_ID=<id> PB_EMAIL=... PB_PASSWORD=... npx tsx scripts/migrate.ts
`);
    return;
  }

  // 3. Generate SQL
  const now = new Date().toISOString();
  const lines = [
    `-- Shopping List migration from PocketBase`,
    `-- Generated: ${now}`,
    `-- Items: ${allItems.length}`,
    ``,
    `PRAGMA foreign_keys = OFF;`,
    ``,
  ];

  for (const item of allItems) {
    const id = crypto.randomUUID();
    const name = String(item.name ?? "").replace(/'/g, "''");
    const quantity = item.quantity ? `'${String(item.quantity).replace(/'/g, "''")}'` : "NULL";
    const notes = item.notes ? `'${String(item.notes).replace(/'/g, "''")}'` : "NULL";
    const category = String(item.category ?? "Other").replace(/'/g, "''");
    const aisleOrder = Number(item.aisle_order ?? 19);
    const checked = item.checked ? 1 : 0;
    const createdAt = String(item.created ?? now);
    const updatedAt = String(item.updated ?? now);

    lines.push(
      `INSERT OR IGNORE INTO shopping_items ` +
      `(id, household_id, name, quantity, notes, category, aisle_order, checked, added_by, created_at, updated_at) ` +
      `VALUES ('${id}', '${householdId}', '${name}', ${quantity}, ${notes}, ` +
      `'${category}', ${aisleOrder}, ${checked}, '${householdId}', '${createdAt}', '${updatedAt}');`,
    );
  }

  lines.push(``, `PRAGMA foreign_keys = ON;`);
  const sql = lines.join("\n") + "\n";
  import("fs").then(({ writeFileSync }) => writeFileSync("migration.sql", sql));

  console.log(`✓ Written migration.sql with ${allItems.length} items`);
  console.log(`
Next step:
  cd worker && wrangler d1 execute ${DB_NAME} --remote --file=../migration.sql
`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
