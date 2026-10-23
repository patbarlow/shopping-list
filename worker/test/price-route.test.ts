import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { SignJWT } from 'jose';

// Test the real mounted router with auth. An unauthenticated check or a
// subrouter-only test misses Hono's trailing-slash routing difference.
const bundle = await build({ entryPoints: [fileURLToPath(new URL('../src/index.ts', import.meta.url))], bundle: true,
  platform: 'node', format: 'esm', write: false });
const { default: app } = await import('data:text/javascript;base64,' + Buffer.from(bundle.outputFiles[0].text).toString('base64'));
const secret = 'test-price-check-session-secret';
const token = await new SignJWT({ sub: 'user-1' }).setProtectedHeader({ alg: 'HS256' })
  .setIssuer('shopping-list-api').setExpirationTime('5m').sign(new TextEncoder().encode(secret));
function env(member = true) {
  return { SESSION_SECRET: secret, ANTHROPIC_API_KEY: 'test-provider-key', DB: {
    prepare(sql: string) { return { bind() { return { async first() {
      if (sql.includes('household_members')) return member ? { exists: 1 } : null;
      return { id: 'user-1', email: 'test@example.com', name: 'Test' };
    } }; } }; }
  } };
}
function request(path: string, body: object, authenticated = true) {
  return new Request('https://example.test' + path, { method: 'POST',
    headers: { 'content-type': 'application/json', ...(authenticated ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body) });
}
const offer = { name: 'Red Bull Energy Drink', price: 9.83, size: 1000, unit: 'mL', question: null };

test('authenticated image-only price checks reach the mounted route with either slash form', async () => {
  const realFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (_url, init) => {
    calls++;
    const body = JSON.parse(String(init?.body));
    assert.equal(body.messages[0].content[0].source.media_type, 'image/jpeg');
    assert.equal(JSON.parse(body.messages[0].content[1].text).question, '');
    return Response.json({ content: [{ type: 'text', text: JSON.stringify(offer) }] });
  };
  try {
    for (const path of ['/v1/price-check', '/v1/price-check/']) {
      const result = await app.fetch(request(path, { household_id: 'home', image_base64: '/9j/AA==', text: '' }), env());
      assert.equal(result.status, 200, path);
      assert.deepEqual(await result.json(), offer);
    }
    assert.equal(calls, 2);
  } finally { globalThis.fetch = realFetch; }
});

test('both price-check paths enforce authentication, membership and input validation', async () => {
  for (const path of ['/v1/price-check', '/v1/price-check/']) {
    const body = { household_id: 'home', text: 'Milk $4' };
    assert.equal((await app.fetch(request(path, body, false), env())).status, 401);
    assert.equal((await app.fetch(request(path, body), env(false))).status, 403);
    assert.equal((await app.fetch(request(path, { household_id: 'home', text: '' }), env())).status, 400);
  }
});

test('mounted price route reports provider failure and unreadable offers without a fake result', async () => {
  const realFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => new Response('unavailable', { status: 503 });
    const failed = await app.fetch(request('/v1/price-check', { household_id: 'home', text: 'Milk $4' }), env());
    assert.equal(failed.status, 503);
    assert.deepEqual(await failed.json(), { error: 'price_reader_unavailable' });
    globalThis.fetch = async () => Response.json({ content: [{ type: 'text', text: '{"name":""}' }] });
    const unreadable = await app.fetch(request('/v1/price-check', { household_id: 'home', text: 'Milk $4' }), env());
    assert.equal(unreadable.status, 422);
  } finally { globalThis.fetch = realFetch; }
});
