import { Hono } from "hono";
import type { Env } from "./env";

import authRoutes from "./routes/auth";
import meRoutes from "./routes/me";
import itemsRoutes from "./routes/items";
import householdsRoutes from "./routes/households";
import realtimeRoutes from "./routes/realtime";

export { HouseholdRoom } from "./room";

const app = new Hono<{ Bindings: Env }>();

app.get("/", (c) => c.json({ ok: true, service: "shopping-list-api" }));
app.get("/healthz", (c) => c.text("ok"));

app.route("/auth", authRoutes);
app.route("/v1/me", meRoutes);
app.route("/v1/items", itemsRoutes);
app.route("/v1/households", householdsRoutes);
app.route("/v1/households", realtimeRoutes);

app.onError((err, c) => {
  console.error("Unhandled error:", err);
  return c.json({ error: "internal_error", detail: err.message }, 500);
});

export default app;
