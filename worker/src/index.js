/**
 * PocketShare provisioning Worker.
 *
 * Holds the only copy of the Cloudflare API token. A phone sends an invite
 * code and a desired name; it gets back a hostname and a tunnel token scoped
 * to a single tunnel. The API token itself never leaves this Worker — anything
 * shipped in the APK is extractable with `strings`.
 */

const SERVICE_URL = 'http://127.0.0.1:8080';
const CF_API = 'https://api.cloudflare.com/client/v4';

// Names that would shadow real infrastructure on the apex domain.
const RESERVED = new Set([
  'www', 'api', 'mail', 'smtp', 'imap', 'pop', 'ns', 'ns1', 'ns2', 'mx',
  'admin', 'root', 'cpanel', 'webmail', 'ftp', 'cdn', 'static', 'assets',
  'blog', 'shop', 'store', 'app', 'dev', 'test', 'staging', 'status',
  'dashboard', 'login', 'auth', 'account', 'billing', 'support', 'help',
  'docs', 'git', 'vpn', 'proxy', 'tunnel', 'pocketshare', 'files',
  // The Worker's own hostname. Claiming it would rewrite the DNS record
  // this service answers on and take provisioning down for everyone.
  'provision',
]);

// Single DNS label: lowercase alphanumerics and inner hyphens, 3-32 chars.
// One label deep keeps it inside Universal SSL's wildcard coverage.
const NAME_RE = /^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    try {
      if (request.method === 'GET' && url.pathname === '/invite') {
        return await invite(url, env);
      }
      if (request.method === 'GET' && url.pathname === '/available') {
        return await available(url, env);
      }
      if (request.method === 'POST' && url.pathname === '/claim') {
        return await claim(request, env);
      }
      return json({ error: 'not found' }, 404);
    } catch (err) {
      // Never surface Cloudflare API internals to the app.
      console.error('provisioning failed', err?.stack || String(err));
      return json({ error: 'provisioning failed, try again' }, 502);
    }
  },
};

/**
 * Checks an invite code and, only if it is good, says which domain it is for.
 *
 * The domain is the answer to "whose PocketShare am I joining?", and until a
 * code proves the asker was invited there is no reason to tell them. This is
 * also the gate on /available: without it, anyone who installed the app could
 * probe which names are taken on the domain.
 */
async function invite(url, env) {
  const code = (url.searchParams.get('code') || '').toUpperCase().trim();
  const check = await checkInvite(env, code);
  if (!check.ok) return json({ ok: false, error: check.error }, 403);

  return json({
    ok: true,
    domain: env.ROOT_DOMAIN,
    remaining: check.remaining,
  });
}

async function available(url, env) {
  // A name check reveals what is taken on the domain, so it needs the same
  // invite a claim does.
  const code = (url.searchParams.get('code') || '').toUpperCase().trim();
  const invited = await checkInvite(env, code);
  if (!invited.ok) return json({ available: false, reason: invited.error }, 403);

  const name = (url.searchParams.get('name') || '').toLowerCase().trim();
  const problem = validateName(name);
  if (problem) return json({ available: false, reason: problem });

  const taken = await env.CLAIMS.get(`name:${name}`);
  return json({
    available: !taken,
    reason: taken ? 'already taken' : null,
    hostname: `${name}.${env.ROOT_DOMAIN}`,
  });
}

async function claim(request, env) {
  if (!env.CF_API_TOKEN || env.CF_API_TOKEN.trim() === '') {
    console.error('CF_API_TOKEN is unset or empty');
    return json(
      { error: 'this PocketShare server is not configured yet' },
      503,
    );
  }

  const body = await request.json().catch(() => ({}));
  const name = String(body.name || '').toLowerCase().trim();
  const inviteCode = String(body.inviteCode || '').toUpperCase().trim();
  const deviceId = String(body.deviceId || '').trim();

  if (!deviceId || deviceId.length < 8) {
    return json({ error: 'missing device id' }, 400);
  }

  const problem = validateName(name);
  if (problem) return json({ error: problem }, 400);

  const hostname = `${name}.${env.ROOT_DOMAIN}`;
  const existing = await env.CLAIMS.get(`name:${name}`, 'json');

  // Re-provisioning the same name from the same device is a reinstall, not a
  // new claim: hand back the existing tunnel's token instead of refusing.
  if (existing) {
    if (existing.deviceId !== deviceId) {
      return json({ error: 'that name is taken' }, 409);
    }
    const token = await tunnelToken(env, existing.tunnelId);
    return json({ hostname, tunnelToken: token, reused: true });
  }

  const invite = await checkInvite(env, inviteCode);
  if (!invite.ok) return json({ error: invite.error }, 403);

  // Reserve the name before calling Cloudflare, so two phones racing on the
  // same name cannot both create a tunnel for it.
  const reserved = await reserveName(env, name, deviceId);
  if (!reserved) return json({ error: 'that name is taken' }, 409);

  let tunnel;
  try {
    tunnel = await createTunnel(env, name);
    await configureIngress(env, tunnel.id, hostname);
    await upsertDnsRecord(env, name, `${tunnel.id}.cfargotunnel.com`);
  } catch (err) {
    // Roll the reservation back so a failed claim does not burn the name.
    await env.CLAIMS.delete(`name:${name}`);
    if (tunnel?.id) await deleteTunnel(env, tunnel.id).catch(() => {});
    throw err;
  }

  await env.CLAIMS.put(
    `name:${name}`,
    JSON.stringify({
      deviceId,
      tunnelId: tunnel.id,
      inviteCode,
      createdAt: Date.now(),
    }),
  );

  await consumeInvite(env, inviteCode);
  return json({ hostname, tunnelToken: tunnel.token, reused: false });
}

