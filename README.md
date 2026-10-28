# PocketShare

Turns a spare Android phone into a private drive reachable from anywhere, at a
name on a domain you control. The phone serves its own files; nothing is
uploaded to anyone else's server.

There are two ways in, and the first screen asks which one you are:

- **I have my own domain.** Connect a Cloudflare API token once. The phone can
  then create addresses on that domain — one for itself, and one for anyone it
  invites.
- **I have an invite code.** Someone with a domain invited you. Paste the code
  first: it is what says which domain you are joining, so nothing about the
  address is shown until the code has been checked. Then pick a name, done.
  You never see Cloudflare.

## How it fits together

The phone that owns the domain does the provisioning. There is no server in
the middle holding anyone's credentials.

```
HOST (owns the domain)                        Cloudflare API
──────────────────────                        ──────────────
pastes an API token
  GET /zones ─────────────────────────────►   lists zones it can reach
  ◄───────────────────────────────────────    thapaalish.com.np (+ account id)
picks a domain and a name
  POST /cfd_tunnel ───────────────────────►   create tunnel
  PUT  .../configurations ────────────────►   ingress → 127.0.0.1:8080
  POST /zones/<id>/dns_records ───────────►   CNAME → <id>.cfargotunnel.com
  ◄───────────────────────────────────────    tunnel token
runs cloudflared, polls /api/health, live


GUEST (has an invite code)
──────────────────────────
  POST https://<host-address>/provision/claim      ── not yet built ──
       { code, name, deviceId }
                       │
                       ▼  the HOST's phone does the Cloudflare calls above
                          using the token that never left it
  ◄──── { hostname, tunnelToken }
```

The API token stays on the device that created it. The alternative — one
service holding every user's Cloudflare credentials — would make that service
the single thing worth attacking, and a drive is not worth that.

## Layout

| Path | What it is |
| --- | --- |
| `lib/server/` | the drive itself: store, auth, files, uploads, HTTP routes |
| `lib/cloudflare/` | Cloudflare API client, name rules, host provisioner |
| `lib/invites/` | invite codes, kept on the host's phone |
| `lib/files/` | reading one directory for the in-app browser |
| `lib/storage/` | credential storage and the drive's folder on disk |
| `lib/tunnel/` | cloudflared supervision |
| `lib/state/` | lifecycle controller the UI renders |
| `lib/ui/` | start → connect or claim → login → the two-tab home |
| `assets/web/` | the UI people see in a browser |
| `android/app/src/main/jniLibs/` | prebuilt cloudflared, named `libcloudflared.so` |
| `worker/` | optional: the original provisioning Worker, no longer required |
| `test/` | widget tests for the running screens, against stubbed channels |

## Design notes

**The server binds loopback only.** The sole route in is the tunnel, so the
drive is invisible on local Wi-Fi, and `CF-Connecting-IP` becomes trustworthy
for rate limiting because nothing else can reach the socket.

**The Cloudflare API token is encrypted, not hashed.** A hash cannot be
undone, and the app has to send the original bytes to Cloudflare on every
provision — hashing it would destroy it. It goes to `flutter_secure_storage`,
whose Android key lives in the Keystore and never leaves it. Hashing is used
for the two jobs it fits: a truncated digest for telling one token from
another, and a fixed-width mask (`cfut_**********9a2f`, so the length does not
leak either) for showing one without revealing it. `allowBackup` is `false`,
or those encrypted blobs would be copied into cloud backups.

**The account id comes from the zone, not from listing accounts.** Listing
accounts is its own permission. `Account → Cloudflare Tunnel → Edit` lets a
token manage tunnels inside an account without being allowed to enumerate
accounts, so `GET /accounts` returns nothing for a perfectly good token —
which looked exactly like a missing scope. Every zone names its owning
account, so that is where it is read from, and one fewer permission is needed.

**Provisioning rolls back.** If ingress or DNS fails after the tunnel exists,
the tunnel is deleted. Otherwise a half-made claim leaves a tunnel holding the
name and that name can never be claimed again — a state reached in practice,
and cleared by hand.

**Renaming keeps the tunnel.** Only DNS is rewritten, so the tunnel token
stays valid and the drive does not reconnect. The old record is released last,
so a failure leaves the drive reachable at the address it already had.

