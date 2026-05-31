import { Hono } from "hono";
import type { Env } from "../env";
import { requireAuth, type AuthVariables } from "../middleware/auth";

const app = new Hono<{ Bindings: Env; Variables: AuthVariables }>();

app.use("*", requireAuth);

// GET /v1/households/:householdId/realtime
// Upgrades to a persistent SSE stream for real-time shopping item events.
app.get("/:householdId/realtime", async (c) => {
  const user = c.var.user;
  const householdId = c.req.param("householdId");

  const member = await c.env.DB
    .prepare("SELECT id FROM household_members WHERE household_id = ? AND user_id = ?")
    .bind(householdId, user.id)
    .first();

  if (!member) return c.json({ error: "not_member" }, 403);

  const id = c.env.HOUSEHOLD_ROOMS.idFromName(householdId);
  const stub = c.env.HOUSEHOLD_ROOMS.get(id);

  return stub.fetch(
    new Request("http://do/sse", {
      method: "GET",
      signal: c.req.raw.signal,
    }),
  );
});

export default app;
