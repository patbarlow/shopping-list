import { Hono } from "hono";
import type { Env } from "../env";
import { upsertUserByEmail, publicUser } from "../db";
import { issueSession } from "../session";
import { generateCode, hashCode, sendCodeEmail, isValidEmail } from "../email";

const app = new Hono<{ Bindings: Env }>();

const CODE_TTL_MS = 10 * 60 * 1000;
const RESEND_COOLDOWN_MS = 30 * 1000;
const MAX_ATTEMPTS = 5;

app.post("/email/start", async (c) => {
  const body = await c.req.json<{ email?: string }>().catch(() => ({} as { email?: string }));
  const email = body.email?.trim().toLowerCase();
  if (!email || !isValidEmail(email)) {
    return c.json({ error: "invalid_email" }, 400);
  }

  const existing = await c.env.DB
    .prepare("SELECT last_sent_at FROM email_codes WHERE email = ?")
    .bind(email)
    .first<{ last_sent_at: string }>();

  if (existing) {
    const elapsed = Date.now() - new Date(existing.last_sent_at).getTime();
    if (elapsed < RESEND_COOLDOWN_MS) {
      const retryAfter = Math.ceil((RESEND_COOLDOWN_MS - elapsed) / 1000);
      return c.json({ error: "rate_limited", retry_after: retryAfter }, 429);
    }
  }

  const code = generateCode();
  const codeHash = await hashCode(code);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + CODE_TTL_MS).toISOString();
  const nowISO = now.toISOString();

  await c.env.DB
    .prepare(
      `INSERT INTO email_codes (email, code_hash, attempts, expires_at, last_sent_at)
       VALUES (?, ?, 0, ?, ?)
       ON CONFLICT(email) DO UPDATE SET
         code_hash = excluded.code_hash,
         attempts = 0,
         expires_at = excluded.expires_at,
         last_sent_at = excluded.last_sent_at`,
    )
    .bind(email, codeHash, expiresAt, nowISO)
    .run();

  try {
    await sendCodeEmail(c.env, email, code);
  } catch (e) {
    console.error("Email send failed:", e);
    return c.json({ error: "email_failed", detail: String(e) }, 502);
  }

  return c.json({ sent: true });
});

app.post("/email/verify", async (c) => {
  const body = await c.req
    .json<{ email?: string; code?: string; name?: string }>()
    .catch(() => ({} as { email?: string; code?: string; name?: string }));

  const email = body.email?.trim().toLowerCase();
  const code = body.code?.trim();
  if (!email || !code) return c.json({ error: "missing_fields" }, 400);

  const row = await c.env.DB
    .prepare("SELECT * FROM email_codes WHERE email = ?")
    .bind(email)
    .first<{ email: string; code_hash: string; attempts: number; expires_at: string }>();

  if (!row) return c.json({ error: "no_code" }, 400);
  if (new Date(row.expires_at) < new Date()) {
    await c.env.DB.prepare("DELETE FROM email_codes WHERE email = ?").bind(email).run();
    return c.json({ error: "code_expired" }, 400);
  }
  if (row.attempts >= MAX_ATTEMPTS) return c.json({ error: "too_many_attempts" }, 400);

  await c.env.DB
    .prepare("UPDATE email_codes SET attempts = attempts + 1 WHERE email = ?")
    .bind(email)
    .run();

  const providedHash = await hashCode(code);
  if (providedHash !== row.code_hash) return c.json({ error: "invalid_code" }, 400);

  await c.env.DB.prepare("DELETE FROM email_codes WHERE email = ?").bind(email).run();

  const { user } = await upsertUserByEmail(c.env.DB, email, body.name);
  const session = await issueSession(user.id, c.env.SESSION_SECRET);
  return c.json({ session, user: publicUser(user) });
});

export default app;
