import { Hono } from "hono";
import type { Env } from "./env";

import authRoutes from "./routes/auth";
import meRoutes from "./routes/me";
import itemsRoutes from "./routes/items";
import householdsRoutes from "./routes/households";
import realtimeRoutes from "./routes/realtime";
import recipesRoutes from "./routes/recipes";
import receiptsRoutes from "./routes/receipts";
import priceCheckRoutes from "./routes/price-check";
import insightsRoutes from "./routes/insights";
import { errorCode, logError } from "./log";

export { HouseholdRoom } from "./room";

// Accept the trailing slash sent by released iOS build 201 as well as the
// canonical paths. Authentication middleware alone could previously return 401
// for that URL while authenticated requests fell through to a 404.
const app = new Hono<{ Bindings: Env }>({ strict: false });

app.get("/", (c) => c.json({ ok: true, service: "shopping-list-api" }));
app.get("/healthz", (c) => c.text("ok"));

app.route("/auth", authRoutes);
app.route("/v1/me", meRoutes);
app.route("/v1/items", itemsRoutes);
app.route("/v1/households", householdsRoutes);
app.route("/v1/households", realtimeRoutes);
app.route("/v1/recipes", recipesRoutes);
app.route("/v1/receipts", receiptsRoutes);
app.route("/v1/insights", insightsRoutes);
app.route("/v1/price-check", priceCheckRoutes);

app.onError((err, c) => {
  logError("request_failed", {
    method: c.req.method,
    path: new URL(c.req.url).pathname,
    errorCode: errorCode(err),
  });
  return c.json({ error: "internal_error" }, 500);
});

export default app;
