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
