# PocketShare

Turns a spare Android phone into a private drive reachable from anywhere, at
`<name>.thapaalish.com.np`. Friends install the app, type a name, and are done:
no Cloudflare account, no tunnel token, no dashboard.

## How it fits together

```
Friend's phone                    Worker                 Cloudflare API
──────────────                    ──────                 ──────────────
types "kishanfiles"
  POST /claim ───────────────────►
                                  check invite code
                                  create tunnel ───────► POST /cfd_tunnel
                                   ◄──────────────────── {id, token}
                                  ingress → 127.0.0.1:8080
                                  CNAME ───────────────► kishanfiles
                                                          → <id>.cfargotunnel.com
  ◄──────────── {hostname, tunnelToken}
runs cloudflared with that token
polls /api/health until 200
drive is live
```

The Cloudflare API token exists only in the Worker. Nothing in the APK can
reach the domain — anything shipped in an APK is recoverable with `strings`.

## Layout

| Path | What it is |
| --- | --- |
| `lib/server/` | the drive itself: store, auth, files, uploads, HTTP routes |
| `lib/tunnel/` | cloudflared supervision and Worker client |
| `lib/state/` | lifecycle controller the UI renders |
| `lib/ui/` | claim → login → running |
| `assets/web/` | the UI friends see in a browser |
| `worker/` | provisioning Worker (see `worker/README.md`) |
| `android/app/src/main/jniLibs/` | prebuilt cloudflared, named `libcloudflared.so` |

## Design notes

**The server binds loopback only.** The sole route in is the tunnel, so the
drive is invisible on local Wi-Fi, and `CF-Connecting-IP` becomes trustworthy
for rate limiting because nothing else can reach the socket.

**cloudflared ships as `libcloudflared.so`.** It is the stock static
`cloudflared-linux-arm64` release, stripped. Android only permits executing
files from an app's native library directory, so the binary is given a `.so`
name to land there. This also requires `extractNativeLibs=true` and
`useLegacyPackaging=true`: the modern default leaves libraries packed inside
the APK with no real file to execute.

**cloudflared cannot resolve DNS on Android.** It is a cgo-free Go binary, so
it uses Go's own resolver, which reads `/etc/resolv.conf`. Android has no such
file — name resolution goes through `netd` — so Go falls back to
`localhost:53` and every lookup fails with "connection refused". Dart's
resolver *does* work, so `TunnelManager` resolves
`region1/region2.v2.argotunnel.com` itself and passes the addresses with
repeated `--edge` flags, bypassing cloudflared's SRV discovery. `--edge` is
repeatable, not comma-separated; a comma-joined list is parsed as one address
("too many colons"). cloudflared's own `api.cloudflare.com` precheck still
fails for the same reason, but it is `hard_fail=false` and harmless.

**The native library directory is read from `/proc/self/maps`.** A method
channel only exists in the UI isolate, because MainActivity registers it; the
service isolate has its own engine and no Activity, so any channel call there
throws `MissingPluginException`. `libflutter.so` is itself loaded from the
native library directory, so its mapped path names the directory — no channel,
works in any isolate.

**"Connected" is not "reachable".** cloudflared reporting a registered
connection only means it reached Cloudflare's edge; the hostname can still
return error 1033 for several seconds while that connection propagates.
`TunnelManager` polls `/api/health` for up to 120s instead of probing once.
Probing once is a race, and losing it looks exactly like a broken setup.

**Passwords use PBKDF2-HMAC-SHA256 at 600k iterations**, on a worker isolate so
a login cannot stall in-flight uploads. That is ~2-3s on a Snapdragon 732G,
which also makes `/api/auth/login` a CPU-exhaustion lever — hence the per-IP
throttle, which is as much about that as about brute force.

**Uploads are chunked and resumable.** A dropped connection costs one chunk,
not a 4 GB transfer. Chunks are written to `N.part` and renamed, so a chunk
interrupted mid-PUT is never mistaken for a complete one.

**Every response is `Cache-Control: no-store, private`.** Without it
Cloudflare applies its own default TTL to static extensions — observed as a
4-hour `max-age` injected onto `app.js`, so a shipped UI fix did not reach the
browser. The same default would make `GET /api/files` edge-cacheable, putting
a private file listing in Cloudflare's cache. Nothing this server returns is
public, so nothing may be stored.

**The login form is `method="post"`.** The JS handler calls `preventDefault`,
but if the script has not attached its listener when the user hits Sign in,
the browser submits natively — and a GET would write the password into the
URL, into browser history and into `Referer` headers. Observed in the wild,
not hypothetical.

**The drive's folder is the user's, and they are told where it is.** It
defaults to `<volume>/PocketShare` — a normal folder, visible in the phone's
own Files app — and the running screen shows the absolute path. Storing inside
`Android/data/<pkg>/` is possible but only as a fallback, and the UI warns
when that is where files have ended up: Android deletes that directory on
uninstall, without a prompt, and blocks other apps from browsing it. Moving
between volumes copies rather than renames, because rename(2) cannot cross
filesystems and internal storage and an SD card never share one.

**Deletes go to trash**, because this runs on a phone screen where a mistap is
easy and `rm -rf` is not recoverable.

**The drive runs in the foreground service isolate, not the UI isolate.** When
Android destroys the Activity the UI isolate goes with it, so a server owned by
the screen stops serving the moment the user swipes the app away. `lib/ui/` is
a remote control: it starts and stops the service and mirrors status over the
plugin's data channel. The service is declared in the app's own manifest with
`foregroundServiceType="dataSync"`, which Android 14 requires and the plugin
does not provide.

## Build

```bash
flutter build apk --release --target-platform android-arm64 \
  --dart-define=PROVISION_ENDPOINT=https://<your-worker-url>
```

The endpoint must be baked in at build time; there is no in-app field for it,
deliberately — a friend should never see infrastructure.

## Test

```bash
dart run tool/smoke_server.dart
```

Exercises auth, path traversal, chunked upload with a deliberately skipped
chunk, range requests, and trash/restore against a real server on a real port.

## Known gaps

- Release builds are signed with the debug key. Replace before distributing.
- cloudflared runs as a child process, which Android 12+ treats as a *phantom
  process* and may kill under its own quota, independently of the foreground
  service. Not yet observed for this app, but it was observed killing the
  other drive app's cloudflared on this same device.
- Only the `lib/server/` layer has automated tests; everything above it has
  been exercised by hand.
- No per-file sharing; the login guards everything or nothing.
- arm64 only.
