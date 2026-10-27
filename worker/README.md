# PocketShare provisioning Worker

> **Optional, and no longer how the app works.**
>
> The app provisions from the host's own phone now, using a Cloudflare API
> token that never leaves that device. Nothing in the app requires this
> Worker, and deploying it means one service holding a credential for a whole
> domain — which is exactly what moving provisioning onto the phone avoided.
>
> It is kept because it still works, and because a central provisioner is a
> reasonable thing to want if you are handing addresses to people who will
> never install the app. See the root `README.md` for the current design.

Creates a tunnel + DNS record under a domain you own, on demand, so the app's
users never touch Cloudflare.

## 1. Create the API token

Dashboard → **My Profile → API Tokens → Create Token → Create Custom Token**.

| Section | Setting |
| --- | --- |
| Permissions | `Account` → `Cloudflare Tunnel` → **Edit** |
| Permissions | `Zone` → `DNS` → **Edit** |
| Account Resources | Include → *your account* |
| Zone Resources | Include → Specific zone → **thapaalish.com.np** |
| TTL | leave open, or set a renewal reminder |

Those two permissions are the whole set. Do **not** add `Zone → Zone → Edit` or
anything account-wide — this token is the one credential that, if leaked,
rewrites your domain, so it should be able to do nothing but manage tunnels and
DNS records in this one zone.

Copy the token once; Cloudflare will not show it again.

The Account ID lives in `wrangler.toml` (it is not a secret). The Zone ID is
not configured at all — the Worker looks it up from `ROOT_DOMAIN` on first use
and caches it in KV, so there is one less value to paste wrong and it cannot
drift out of sync with the domain.

## 2. Deploy

```bash
npm install -g wrangler
wrangler login

# storage for claimed names + invite codes
wrangler kv namespace create CLAIMS
# paste the printed id into wrangler.toml -> kv_namespaces.id

wrangler secret put CF_API_TOKEN    # the token from step 1 — the only secret

wrangler deploy
```

Secrets live in Cloudflare, never in this repo. `wrangler.toml` is safe to commit.

## 3. Mint invite codes

```bash
wrangler kv key put --binding=CLAIMS "invite:FRIEND-7F2A" \
  '{"uses":0,"maxUses":1}' --remote
```

One code per friend, `maxUses` as you like. A code with `uses >= maxUses` is
refused.

## API

```
GET  /available?name=myfiles
     -> { available: true, hostname: "myfiles.thapaalish.com.np" }

POST /claim  { name, inviteCode, deviceId }
     -> { hostname, tunnelToken, reused }
```

`deviceId` is a per-install random id. Re-claiming the same name from the same
device returns the existing tunnel's token, so a reinstall doesn't strand the
name — a different device gets 409.

## Operational notes

- Names are a single DNS label (`myfiles`, not `a.b`). One label deep is
  what Universal SSL's wildcard covers on the free plan; deeper needs ACM.
- A failed claim rolls back both the name reservation and the tunnel, so a
  Cloudflare hiccup doesn't leak a half-provisioned name.
- KV has no compare-and-swap. `reserveName` writes then re-reads to confirm
  ownership, which closes the common race but is not a hard lock; two phones
  claiming the same name in the same instant is still theoretically possible.
  At friends-scale that's fine. If this ever goes wider, move the reservation
  to a Durable Object.
- You are the operator: every drive lives under your domain and you can see
  every claimed name. If the Worker is down, new claims fail but existing
  drives keep running, since their tunnel token is already on the device.
