// Exercise cache expiry/retry without contacting any external environment.
// node scripts/verify-runtime-config.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = (await readFile(new URL('../site/public/legacy/conference-client.js', import.meta.url), 'utf8'))
  .replace(/^import .*\n/, '').replaceAll('export ', '');
const config = { url: 'https://example.test', publishableKey: 'public-test-key' };
let now = 1_000_000, stored = null, calls = 0, fail = false, blocked = false;
const context = vm.createContext({
  Intl, Date: class extends Date { static now() { return now; } },
  window: { sessionStorage: {
    getItem() { if (blocked) throw Error('blocked'); return stored; },
    setItem(key, value) { if (blocked) throw Error('blocked'); stored = value; },
  } },
  fetch: async () => { calls++; return { ok: !fail, json: async () => config }; },
});
vm.runInContext(source, context);
const load = () => vm.runInContext('conferenceConfig()', context);
await Promise.all([load(), load()]);
assert.equal(calls, 1, 'Concurrent callers share one request');
assert.equal((await load()).url, config.url);
assert.equal(calls, 1, 'Fresh nested cache survives another call');
now += 300_000;
await load();
assert.equal(calls, 2, 'Expired cache refreshes within the same document');
for (const invalid of ['{broken', JSON.stringify({ cachedAt: now, data: {} }),
  JSON.stringify({ cachedAt: 'invalid', data: config }), JSON.stringify({ cachedAt: now + 1, data: config })]) {
  stored = invalid;
  const before = calls;
  await load();
  assert.equal(calls, before + 1, 'Invalid cache recovers through the API');
}
blocked = true;
const beforeBlocked = calls;
await load();
assert.equal(calls, beforeBlocked + 1, 'Storage denial does not prevent loading');
blocked = false; stored = null; fail = true;
await assert.rejects(load(), /사이트 데이터 연결/);
fail = false;
assert.equal((await load()).publishableKey, config.publishableKey, 'A failed request can be retried');
console.log('PASS: concurrent requests, cache hit, expiry, malformed/invalid/future cache, blocked storage, retry');
