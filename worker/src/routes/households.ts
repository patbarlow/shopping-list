import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";
import { nowISO, generateInviteCode, type Household } from "../db";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

// GET /v1/households/mine — fetch the household this user belongs to
app.get("/mine", async (c) => {
  const user = c.var.user;
  const row = await c.env.DB
    .prepare(
      `SELECT h.* FROM households h
       JOIN household_members m ON m.household_id = h.id
       WHERE m.user_id = ?
       LIMIT 1`,
    )
    .bind(user.id)
    .first<Household>();

  if (!row) return c.json({ household: null });
  return c.json({ household: row });
});

// POST /v1/households — create a new household
app.post("/", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ name?: string }>().catch(() => ({} as { name?: string }));
  const name = body.name?.trim();
  if (!name) return c.json({ error: "missing_name" }, 400);

  const id = crypto.randomUUID();
  const inviteCode = generateInviteCode();
  const now = nowISO();

  await c.env.DB.batch([
    c.env.DB.prepare(
      "INSERT INTO households (id, name, invite_code, created_at) VALUES (?, ?, ?, ?)",
    ).bind(id, name, inviteCode, now),
    c.env.DB.prepare(
      "INSERT INTO household_members (id, household_id, user_id, created_at) VALUES (?, ?, ?, ?)",
    ).bind(crypto.randomUUID(), id, user.id, now),
  ]);

  return c.json({ household: { id, name, invite_code: inviteCode, created_at: now } }, 201);
});

// POST /v1/households/join — join via invite code
app.post("/join", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ invite_code?: string }>().catch(() => ({} as { invite_code?: string }));
  const code = body.invite_code?.trim().toUpperCase();
  if (!code) return c.json({ error: "missing_code" }, 400);

  const household = await c.env.DB
    .prepare("SELECT * FROM households WHERE invite_code = ?")
    .bind(code)
    .first<Household>();

  if (!household) return c.json({ error: "not_found" }, 404);

  // Idempotent join — already a member is fine
  await c.env.DB
    .prepare(
      `INSERT OR IGNORE INTO household_members (id, household_id, user_id, created_at)
       VALUES (?, ?, ?, ?)`,
    )
    .bind(crypto.randomUUID(), household.id, user.id, nowISO())
    .run();

  return c.json({ household });
});

export default app;
