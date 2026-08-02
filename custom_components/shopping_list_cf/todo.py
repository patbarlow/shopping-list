"""Todo platform for Shopping List (Cloudflare)."""
from __future__ import annotations

import logging

from homeassistant.components.todo import (
    TodoItem,
    TodoItemStatus,
    TodoListEntity,
    TodoListEntityFeature,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.event import async_track_time_interval

from .api import ShoppingListApiClient, ShoppingListApiError
from .const import CONF_HOUSEHOLD_ID, DOMAIN, FALLBACK_POLL_INTERVAL, SIGNAL_ITEMS_UPDATED

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    data = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([CloudflareShoppingListEntity(data["client"], entry)])


class CloudflareShoppingListEntity(TodoListEntity):
    """A todo list backed by the shopping-list-api Worker.

    "Completing" an item here calls POST /v1/items/:id/complete, which the
    backend treats as "bought it" — it records a purchase and removes the
    item from the active list rather than leaving it checked off. So
    completed items simply disappear rather than showing struck-through.
    """

    _attr_has_entity_name = True
    _attr_name = None
    _attr_should_poll = False
    _attr_supported_features = (
        TodoListEntityFeature.CREATE_TODO_ITEM
        | TodoListEntityFeature.UPDATE_TODO_ITEM
        | TodoListEntityFeature.DELETE_TODO_ITEM
        | TodoListEntityFeature.SET_DESCRIPTION_ON_ITEM
    )

    def __init__(self, client: ShoppingListApiClient, entry: ConfigEntry) -> None:
        self._client = client
        self._household_id = entry.data[CONF_HOUSEHOLD_ID]
        self._entry_id = entry.entry_id
        self._attr_unique_id = f"{entry.entry_id}_todo"
        self._attr_todo_items = []
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=entry.title,
            manufacturer="Shopping List (Cloudflare)",
        )
        self._unsub_dispatcher = None
        self._unsub_interval = None

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        self._unsub_dispatcher = async_dispatcher_connect(
            self.hass, f"{SIGNAL_ITEMS_UPDATED}_{self._entry_id}", self._handle_push_update
        )
        self._unsub_interval = async_track_time_interval(
            self.hass, self._handle_scheduled_refresh, FALLBACK_POLL_INTERVAL
        )
        await self._async_refresh_items()

    async def async_will_remove_from_hass(self) -> None:
        if self._unsub_dispatcher:
            self._unsub_dispatcher()
        if self._unsub_interval:
            self._unsub_interval()

    @callback
    def _handle_push_update(self) -> None:
        self.hass.async_create_task(self._async_refresh_items())

    async def _handle_scheduled_refresh(self, now) -> None:
        await self._async_refresh_items()

    async def _async_refresh_items(self) -> None:
        try:
            items = await self._client.get_items(self._household_id)
        except ShoppingListApiError as err:
            _LOGGER.warning("Failed to refresh shopping list: %s", err)
            return
        self._attr_todo_items = [self._to_todo_item(item) for item in items]
        self.async_write_ha_state()

    @staticmethod
    def _to_todo_item(item: dict) -> TodoItem:
        return TodoItem(
            uid=item["id"],
            summary=item["name"],
            status=TodoItemStatus.NEEDS_ACTION,
            description=item.get("notes"),
        )

    async def async_create_todo_item(self, item: TodoItem) -> None:
        # Mirrors the dedup check the iOS app and Siri Shortcut each do
        # client-side — the API itself has no unique constraint on active
        # item names, so without this a duplicate voice command creates a
        # second row instead of being a no-op.
        summary_lower = item.summary.strip().lower()
        if any(i.summary.strip().lower() == summary_lower for i in self._attr_todo_items):
            _LOGGER.debug("Skipping create — %s is already on the list", item.summary)
            return

        created = await self._client.create_item(
            self._household_id, item.summary, item.description
        )
        # Update local state immediately from the response rather than waiting
        # on the webhook/poll — HA-initiated changes should reflect instantly.
        self._attr_todo_items = [*self._attr_todo_items, self._to_todo_item(created)]
        self.async_write_ha_state()

    async def async_update_todo_item(self, item: TodoItem) -> None:
        if item.status == TodoItemStatus.COMPLETED:
            await self._client.complete_item(item.uid)
            self._attr_todo_items = [
                i for i in self._attr_todo_items if i.uid != item.uid
            ]
        else:
            updated = await self._client.update_item(
                item.uid, name=item.summary, notes=item.description
            )
            new_item = self._to_todo_item(updated)
            self._attr_todo_items = [
                new_item if i.uid == item.uid else i for i in self._attr_todo_items
            ]
        self.async_write_ha_state()

    async def async_delete_todo_items(self, uids: list[str]) -> None:
        for uid in uids:
            await self._client.delete_item(uid)
        self._attr_todo_items = [
            i for i in self._attr_todo_items if i.uid not in uids
        ]
        self.async_write_ha_state()
