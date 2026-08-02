"""Config flow for Shopping List (Cloudflare)."""
from __future__ import annotations

import secrets
from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.components import webhook
from homeassistant.const import CONF_URL
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .api import ShoppingListApiClient, ShoppingListApiError, ShoppingListAuthError
from .const import (
    CONF_API_TOKEN,
    CONF_HOUSEHOLD_ID,
    CONF_HOUSEHOLD_NAME,
    CONF_WEBHOOK_ID,
    CONF_WEBHOOK_SECRET,
    DOMAIN,
)

STEP_USER_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_URL, default="https://shopping-list-api.pat-barlow.workers.dev"): str,
        vol.Required(CONF_API_TOKEN): str,
    }
)


class ShoppingListCfConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Handle setup: verify the token, then hand back the webhook URL to configure."""

    VERSION = 1

    def __init__(self) -> None:
        self._base_url: str | None = None
        self._api_token: str | None = None
        self._household_id: str | None = None
        self._household_name: str | None = None
        self._webhook_id: str | None = None
        self._webhook_secret: str | None = None

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> config_entries.ConfigFlowResult:
        errors: dict[str, str] = {}

        if user_input is not None:
            base_url = user_input[CONF_URL].rstrip("/")
            api_token = user_input[CONF_API_TOKEN]

            session = async_get_clientsession(self.hass)
            client = ShoppingListApiClient(session, base_url, api_token)
            try:
                household = await client.get_household()
            except ShoppingListAuthError:
                errors["base"] = "invalid_auth"
            except ShoppingListApiError:
                errors["base"] = "cannot_connect"
            else:
                if not household:
                    errors["base"] = "no_household"
                else:
                    await self.async_set_unique_id(household["id"])
                    self._abort_if_unique_id_configured()

                    self._base_url = base_url
                    self._api_token = api_token
                    self._household_id = household["id"]
                    self._household_name = household["name"]
                    self._webhook_id = webhook.async_generate_id()
                    self._webhook_secret = secrets.token_hex(16)

                    return await self.async_step_webhook_info()

        return self.async_show_form(
            step_id="user", data_schema=STEP_USER_SCHEMA, errors=errors
        )

    async def async_step_webhook_info(
        self, user_input: dict[str, Any] | None = None
    ) -> config_entries.ConfigFlowResult:
        """Show the generated webhook URL/secret to set on the Worker, then finish."""
        if user_input is not None:
            return self.async_create_entry(
                title=self._household_name or "Shopping List",
                data={
                    CONF_URL: self._base_url,
                    CONF_API_TOKEN: self._api_token,
                    CONF_HOUSEHOLD_ID: self._household_id,
                    CONF_HOUSEHOLD_NAME: self._household_name,
                    CONF_WEBHOOK_ID: self._webhook_id,
                    CONF_WEBHOOK_SECRET: self._webhook_secret,
                },
            )

        webhook_url = webhook.async_generate_url(self.hass, self._webhook_id)

        return self.async_show_form(
            step_id="webhook_info",
            data_schema=vol.Schema({}),
            description_placeholders={
                "webhook_url": webhook_url,
                "webhook_secret": self._webhook_secret,
            },
        )
