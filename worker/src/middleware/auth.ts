import type { MiddlewareHandler } from "hono";
import type { Env } from "../env";
import { verifySession } from "../session";
import { getUser, type User } from "../db";

export interface AuthVariables {
  user: User;
}

export const requireAuth: MiddlewareHandler<{
  Bindings: Env;
  Variables: AuthVariables;
}> = async (c, next) => {
  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return c.json({ error: "missing_bearer" }, 401);
  }
  const token = authHeader.slice("Bearer ".length);

  let userId: string;
  try {
    userId = await verifySession(token, c.env.SESSION_SECRET);
  } catch {
    return c.json({ error: "invalid_session" }, 401);
  }

  const user = await getUser(c.env.DB, userId);
  if (!user) return c.json({ error: "user_not_found" }, 401);

  c.set("user", user);
  return next();
};
