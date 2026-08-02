import type { Env } from "./env";
import type { ShoppingItem } from "./db";

// SQLite stores booleans as 0/1 integers; convert to JSON boolean for HA (mirrors items.ts toResponse).
function toResponse(item: ShoppingItem): object {
  return { ...item, checked: item.checked === 1 };
}

// Pushes a create/update/delete event to Home Assistant so the todo entity there
// stays in sync without waiting on its fallback poll. Best-effort: HA sync is optional
// and must never fail or block a request to the apps.
export async function notifyHomeAssistant(
  env: Env,
  action: "create" | "update" | "delete",
  item: ShoppingItem,
): Promise<void> {
  if (!env.HA_WEBHOOK_URL) return;

  try {
    await fetch(env.HA_WEBHOOK_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(env.HA_WEBHOOK_SECRET ? { "X-Webhook-Secret": env.HA_WEBHOOK_SECRET } : {}),
      },
      body: JSON.stringify({ action, item: toResponse(item) }),
    });
  } catch (e) {
    console.error("[ha-webhook] failed:", e);
  }
}