**Invite codes are six characters, with no `O/0`, `I/1/L` or `U`.** They get
read aloud and copied off screens. That is ~594 million codes; the host is the
only thing that can answer a guess, unknown codes are refused outright, and
each code carries its own use limit, so more length would only cost typing. A
code is copied as `CODE@host.domain`, because the guest's phone has no central
service to ask where to send its claim. Spending a use is deliberately
separate from checking one, so a failed provision never burns an invite.

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

**A service record outlives the task inside it.** If the service isolate
throws on the way up, Android keeps the foreground service running while
nothing is listening. Asking that for status gets no reply, so the drive reads
as unreachable and the start button does nothing — permanently. Starting now
tears down a stale service first whenever the last state was a failure.

**Passwords use PBKDF2-HMAC-SHA256 at 600k iterations**, on a worker isolate so
a login cannot stall in-flight uploads. That is ~2-3s on a Snapdragon 732G,
which also makes `/api/auth/login` a CPU-exhaustion lever — hence the per-IP
throttle, which is as much about that as about brute force.

**Uploads are chunked and resumable.** A dropped connection costs one chunk,
not a 4 GB transfer. Chunks are written to `N.part` and renamed, so a chunk
interrupted mid-PUT is never mistaken for a complete one.

**Downloads name non-ASCII files per RFC 6266.** HTTP header values are
Latin-1, so a filename in Devanagari or with an emoji cannot go in the quoted
`filename` at all: dart:io throws while writing the headers and the response
never completes, hanging the client rather than failing it. The quoted form
carries an ASCII fallback and the real name travels percent-encoded in
`filename*`.

**State-changing requests must carry an `Origin`.** The check used to run only
when one was present, so the requests it let through were precisely those not
subject to the same-origin policy — the opposite of failing closed.

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

**The app is two tabs, not one list.** One screen held the status, the
address, the storage path, the permission chores, the invites and the login,
and read as a pile. *Drive* answers "is it up and what is its address";
*Files* answers "what is actually in it". The address and its status are one
panel rather than two, because a green dot in one card and a hostname in
another asks the reader to join them up.

**The folder picker is the app's own, not Android's.**
`ACTION_OPEN_DOCUMENT_TREE` returns a document URI, and the drive serves
files through plain paths from a background isolate with no Activity to
re-grant such a URI to. With all-files access already held, browsing the
filesystem directly shows the same path the server will open.

**Not every folder may be the drive.** Whatever is chosen becomes the root of
something published to the internet behind one password, so `FolderRules`
refuses a volume root — which would publish the camera roll, downloads and
every other app's shared files on one tap — and refuses `Android/`, where the
contents belong to other apps and vanish when they are uninstalled. A path
that does not normalise to itself is refused rather than silently corrected,
so the path shown in the warning is the path that gets served. A folder that
already has contents is confirmed, with the count, before it is used. The
rule runs again in `changeStorageToPath`: it is the one call that decides what
the whole drive serves, so it does not trust its caller.

**Moving the drive never overwrites, never eats itself, and never deletes a
folder it did not make.** Three separate ways this went wrong the moment the
destination stopped being a `PocketShare/` folder the app composed itself:

- The destination may already hold a `report.pdf` of its own, so a name that
  is taken gets `report (1).pdf` beside it instead of being replaced.
- A destination *inside* the current folder is refused outright — copying
  inwards and then deleting the source would delete the copies with it.
- The source is only deleted when the app created it. Point the drive at
  `DCIM/Camera` and the old code would, on the next "Change folder", empty
  that folder and `rm -rf` it. A folder the user picked is copied out of and
  left exactly as found, and the app says so rather than leaving them to
  discover it. A flag stored beside the path records which kind it is, and
  the rules run again over the *source* before any delete, so a path that
  reached storage without passing them can never become one.

`FolderMigration` is split out of `DriveLocation` precisely so all of this is
testable on a laptop.

**There is no `file://` fallback for opening a folder.** Android specifies no
intent for "show me this folder", so `openFolder` tries the documents-provider
URI and then the file manager's front door. The obvious middle step — a
`file://` URI with `resource/folder` — is absent on purpose: `minSdk` is 24,
and handing a file URI to another app throws `FileUriExposedException` on
every device this runs on, from `startActivity`, before anything resolves. It
would have crashed the app instead of falling through to the next attempt.

**Tapping a file hands it over with a `content://` URI.** A `file://` URI
crossing an app boundary throws `FileUriExposedException` on Android 7+, so a
`FileProvider` issues a read-only grant for the one file. Its paths are
scoped to `/storage/`, not `/`: nothing under `/data` — the app's databases,
the Keystore-backed secure storage — has any business being shareable.