function validateName(name) {
  if (!name) return 'pick a name';
  if (name.length < 3) return 'at least 3 characters';
  if (name.length > 32) return 'at most 32 characters';
  if (!NAME_RE.test(name)) {
    return 'letters, digits and hyphens only; must start and end with a letter or digit';
  }
  if (RESERVED.has(name)) return 'that name is reserved';
  return null;
}

/** Atomic-enough reservation: KV has no CAS, so re-read and confirm ownership. */
async function reserveName(env, name, deviceId) {
  const key = `name:${name}`;
  if (await env.CLAIMS.get(key)) return false;

  await env.CLAIMS.put(key, JSON.stringify({ deviceId, pending: true }));
  const settled = await env.CLAIMS.get(key, 'json');
  return settled?.deviceId === deviceId;
}

async function checkInvite(env, code) {
  if (!code) return { ok: false, error: 'invite code required' };

  const found = await env.CLAIMS.get(`invite:${code}`, 'json');
  if (!found) return { ok: false, error: 'invalid invite code' };
  if (found.revoked) return { ok: false, error: 'this invite code was revoked' };
  if (found.uses >= found.maxUses) {
    return { ok: false, error: 'this invite code is used up' };
  }
  return { ok: true, remaining: Math.max(0, found.maxUses - found.uses) };
}

/** Called only after a claim fully succeeds, so a fault never eats a code. */
async function consumeInvite(env, code) {
  const key = `invite:${code}`;
  const invite = await env.CLAIMS.get(key, 'json');
  if (!invite) return;
  await env.CLAIMS.put(key, JSON.stringify({ ...invite, uses: invite.uses + 1 }));
}

// --- Cloudflare API ---------------------------------------------------------

async function cf(env, path, init = {}) {
  const res = await fetch(`${CF_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.CF_API_TOKEN}`,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });

  const payload = await res.json().catch(() => ({}));
  if (!res.ok || payload.success === false) {
    const detail = (payload.errors || []).map((e) => e.message).join('; ');
    throw new Error(`CF ${path} -> ${res.status} ${detail}`);
  }
  return payload.result;
}

async function createTunnel(env, name) {
  // config_src 'cloudflare' makes the tunnel remotely managed, so ingress
  // comes from the API call below rather than a config file on the phone.
  const result = await cf(env, `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel`, {
    method: 'POST',
    body: JSON.stringify({ name: `ps-${name}`, config_src: 'cloudflare' }),
  });
  return { id: result.id, token: result.token };
}

function configureIngress(env, tunnelId, hostname) {
  return cf(
    env,
    `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel/${tunnelId}/configurations`,
    {
      method: 'PUT',
      body: JSON.stringify({
        config: {
          ingress: [
            { hostname, service: SERVICE_URL },
            { service: 'http_status:404' },
          ],
        },
      }),
    },
  );
}

function tunnelToken(env, tunnelId) {
  return cf(env, `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel/${tunnelId}/token`);
}

function deleteTunnel(env, tunnelId) {
  return cf(env, `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel/${tunnelId}`, {
    method: 'DELETE',
  });
}

/**
 * Zone id for ROOT_DOMAIN, looked up once and cached.
 *
 * Deriving it beats configuring it: one less value to paste wrong, and it
 * cannot drift out of sync with ROOT_DOMAIN.
 */
async function zoneId(env) {
  if (env.CF_ZONE_ID) return env.CF_ZONE_ID;

  const cached = await env.CLAIMS.get('meta:zone_id');
  if (cached) return cached;

  const zones = await cf(
    env,
    `/zones?name=${encodeURIComponent(env.ROOT_DOMAIN)}`,
  );
  if (!zones.length) {
    throw new Error(`zone ${env.ROOT_DOMAIN} not found for this token`);
  }

  await env.CLAIMS.put('meta:zone_id', zones[0].id);
  return zones[0].id;
}

async function upsertDnsRecord(env, name, target) {
  const zone = await zoneId(env);
  const fqdn = `${name}.${env.ROOT_DOMAIN}`;
  const existing = await cf(
    env,
    `/zones/${zone}/dns_records?type=CNAME&name=${encodeURIComponent(fqdn)}`,
  );

  const record = {
    type: 'CNAME',
    name,
    content: target,
    proxied: true,
    comment: 'pocketshare',
  };

  if (existing.length > 0) {
    return cf(env, `/zones/${zone}/dns_records/${existing[0].id}`, {
      method: 'PUT',
      body: JSON.stringify(record),
    });
  }
  return cf(env, `/zones/${zone}/dns_records`, {
    method: 'POST',
    body: JSON.stringify(record),
  });
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
