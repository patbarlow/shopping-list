import test from "node:test";
import assert from "node:assert/strict";
import { HouseholdRoom } from "../src/room.ts";

const decoder = new TextDecoder();

test("live devices receive updates without waiting for a stalled reader", async () => {
  const room = new HouseholdRoom();
  const stalled = new AbortController();
  const live = new AbortController();
  await room.fetch(new Request("http://room/sse", { signal: stalled.signal }));
  const response = await room.fetch(new Request("http://room/sse", { signal: live.signal }));
  const reader = response.body!.getReader();
  try {
    assert.match(decoder.decode((await reader.read()).value), /connected/);
    const message = 'data: {"action":"delete","record":{"id":"milk"}}\n\n';
    const broadcast = room.fetch(new Request("http://room/broadcast", { method: "POST", body: message }));
    let timer: ReturnType<typeof setTimeout>;
    const received = await Promise.race([
      reader.read(),
      new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("live device was blocked")), 500); }),
    ]).finally(() => clearTimeout(timer));
    assert.equal(decoder.decode(received.value), message);
    stalled.abort();
    assert.equal((await broadcast).status, 200);
  } finally {
    stalled.abort();
    live.abort();
    await reader.cancel().catch(() => {});
  }
});

test("rooms isolate households and remove disconnected readers", async () => {
  const room = new HouseholdRoom();
  const abort = new AbortController();
  const response = await room.fetch(new Request("http://room/sse", { signal: abort.signal }));
  const reader = response.body!.getReader();
  await reader.read();
  abort.abort();
  await reader.cancel().catch(() => {});
  assert.equal((await room.fetch(new Request("http://room/broadcast", { method: "POST", body: "data: ignored\n\n" }))).status, 200);
  assert.equal((await new HouseholdRoom().fetch(new Request("http://room/broadcast", { method: "POST", body: "data: isolated\n\n" }))).status, 200);
});
