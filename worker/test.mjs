// Exercises the Worker's request handling against a fake KV, with no
// Cloudflare and no wrangler. Run: node worker/test.mjs
//
// The gating is the point: /invite is the only way to learn the domain, and
// /available must not answer without a good code — otherwise anyone who
// installed the app could probe which names are taken on someone's domain.
import worker from './src/index.js';

let passed = 0, failed = 0;

function check(label, ok, detail = '') {
  if (ok) {
    passed++;
    console.log(`  PASS  ${label}`);
  } else {
    failed++;
    console.log(`  FAIL  ${label}  ${detail}`);
  }
}

/** Enough of a KV namespace for the paths under test. */
function fakeKv(seed = {}) {
  const store = new Map(Object.entries(seed).map(([k, v]) => [k, JSON.stringify(v)]));
  return {
    store,
    async get(key, type) {
      const raw = store.get(key);
      if (raw === undefined) return null;
      return type === 'json' ? JSON.parse(raw) : raw;
    },
    async put(key, value) { store.set(key, value); },
    async delete(key) { store.delete(key); },
  };
}

function env(seed) {
  return {
    CLAIMS: fakeKv(seed),
    ROOT_DOMAIN: 'thapaalish.com.np',
    CF_API_TOKEN: 'unused-here',
  };
}

const call = (e, path) =>
  worker.fetch(new Request(`https://provision.example${path}`), e);

const body = async (res) => [res.status, await res.json()];

const GOOD = { uses: 0, maxUses: 3, label: 'family' };

console.log('\n-- /invite --');
{
  const e = env({ 'invite:ABC123': GOOD });

  let [status, out] = await body(await call(e, '/invite?code=ABC123'));
  check('a good code is accepted', status === 200 && out.ok === true, `${status} ${JSON.stringify(out)}`);
  check('it answers with the domain', out.domain === 'thapaalish.com.np', out.domain);
  check('it reports uses left', out.remaining === 3, `${out.remaining}`);

  check('checking a code does not spend it',
    JSON.parse(e.CLAIMS.store.get('invite:ABC123')).uses === 0);

  [status, out] = await body(await call(e, '/invite?code=abc123'));
  check('codes are not case sensitive', status === 200 && out.ok === true, `${status}`);

  [status, out] = await body(await call(e, '/invite?code=NOPE99'));
  check('an unknown code is refused', status === 403 && out.ok === false, `${status}`);
  check('refusal says why', out.error === 'invalid invite code', out.error);
  check('refusal does not leak the domain', out.domain === undefined, `${out.domain}`);

  [status, out] = await body(await call(e, '/invite'));
  check('no code at all is refused', status === 403, `${status}`);
  check('no code does not leak the domain', out.domain === undefined, `${out.domain}`);
}

console.log('\n-- codes that should not work --');
{
  const e = env({
    'invite:USEDUP': { uses: 2, maxUses: 2 },
    'invite:GONE11': { uses: 0, maxUses: 5, revoked: true },
    'invite:LASTGO': { uses: 4, maxUses: 5 },
  });

  let [status, out] = await body(await call(e, '/invite?code=USEDUP'));
  check('an exhausted code is refused', status === 403, `${status}`);
  check('exhausted says so', out.error === 'this invite code is used up', out.error);

  [status, out] = await body(await call(e, '/invite?code=GONE11'));
  check('a revoked code is refused', status === 403, `${status}`);
  check('revoked says so', out.error === 'this invite code was revoked', out.error);

  [status, out] = await body(await call(e, '/invite?code=LASTGO'));
  check('a code on its last use still works', status === 200 && out.ok === true, `${status}`);
  check('and reports one left', out.remaining === 1, `${out.remaining}`);
}

