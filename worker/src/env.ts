export interface Env {
  DB: D1Database;
  HOUSEHOLD_ROOMS: DurableObjectNamespace;

  SESSION_SECRET: string;
  ANTHROPIC_API_KEY: string;
  RESEND_API_KEY: string;
  RESEND_FROM?: string;

  // Home Assistant push-sync webhook (optional — HA integration only)
  HA_WEBHOOK_URL?: string;
  HA_WEBHOOK_SECRET?: string;
}
