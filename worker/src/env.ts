export interface Env {
  DB: D1Database;
  HOUSEHOLD_ROOMS: DurableObjectNamespace;

  SESSION_SECRET: string;
  ANTHROPIC_API_KEY: string;
  RESEND_API_KEY: string;
  RESEND_FROM?: string;
}
