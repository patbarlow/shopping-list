"""The Shopping List (Cloudflare) integration."""
from __future__ import annotations

import functools
import logging

from aiohttp import web
from homeassistant.components import webhook
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_URL, Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.dispatcher import async_dispatcher_send

from .api import ShoppingListApiClient
from .const import (
    CONF_API_TOKEN,
    CONF_HOUSEHOLD_ID,
    CONF_WEBHOOK_ID,
    CONF_WEBHOOK_SECRET,
    DOMAIN,
    SIGNAL_ITEMS_UPDATED,
)

_LOGGER = logging.getLogger(__name__)

PLATFORMS = [Platform.TODO]


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    session = async_get_clientsession(hass)
    client = ShoppingListApiClient(
        session, entry.data[CONF_URL], entry.data[CONF_API_TOKEN]
    )

    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = {
        "client": client,
        "household_id": entry.data[CONF_HOUSEHOLD_ID],
    }

    webhook.async_register(
        hass,
        DOMAIN,
        entry.title,
        entry.data[CONF_WEBHOOK_ID],
        functools.partial(_handle_webhook, entry.entry_id, entry.data[CONF_WEBHOOK_SECRET]),
    )

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    webhook.async_unregister(hass, entry.data[CONF_WEBHOOK_ID])
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        hass.data[DOMAIN].pop(entry.entry_id, None)
    return unloaded


async def _handle_webhook(
    entry_id: str,
    expected_secret: str,
    hass: HomeAssistant,
    webhook_id: str,
    request: web.Request,
) -> web.Response:
    """Called when the Worker POSTs a create/update/delete event.

    Just nudges the todo entity to refresh from the API rather than trying to
    patch state from the payload — keeps this handler trivial and correct
    even if the payload shape changes.
    """
    if expected_secret and request.headers.get("X-Webhook-Secret") != expected_secret:
        return web.Response(status=401)

    try:
        payload = await request.json()
    except ValueError:
        return web.Response(status=400)

    _LOGGER.debug("Shopping list webhook received: %s", payload.get("action"))
    async_dispatcher_send(hass, f"{SIGNAL_ITEMS_UPDATED}_{entry_id}")
    return web.Response(status=200)
