"""Constants for the Shopping List (Cloudflare) integration."""
from datetime import timedelta

DOMAIN = "shopping_list_cf"

CONF_API_TOKEN = "api_token"
CONF_HOUSEHOLD_ID = "household_id"
CONF_HOUSEHOLD_NAME = "household_name"
CONF_WEBHOOK_ID = "webhook_id"
CONF_WEBHOOK_SECRET = "webhook_secret"

# Primary sync is webhook push from the Worker; this is only a safety net in
# case a webhook delivery is ever missed (dropped request, HA restart, etc).
FALLBACK_POLL_INTERVAL = timedelta(minutes=20)

SIGNAL_ITEMS_UPDATED = f"{DOMAIN}_items_updated"