console.log('\n-- /available is gated on the code --');
{
  const e = env({
    'invite:ABC123': GOOD,
    'name:taken': { deviceId: 'someone-else', tunnelId: 'tun-1' },
  });

  let [status, out] = await body(await call(e, '/available?name=myfiles'));
  check('no code: refused', status === 403, `${status}`);
  check('no code: no hostname leaked', out.hostname === undefined, `${out.hostname}`);

  [status, out] = await body(await call(e, '/available?name=taken&code=NOPE99'));
  check('bad code: refused', status === 403, `${status}`);
  check('bad code: does not reveal that the name is taken',
    out.hostname === undefined && out.reason === 'invalid invite code', JSON.stringify(out));

  [status, out] = await body(await call(e, '/available?name=myfiles&code=ABC123'));
  check('good code: a free name is available', status === 200 && out.available === true, `${status}`);
  check('good code: hostname is name + domain',
    out.hostname === 'myfiles.thapaalish.com.np', out.hostname);

  [status, out] = await body(await call(e, '/available?name=taken&code=ABC123'));
  check('good code: a taken name is refused', out.available === false, JSON.stringify(out));
  check('taken says why', out.reason === 'already taken', out.reason);

  [status, out] = await body(await call(e, '/available?name=ab&code=ABC123'));
  check('a too-short name is refused', out.available === false, JSON.stringify(out));

  [status, out] = await body(await call(e, '/available?name=admin&code=ABC123'));
  check('a reserved name is refused', out.available === false, JSON.stringify(out));
  check('reserved says why', out.reason === 'that name is reserved', out.reason);

  [status, out] = await body(await call(e, '/available?name=provision&code=ABC123'));
  check('the Worker cannot be claimed out from under itself', out.available === false);
}

