export interface User {
  id: string;
  email: string;
  name: string | null;
  created_at: string;
  updated_at: string;
}

export interface Household {
  id: string;
  name: string;
  invite_code: string;
  created_at: string;
}

export interface HouseholdMember {
  id: string;
  household_id: string;
  user_id: string;
  created_at: string;
}

export interface ShoppingItem {
  id: string;
  household_id: string;
  product_id: string | null;
  name: string;
  quantity: string | null;
  notes: string | null;
  category: string;
  aisle_order: number;
  checked: number; // SQLite boolean: 0 | 1
  added_by: string;
  created_at: string;
  updated_at: string;
}

export interface Product {
  id: string;
  household_id: string;
  name: string;
  category: string;
  aisle_order: number;
  created_at: string;
  updated_at: string;
}

export interface PurchaseHistory {
  id: string;
  household_id: string;
  product_id: string;
  quantity: string | null;
  purchased_by: string;
  purchased_at: string;
  price_paid: number | null;
  currency: string | null;
  source: string | null;
}

export interface Recipe {
  id: string;
  household_id: string;
  name: string;
  source_url: string | null;
  default_servings: number | null;
  created_at: string;
}

export interface RecipeIngredient {
  id: string;
  recipe_id: string;
  product_id: string | null;
  name: string;
  quantity: string | null;
  created_at: string;
}

export interface Receipt {
  id: string;
  household_id: string;
  scanned_at: string;
  receipt_date: string | null;
  store_name: string | null;
  total_amount: number | null;
  currency: string | null;
}

export interface ProductAlias {
  id: string;
  household_id: string;
  raw_description: string;
  product_id: string;
  match_count: number;
  last_seen_at: string;
  created_at: string;
}

export interface ReceiptLineItem {
  id: string;
  receipt_id: string;
  household_id: string;
  raw_description: string;
  quantity: number | null;
  unit_price: number | null;
  total_price: number | null;
  product_id: string | null;
  match_source: string | null;
  confirmed: number;
  purchase_history_id: string | null;
  created_at: string;
}

export interface PublicUser {
  id: string;
  email: string;
  name: string | null;
}

export function publicUser(u: User): PublicUser {
  return { id: u.id, email: u.email, name: u.name };
}

export async function upsertUserByEmail(
  db: D1Database,
  email: string,
  name?: string,
): Promise<{ user: User; isNew: boolean }> {
  const existing = await db
    .prepare("SELECT * FROM users WHERE email = ?")
    .bind(email)
    .first<User>();

  if (existing) {
    if (name && !existing.name) {
      await db
        .prepare("UPDATE users SET name = ?, updated_at = ? WHERE id = ?")
        .bind(name, nowISO(), existing.id)
        .run();
      existing.name = name;
    }
    return { user: existing, isNew: false };
  }

  const id = crypto.randomUUID();
  const now = nowISO();
  await db
    .prepare(
      `INSERT INTO users (id, email, name, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(id, email, name ?? null, now, now)
    .run();

  return {
    user: { id, email, name: name ?? null, created_at: now, updated_at: now },
    isNew: true,
  };
}

export async function getUser(db: D1Database, id: string): Promise<User | null> {
  return db.prepare("SELECT * FROM users WHERE id = ?").bind(id).first<User>();
}

export function nowISO(): string {
  return new Date().toISOString();
}

export function generateInviteCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  return Array.from({ length: 6 }, () => chars[Math.floor(Math.random() * chars.length)]).join("");
}
