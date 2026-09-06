import assert from "node:assert/strict";
import { test } from "node:test";
import { anthropicTextDeltas } from "../src/sse.ts";

function streamOf(chunks: string[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
}

function frame(text: string): string {
  return `event: content_block_delta\ndata: ${JSON.stringify({
    type: "content_block_delta",
    index: 0,
    delta: { type: "text_delta", text },
  })}\n\n`;
}

async function collect(chunks: string[]): Promise<string> {
  let out = "";
  for await (const delta of anthropicTextDeltas(streamOf(chunks))) out += delta;
  return out;
}

test("reads text deltas out of the event stream", async () => {
  const body = [
    'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1"}}\n\n',
    frame('{"type":"receipt",'),
    frame('"store_name":"ALDI STORES"}\n'),
    'event: message_stop\ndata: {"type":"message_stop"}\n\n',
  ];
  assert.equal(await collect(body), '{"type":"receipt","store_name":"ALDI STORES"}\n');
});

test("a frame split across chunk boundaries still arrives whole", async () => {
  const whole = frame("Milk Almond UHT 1L");
  for (const size of [1, 5, 23, 100]) {
    const chunks: string[] = [];
    for (let i = 0; i < whole.length; i += size) chunks.push(whole.slice(i, i + size));
    assert.equal(await collect(chunks), "Milk Almond UHT 1L", `chunk size ${size}`);
  }
});

test("ignores pings, other event types and unparsable frames", async () => {
  const body = [
    "event: ping\ndata: {\"type\":\"ping\"}\n\n",
    'data: {"type":"content_block_start","content_block":{"type":"text","text":""}}\n\n',
    "data: not json at all\n\n",
    frame("kept"),
    "data: [DONE]\n\n",
  ];
  assert.equal(await collect(body), "kept");
});

test("an empty stream yields nothing", async () => {
  assert.equal(await collect([]), "");
});
