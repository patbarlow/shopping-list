import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { issueSession } from "../src/session.ts";

// Exercise the actual Worker, D1 transactions, authentication and Durable Object
// streams in workerd. No live account, household or network AI calls are used.
test("two open clients receive edits, completion and Undo; retries preserve history", { timeout: 30_000 }, async () => {
  const bundled = await build({ entryPoints: ["src/index.ts"], bundle: true, format: "esm", write: false });
  const secret = "local-sync-test-secret-not-a-production-secret";
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: "shopping-sync-test",
    modules: true,
    script: bundled.outputFiles[0].text,
    compatibilityDate: "2024-12-01",
    d1Databases: ["DB"],
    durableObjects: { HOUSEHOLD_ROOMS: "HouseholdRoom" },
    bindings: { SESSION_SECRET: secret },
  }));
  const readers: ReadableStreamDefaultReader<Uint8Array>[] = [];
  try {
    const db = await mf.getD1Database("DB");
    const schema = await readFile("schema.sql", "utf8");
    // D1 exec accepts one SQL statement per line.
    await db.exec(schema.replace(/\n/g, " ").replace(/;/g, ";\n"));
    await db.exec("CREATE TABLE receipt_line_items (id TEXT PRIMARY KEY, purchase_history_id TEXT REFERENCES purchase_history(id));");
    await db.exec(`
      INSERT INTO users VALUES ('pat', 'pat@example.test', 'Pat', 'now', 'now'), ('juliet', 'juliet@example.test', 'Juliet', 'now', 'now'), ('outsider', 'other@example.test', 'Other', 'now', 'now');
      INSERT INTO households VALUES ('home', 'Home', 'HOME', 'weekly', 'now');
      INSERT INTO household_members VALUES ('p', 'home', 'pat', 'now'), ('j', 'home', 'juliet', 'now');
      INSERT INTO products VALUES ('milk-product', 'home', 'Milk', 'Dairy & Eggs', 5, 'now', 'now');
    `);
    const tokens = Object.fromEntries(await Promise.all(["pat", "juliet", "outsider"].map(async user => [user, await issueSession(user, secret)])));
    async function request(path: string, method = "GET", body?: object, user = "pat") {
      return mf.dispatchFetch(`http://local${path}`, {
        method,
        headers: { Authorization: `Bearer ${tokens[user]}`, "Content-Type": "application/json" },
        body: body ? JSON.stringify(body) : undefined,
      });
    }
    function streamEvents(reader: ReadableStreamDefaultReader<Uint8Array>) {
      let buffer = "";
      const decoder = new TextDecoder();
      return async () => {
        for (;;) {
          const boundary = buffer.indexOf("\n\n");
          if (boundary >= 0) {
            const frame = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const data = frame.split("\n").find(line => line.startsWith("data: "));
            if (data) return JSON.parse(data.slice(6));
            continue;
          }
          const next = await reader.read();
          assert.equal(next.done, false, "stream ended unexpectedly");
          buffer += decoder.decode(next.value, { stream: true });
        }
      };
    }
    for (const user of ["pat", "juliet"]) {
      const response = await request("/v1/households/home/realtime", "GET", undefined, user);
      assert.equal(response.status, 200);
      const reader = response.body!.getReader();
      readers.push(reader);
      assert.match(new TextDecoder().decode((await reader.read()).value), /connected/);
    }
    const nextEvents = readers.map(streamEvents);
    async function expectEvent(action: string, checked: boolean, name?: string) {
      const events = await Promise.all(nextEvents.map(next => next()));
      for (const event of events) {
        assert.equal(event.action, action);
        assert.equal(event.record.checked, checked);
        if (name) assert.equal(event.record.name, name);
      }
    }
    assert.equal((await request("/v1/households/home/realtime", "GET", undefined, "outsider")).status, 403);
    assert.equal((await request("/v1/items", "POST", { id: "milk", household_id: "home", name: "Milk" })).status, 201);
    await expectEvent("create", false, "Milk");
    assert.equal((await request("/v1/items/milk", "PATCH", { quantity: "2", notes: "Oat" })).status, 200);
    await expectEvent("update", false);
    assert.equal((await request("/v1/items/milk/complete", "POST")).status, 204);
    await expectEvent("delete", true);
    assert.deepEqual((await (await request("/v1/items?household_id=home")).json()).items, []);
    // Retrying the completion and a simultaneous second shopper must not create
    // multiple purchases for one tick.
    const retries = await Promise.all([
      request("/v1/items/milk/complete", "POST"),
      request("/v1/items/milk/complete", "POST", undefined, "juliet"),
    ]);
    assert.ok(retries.every(r => r.status === 204));
    await expectEvent("delete", true);
    await expectEvent("delete", true);
    assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM purchase_history").first()).n, 1);
    assert.equal((await request("/v1/items/milk/undo-complete", "POST", undefined, "outsider")).status, 403);
    const undone = await request("/v1/items/milk/undo-complete", "POST");
    assert.equal(undone.status, 200);
    assert.equal((await undone.json()).quantity, "2");
    await expectEvent("update", false);
    assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM purchase_history").first()).n, 0);
    assert.equal((await (await request("/v1/items?household_id=home")).json()).items.length, 1);
    assert.equal((await request("/v1/items/milk/complete", "POST")).status, 204);
    await expectEvent("delete", true);
    await db.prepare("INSERT INTO receipt_line_items VALUES ('receipt', 'list:milk')").run();
    assert.equal((await request("/v1/items/milk/undo-complete", "POST")).status, 409);
    assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM purchase_history").first()).n, 1);
  } finally {
    await Promise.all(readers.map(reader => reader.cancel().catch(() => {})));
    await mf.dispose();
  }
});