console.log('\n-- /rebind --');
{
  const post = (e, path, body) =>
    worker.fetch(new Request(`https://provision.example${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }), e);

  const seed = () => env({
    'name:tests': { deviceId: 'old-random-id', tunnelId: 'tun-7', inviteCode: 'ABC123' },
  });

  let e = seed();
  let [status, out] = await body(await post(e, '/rebind', {
    name: 'tests', deviceId: 'old-random-id', newDeviceId: 'a-derived-stable-id',
  }));
  check('a claim moves to the new id', status === 200 && out.ok === true, `${status}`);

  const after = JSON.parse(e.CLAIMS.store.get('name:tests'));
  check('the new id is stored', after.deviceId === 'a-derived-stable-id', after.deviceId);
  check('the tunnel is untouched', after.tunnelId === 'tun-7', after.tunnelId);

  // The point of the whole exercise: a reinstall arrives with the derived
  // id and must be recognised as the same phone.
  [status, out] = await body(await post(e, '/rebind', {
    name: 'tests', deviceId: 'a-derived-stable-id', newDeviceId: 'a-derived-stable-id',
  }));
  check('repeating it is harmless', status === 200 && out.ok === true, `${status}`);

  e = seed();
  [status, out] = await body(await post(e, '/rebind', {
    name: 'tests', deviceId: 'some-other-phone', newDeviceId: 'attacker-id',
  }));
  check('another device cannot take the claim', status === 403, `${status}`);
  check('and the claim is unchanged',
    JSON.parse(e.CLAIMS.store.get('name:tests')).deviceId === 'old-random-id');

  e = seed();
  [status] = await body(await post(e, '/rebind', {
    name: 'nosuchname', deviceId: 'old-random-id', newDeviceId: 'x'.repeat(10),
  }));
  check('an unknown name is a 404', status === 404, `${status}`);

  e = seed();
  [status] = await body(await post(e, '/rebind', {
    name: 'tests', deviceId: 'old-random-id', newDeviceId: 'short',
  }));
  check('a too-short new id is refused', status === 400, `${status}`);
  check('refusing leaves the claim alone',
    JSON.parse(e.CLAIMS.store.get('name:tests')).deviceId === 'old-random-id');

  e = seed();
  [status] = await body(await post(e, '/rebind', { name: 'tests' }));
  check('missing fields are refused', status === 400, `${status}`);
}

console.log('\n-- /recovery --');
{
  const ID = 'a'.repeat(43);
  const AUTH = 'b'.repeat(43);
  const OTHER_AUTH = 'c'.repeat(43);
  const BLOB = 'v1.bm9uY2U.Y2lwaGVydGV4dA';

  const send = (e, method, body, query = '') =>
    worker.fetch(new Request(`https://provision.example/recovery${query}`, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    }), e);

  let e = env({});
  let [status, out] = await body(await send(e, 'GET', undefined, `?id=${ID}`));
  check('no backup is a 404', status === 404, `${status}`);

  [status, out] = await body(await send(e, 'PUT', { id: ID, writeAuth: AUTH, blob: BLOB }));
  check('the first write claims the slot', status === 200 && out.ok === true, `${status}`);

  [status, out] = await body(await send(e, 'GET', undefined, `?id=${ID}`));
  check('it reads back', status === 200 && out.blob === BLOB, `${status}`);
  check('savedAt is recorded', typeof out.savedAt === 'number');

  // The one value stored here that grants anything. A reader does not need
  // it, so a reader does not get it.
  check('reading does not hand back the writeAuth', out.writeAuth === undefined);

  [status, out] = await body(await send(e, 'PUT', { id: ID, writeAuth: AUTH, blob: BLOB + 'x' }));
  check('the same device may overwrite', status === 200, `${status}`);
  [status, out] = await body(await send(e, 'GET', undefined, `?id=${ID}`));
  check('the overwrite took', out.blob === BLOB + 'x');

  [status, out] = await body(await send(e, 'PUT', { id: ID, writeAuth: OTHER_AUTH, blob: 'junk-blob' }));
  check('another caller cannot overwrite', status === 403, `${status}`);
  [status, out] = await body(await send(e, 'GET', undefined, `?id=${ID}`));
  check('and the backup is untouched', out.blob === BLOB + 'x', out.blob);

  console.log('\n-- /recovery refusals --');
  [status] = await body(await send(e, 'GET', undefined, '?id=short'));
  check('a malformed id is refused', status === 400, `${status}`);
  [status] = await body(await send(e, 'GET', undefined, '?id=' + 'x'.repeat(400)));
  check('an overlong id is refused', status === 400, `${status}`);
  [status] = await body(await send(e, 'GET', undefined, `?id=${'a/b'.padEnd(20, 'c')}`));
  check('a non-url-safe id is refused', status === 400, `${status}`);
  [status] = await body(await send(e, 'PUT', { id: ID, writeAuth: AUTH, blob: '' }));
  check('an empty backup is refused', status === 400, `${status}`);
  [status] = await body(await send(e, 'PUT', { id: ID, writeAuth: AUTH, blob: 'z'.repeat(70000) }));
  check('an oversized backup is refused', status === 413, `${status}`);
  [status] = await body(await send(e, 'PUT', { id: ID, blob: BLOB }));
  check('a write without auth is refused', status === 400, `${status}`);

  console.log('\n-- /recovery delete --');
  e = env({});
  await send(e, 'PUT', { id: ID, writeAuth: AUTH, blob: BLOB });
  [status] = await body(await send(e, 'DELETE', { id: ID, writeAuth: OTHER_AUTH }));
  check('another caller cannot delete', status === 403, `${status}`);
  check('so it is still there', e.CLAIMS.store.has(`recovery:${ID}`));

  [status, out] = await body(await send(e, 'DELETE', { id: ID, writeAuth: AUTH }));
  check('the owner can delete', status === 200 && out.ok === true, `${status}`);
  check('turning it off really removes it', !e.CLAIMS.store.has(`recovery:${ID}`));

  [status] = await body(await send(e, 'DELETE', { id: ID, writeAuth: AUTH }));
  check('deleting twice is harmless', status === 200, `${status}`);

  // What the Worker is holding, spelled out: ciphertext and two opaque ids.
  e = env({});
  await send(e, 'PUT', { id: ID, writeAuth: AUTH, blob: BLOB });
  const stored = JSON.parse(e.CLAIMS.store.get(`recovery:${ID}`));
  check('nothing but blob, writeAuth and savedAt is stored',
    Object.keys(stored).sort().join(',') === 'blob,savedAt,writeAuth',
    Object.keys(stored).join(','));
}

console.log('\n-- /release --');
{
  const post = (e, path, payload) =>
    worker.fetch(new Request(`https://provision.example${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }), e);

  // Stands in for api.cloudflare.com, recording what the Worker asked it to
  // do so the test can assert the resources were actually given back rather
  // than just the KV row dropped.
  const realFetch = globalThis.fetch;
  let cfCalls = [];
  let cfFails = null;
  globalThis.fetch = async (url, init = {}) => {
    const path = new URL(url).pathname + new URL(url).search;
    cfCalls.push(`${init.method || 'GET'} ${path}`);
    if (cfFails && path.includes(cfFails)) {
      return new Response(
        JSON.stringify({ success: false, errors: [{ code: 1003, message: 'tunnel has active connections' }] }),
        { status: 400 },
      );
    }
    const result = path.includes('/dns_records?') ? [{ id: 'rec-1' }] : {};
    return new Response(JSON.stringify({ success: true, errors: [], result }), { status: 200 });
  };

  const seed = () => {
    const e = env({
      'name:tests': { deviceId: 'this-phone', tunnelId: 'tun-7', inviteCode: 'ABC123' },
      'invite:ABC123': { uses: 1, maxUses: 3, label: 'family' },
    });
    e.CF_ZONE_ID = 'zone-1';
    e.CF_ACCOUNT_ID = 'acct-1';
    return e;
  };

  let e = seed();
  cfCalls = [];
  let [status, out] = await body(await post(e, '/release', {
    name: 'tests', deviceId: 'this-phone',
  }));
  check('a claim is released', status === 200 && out.released === true, `${status} ${JSON.stringify(out)}`);
  check('the reservation is gone', (await e.CLAIMS.get('name:tests')) === null);
  check('the DNS record was deleted',
    cfCalls.some((c) => c.startsWith('DELETE /client/v4/zones/zone-1/dns_records/')), cfCalls.join(' | '));
  check('the tunnel was deleted',
    cfCalls.some((c) => c === 'DELETE /client/v4/accounts/acct-1/cfd_tunnel/tun-7'), cfCalls.join(' | '));
  check('the invite use was handed back',
    (await e.CLAIMS.get('invite:ABC123', 'json')).uses === 0);

  e = seed();
  [status, out] = await body(await post(e, '/release', {
    name: 'tests', deviceId: 'some-other-phone',
  }));
  check('another device cannot release it', status === 403, `${status}`);
  check('and the claim survives', (await e.CLAIMS.get('name:tests')) !== null);

  // A reply that never arrived, retried. The caller wanted the name gone and
  // the name is gone, so this is a success, not a 404.
  e = seed();
  await e.CLAIMS.delete('name:tests');
  [status, out] = await body(await post(e, '/release', {
    name: 'tests', deviceId: 'this-phone',
  }));
  check('releasing an already-released name succeeds',
    status === 200 && out.ok === true && out.released === false, `${status} ${JSON.stringify(out)}`);

  [status] = await body(await post(seed(), '/release', { name: 'tests' }));
  check('a release with no device id is refused', status === 400, `${status}`);

  // The case that matters most: if Cloudflare will not let the tunnel go,
  // the name must stay claimed. Freeing it here would hand the next person a
  // name whose tunnel already exists, which /claim cannot recover from.
  e = seed();
  cfFails = '/cfd_tunnel/';
  [status] = await body(await post(e, '/release', {
    name: 'tests', deviceId: 'this-phone',
  }));
  check('a failed tunnel delete does not free the name', status === 502, `${status}`);
  check('the reservation is kept for a retry',
    (await e.CLAIMS.get('name:tests')) !== null);
  check('the invite use is not refunded either',
    (await e.CLAIMS.get('invite:ABC123', 'json')).uses === 1);
  cfFails = null;

  // Refunding must not run a code below zero, or an invite would gain uses.
  e = seed();
  await e.CLAIMS.put('invite:ABC123', JSON.stringify({ uses: 0, maxUses: 3 }));
  await post(e, '/release', { name: 'tests', deviceId: 'this-phone' });
  check('a refund never drops below zero',
    (await e.CLAIMS.get('invite:ABC123', 'json')).uses === 0);

  globalThis.fetch = realFetch;
}

console.log('\n-- unknown routes --');
{
  const [status] = await body(await call(env({}), '/nope'));
  check('unknown path is a 404', status === 404, `${status}`);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
