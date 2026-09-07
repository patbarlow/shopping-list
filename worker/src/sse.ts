/**
 * Reading Anthropic's streaming responses.
 *
 * The receipt scan streams so each product can be shown as it is read, which
 * means pulling the text out of a server-sent event stream: frames arrive split
 * across arbitrary chunk boundaries, interleaved with pings and other event
 * types that carry no text.
 */

/** Yield the text of each `text_delta` in an Anthropic SSE response body. */
export async function* anthropicTextDeltas(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += value;
      const lines = buffer.split("\n");
      // The last piece may be half a frame — hold it for the next chunk.
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        try {
          const event = JSON.parse(payload) as {
            type?: string;
            delta?: { type?: string; text?: string };
          };
          if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
            yield event.delta.text ?? "";
          }
        } catch {
          // Ignore a frame we can't read; the next one resyncs.
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}
