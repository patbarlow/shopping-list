"""Thin async client for the shopping-list-api Cloudflare Worker."""
from __future__ import annotations

from typing import Any

from aiohttp import ClientError, ClientSession, ClientTimeout

TIMEOUT = ClientTimeout(total=10)


class ShoppingListApiError(Exception):
    """Raised for any failure talking to the Worker."""


class ShoppingListAuthError(ShoppingListApiError):
    """Raised when the bearer token is rejected (401)."""


class ShoppingListApiClient:
    """Wraps the /v1 REST endpoints used by this integration."""

    def __init__(self, session: ClientSession, base_url: str, api_token: str) -> None:
        self._session = session
        self._base_url = base_url.rstrip("/")
        self._headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json",
        }

    async def _request(
        self, method: str, path: str, *, json: dict[str, Any] | None = None
    ) -> Any:
        url = f"{self._base_url}{path}"
        try:
            async with self._session.request(
                method, url, headers=self._headers, json=json, timeout=TIMEOUT
            ) as resp:
                if resp.status == 401:
                    raise ShoppingListAuthError(f"{method} {path} -> 401")
                if resp.status >= 400:
                    body = await resp.text()
                    raise ShoppingListApiError(f"{method} {path} -> {resp.status}: {body}")
                if resp.status == 204:
                    return None
                return await resp.json()
        except ClientError as err:
            raise ShoppingListApiError(f"{method} {path} failed: {err}") from err

    async def get_household(self) -> dict[str, Any] | None:
        """GET /v1/households/mine — used during config flow validation."""
        data = await self._request("GET", "/v1/households/mine")
        return data.get("household")

    async def get_items(self, household_id: str) -> list[dict[str, Any]]:
        data = await self._request("GET", f"/v1/items?household_id={household_id}")
        return data.get("items", [])

    async def create_item(
        self, household_id: str, name: str, notes: str | None = None
    ) -> dict[str, Any]:
        return await self._request(
            "POST",
            "/v1/items",
            json={"household_id": household_id, "name": name, "notes": notes},
        )

    async def update_item(
        self, item_id: str, *, name: str | None = None, notes: str | None = None
    ) -> dict[str, Any]:
        body: dict[str, Any] = {}
        if name is not None:
            body["name"] = name
        if notes is not None:
            body["notes"] = notes
        return await self._request("PATCH", f"/v1/items/{item_id}", json=body)

    async def complete_item(self, item_id: str) -> None:
        """Marks an item bought — removes it from the active list and records a purchase."""
        await self._request("POST", f"/v1/items/{item_id}/complete")

    async def delete_item(self, item_id: str) -> None:
        """Removes an item without recording a purchase."""
        await self._request("DELETE", f"/v1/items/{item_id}")
