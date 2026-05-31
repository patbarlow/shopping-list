export class HouseholdRoom {
  private sessions = new Map<string, WritableStreamDefaultWriter<Uint8Array>>();

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/sse") {
      return this.handleSSE(request);
    }

    if (request.method === "POST" && url.pathname === "/broadcast") {
      return this.handleBroadcast(request);
    }

    return new Response("not found", { status: 404 });
  }

  private handleSSE(request: Request): Response {
    const sessionId = crypto.randomUUID();
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    const encoder = new TextEncoder();

    this.sessions.set(sessionId, writer);

    request.signal.addEventListener("abort", () => {
      writer.close().catch(() => {});
      this.sessions.delete(sessionId);
    });

    // Send an initial comment so the client knows the connection is live.
    // The Swift side treats the first bytes as the "connected" signal.
    writer.write(encoder.encode(": connected\n\n")).catch(() => {});

    return new Response(readable, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
      },
    });
  }

  private async handleBroadcast(request: Request): Promise<Response> {
    const message = await request.text();
    const encoded = new TextEncoder().encode(message);

    const dead: string[] = [];
    for (const [id, writer] of this.sessions) {
      try {
        await writer.write(encoded);
      } catch {
        dead.push(id);
      }
    }
    dead.forEach((id) => this.sessions.delete(id));

    return new Response("ok");
  }
}
