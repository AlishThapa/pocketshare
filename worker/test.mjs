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

console.log('\n-- unknown routes --');
{
  const [status] = await body(await call(env({}), '/nope'));
  check('unknown path is a 404', status === 404, `${status}`);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
