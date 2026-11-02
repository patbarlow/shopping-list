export class HouseholdRoom {
  private sessions = new Map<string, {
    writer: WritableStreamDefaultWriter<Uint8Array>;
    dispose: () => void;
  }>();

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

    const dispose = () => {
      clearInterval(heartbeat);
      request.signal.removeEventListener("abort", dispose);
      this.sessions.delete(sessionId);
      writer.abort().catch(() => {});
    };
    // Keep idle foreground connections live and detect abandoned readers.
    const heartbeat = setInterval(() => {
      void this.send(sessionId, encoder.encode(": heartbeat\n\n"));
    }, 20_000);
    this.sessions.set(sessionId, { writer, dispose });
    request.signal.addEventListener("abort", dispose, { once: true });
    writer.closed.catch(dispose);
    if (request.signal.aborted) dispose();

    // Send an initial comment so the client knows the connection is live.
    // The Swift side treats the first bytes as the "connected" signal.
    void this.send(sessionId, encoder.encode(": connected\n\n"));

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

    // A suspended phone must not hold up every other household member.
    await Promise.all([...this.sessions.keys()].map((id) => this.send(id, encoded)));

    return new Response("ok");
  }

  private async send(id: string, data: Uint8Array): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) return;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        session.writer.write(data),
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(new Error("slow_realtime_reader")), 5_000);
        }),
      ]);
    } catch {
      session.dispose();
    } finally {
      if (timeout !== undefined) clearTimeout(timeout);
    }
  }
}