**Sharing sends the address and nothing else.** Not the login, not the tunnel
token. A shared message gets forwarded, and a forwarded address is useless
without the password handed over separately. The same goes for an invite: a
code buys a guest an address of their own, never a way into this drive.

**Share is a native intent, not a plugin.** `ACTION_SEND` is a dozen lines of
Kotlin, and this is an app whose whole claim is that nothing sits in the
middle — one fewer third-party dependency with an upload path is worth more
than the convenience.

**The drive's folder is the user's, and they are told where it is.** It
defaults to `<volume>/PocketShare` — a normal folder, visible in the phone's
own Files app, which survives uninstalling the app. `Android/data/<pkg>/` is
only what happens when all-files access is missing, and the UI warns when
files have ended up there: Android deletes that directory on uninstall,
without a prompt, and blocks other apps from browsing it. Moving between
volumes copies rather than renames, because rename(2) cannot cross
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
flutter build apk --release --target-platform android-arm64
```

No build-time configuration. The domain and the token are entered in the app,
because a published build cannot be rebuilt per user.

## Test

```bash
dart run tool/smoke_server.dart      # the drive's HTTP surface
dart run tool/smoke_cloudflare.dart  # API client + provisioning, vs a fake Cloudflare
dart run tool/smoke_invites.dart     # invite codes
dart run tool/smoke_tokens.dart      # masking, fingerprints, token shapes
dart run tool/dev_server.dart        # run the drive locally to poke at the web UI
node worker/test.mjs                 # the provisioning Worker, against a fake KV
flutter test                         # the app's own screens, against stubbed channels
```

The server suite exercises auth, path traversal, chunked upload with a
deliberately skipped chunk, range requests, non-ASCII filenames and
trash/restore against a real server on a real port. The Cloudflare suite runs
against a fake that can be told to fail individual endpoints, covering invalid
and under-scoped tokens, tunnel adoption on reinstall, refusing to adopt a
live tunnel, and rollback. The file suite
moves real directories in a temp folder, including the two cases that lose
data if they are wrong: a name collision in the destination, and a destination
inside the source. The widget tests stub the platform channels and render both
tabs, checking among other things that the share text carries no credential.
The Worker suite calls its exported `fetch` with a fake KV, covering the gate
that keeps `/available` from answering without a good invite code.

## Known gaps

- **Guests cannot redeem a code yet.** The host's `/provision/*` endpoints are
  not built. Everything behind them is: the API client, the provisioner with
  rollback, the name rules and the invite store.
- **Uninstalling forgets the drive, but not the name.** The claim, the login,
  invite codes and the Cloudflare token all live in app storage, which Android
  wipes, and `allowBackup="false"` means there is no backup to restore from.
  Files under `/storage/emulated/0/PocketShare` survive. The address comes
  back either way: a guest is recognised by a device id derived from
  ANDROID_ID, which outlives the app, and a host re-claiming its own name
  adopts the tunnel still standing on the account. What does not come back is
  the login and the invite codes, and a host has to enter its Cloudflare token
  again. Restoring those without putting them somewhere Google can read is not
  solved.
- Release builds are signed with the debug key. Replace before distributing.
- The web UI cannot empty the trash or move a file between folders, though the
  server supports both.
- The drive only lands in app-private storage when all-files access was
  missing at first run. Granting it later does not move the drive on its own;
  the Files tab offers the move as one tap instead, because silently
  relocating someone's files is not something to do behind their back.
- The in-app Files tab is read-only. Uploading, deleting and restoring live in
  the web UI, which already has the whole story; a second half-built copy of
  it on the phone would be worse than one complete one in the browser.
- The new tabs, folder picker and share sheet have been exercised by the
  widget tests and a release build, but not yet on a physical phone.
- Moving the drive out of a folder the user picked leaves a full copy behind,
  by design. The alternative is deleting folders the app did not create.
- Folder navigation does not change the URL, so a folder cannot be linked and
  the browser's back button leaves the app instead of going up.
- cloudflared runs as a child process, which Android 12+ treats as a *phantom
  process* and may kill under its own quota, independently of the foreground
  service. Observed killing another drive app's cloudflared on the same device.
- `MANAGE_EXTERNAL_STORAGE` will need justifying for a Play Store listing.
- No per-file sharing; the login guards everything or nothing.
- arm64 only.
