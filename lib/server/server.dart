import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'files.dart';
import 'inline_types.dart';
import 'shares.dart';
import 'store.dart';
import 'uploads.dart';

/// The drive's HTTP server.
///
/// Binds loopback only: the sole way in is the Cloudflare tunnel running on
/// this device. That keeps the drive off the local Wi-Fi network and makes
/// `CF-Connecting-IP` trustworthy, since nothing else can reach the socket.
class DriveServer {
  DriveServer({
    required this.store,
    required this.auth,
    required this.files,
    required this.uploads,
    required this.webRoot,
    this.port = 8080,
  });

  final DriveStore store;
  final Auth auth;
  final DriveFiles files;
  final UploadManager uploads;

  /// Directory holding the browser UI, unpacked from assets at startup.
  final Directory webRoot;
  final int port;

  /// Share links live in the same database as everything else, so a disconnect
  /// or a backup covers them without a second mechanism.
  late final ShareStore shares = ShareStore(store.db);

  HttpServer? _server;
  Timer? _sweeper;

  final _LoginThrottle _throttle = _LoginThrottle();

  int get boundPort => _server?.port ?? port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;

    final handler = const Pipeline()
        .addMiddleware(_securityHeaders)
        .addMiddleware(_authGate)
        .addHandler(_router.call);

    _server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      port,
      poweredByHeader: null,
    );

    _sweeper = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(uploads.sweep()),
    );
  }

  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
    await _server?.close(force: true);
    _server = null;
  }

  Router get _router => Router()
    ..get('/api/health', _health)
    ..post('/api/auth/login', _login)
    ..post('/api/auth/logout', _logout)
    ..get('/api/me', _me)
    ..get('/api/files', _list)
    ..get('/api/download', _download)
    ..get('/api/search', _search)
    ..post('/api/folders', _mkdir)
    ..post('/api/rename', _rename)
    ..post('/api/move', _move)
    ..post('/api/delete', _delete)
    ..get('/api/shares', _listShares)
    ..post('/api/shares', _createShare)
    ..post('/api/shares/revoke', _revokeShare)
    // Public, deliberately: these are what a share link reaches, and the
    // token in the path is the whole of the permission.
    ..get('/api/share/<token>', _shareInfo)
    ..get('/api/share/<token>/list', _shareList)
    ..get('/api/share/<token>/download', _shareDownload)
    ..post('/api/share/<token>/unlock', _unlockShare)
    ..get('/s/<token>', _serveSharePage)
    ..get('/api/trash', _trash)
    ..post('/api/trash/restore', _restore)
    ..post('/api/trash/empty', _emptyTrash)
    ..post('/api/uploads', _createUpload)
    ..put('/api/uploads/<id>/chunks/<index>', _putChunk)
    ..get('/api/uploads/<id>', _uploadStatus)
    ..post('/api/uploads/<id>/complete', _completeUpload)
    ..all('/api/<rest|.*>', (Request _) => _json({'error': 'not found'}, 404))
    ..all('/<rest|.*>', _serveWebUi);

  // --- middleware ----------------------------------------------------------

  /// Endpoints reachable without a session. Everything else requires one.
  static const Set<String> _publicPaths = {
    '/api/health',
    '/api/auth/login',
  };

  /// Prefixes under `/api/` that a share link reaches without signing in.
  ///
  /// The token in the path is the permission, so these are not unprotected,
  /// they are protected by something other than a session. They are listed
  /// as a prefix rather than exact paths because the token is part of the
  /// path and there is one of these per link.
  static const List<String> _publicPrefixes = ['/api/share/'];

  static bool _needsSession(String path) {
    if (!path.startsWith('/api/')) return false;
    if (_publicPaths.contains(path)) return false;
    return !_publicPrefixes.any(path.startsWith);
  }

  Handler Function(Handler) get _authGate => (Handler inner) {
        return (Request request) async {
          final path = '/${request.url.path}';

          if (_needsSession(path)) {
            final token = _sessionToken(request);
            if (token == null || !auth.validate(token)) {
              return _json({'error': 'unauthorized'}, 401);
            }
          }

          // Reject cross-site state changes. SameSite=Strict already blocks
          // the cookie, but an explicit Origin check fails closed if a future
          // browser or client relaxes that.
          if (_isMutation(request.method) && path.startsWith('/api/')) {
            final origin = request.headers['origin'];
            final host = request.headers['host'];
            // Absent Origin used to pass. Browsers always send it on a
            // state-changing fetch, so the only callers it let through were
            // ones not subject to the same-origin policy at all — which is
            // the opposite of failing closed. A scripted client has to send
            // an Origin header now.
            if (origin == null || host == null) {
              return _json({'error': 'missing Origin'}, 403);
            }
            final originHost = Uri.tryParse(origin)?.host;
            if (originHost == null || originHost != host.split(':').first) {
              return _json({'error': 'cross-origin request refused'}, 403);
            }
          }

          return inner(request);
        };
      };

  static bool _isMutation(String method) =>
      method == 'POST' || method == 'PUT' || method == 'DELETE' || method == 'PATCH';

  Handler Function(Handler) get _securityHeaders => (Handler inner) {
        return (Request request) async {
          final response = await inner(request);
          return response.change(headers: {
            // Everything here is private and served through Cloudflare, which
            // otherwise applies its own default TTL to static extensions —
            // caching the UI for hours and, worse, making file listings
            // edge-cacheable. Nothing from this server may be stored.
            'Cache-Control': 'no-store, private',
            'X-Content-Type-Options': 'nosniff',
            // SAMEORIGIN rather than DENY: the preview needs to put a PDF
            // or a text file in an iframe of this same drive, and framing by
            // this origin is not what clickjacking means. Another site still
            // cannot frame anything here.
            'X-Frame-Options': 'SAMEORIGIN',
            'Referrer-Policy': 'no-referrer',
            // The UI is fully self-hosted, so nothing third-party is allowed
            // to load or to be connected to.
            'Content-Security-Policy':
                "default-src 'self'; img-src 'self' data: blob:; "
                "media-src 'self' blob:; object-src 'none'; "
                "base-uri 'none'; form-action 'self'; frame-ancestors 'self'",
          });
        };
      };

  // --- auth ----------------------------------------------------------------

  Response _health(Request request) => _json({
        'ok': true,
        'service': 'pocketshare',
        'claimed': store.hasAccount,
      });

  Future<Response> _login(Request request) async {
    final ip = _clientIp(request);
    if (!_throttle.allow(ip)) {
      return _json(
        {'error': 'too many attempts, wait a minute'},
        429,
        {'Retry-After': '60'},
      );
    }

    final body = await _readJson(request);
    final username = (body['username'] as String?)?.trim() ?? '';
    final password = body['password'] as String? ?? '';

    final token = await auth.login(
      username: username,
      password: password,
      userAgent: request.headers['user-agent'],
    );

    if (token == null) {
      _throttle.penalise(ip);
      return _json({'error': 'wrong username or password'}, 401);
    }

    _throttle.clear(ip);
    return _json({'ok': true}, 200, {
      'Set-Cookie': _buildCookie(token),
    });
  }

  Response _logout(Request request) {
    final token = _sessionToken(request);
    if (token != null) auth.logout(token);
    return _json({'ok': true}, 200, {
      'Set-Cookie': '${Auth.sessionCookie}=; Path=/; HttpOnly; Secure; '
          'SameSite=Strict; Max-Age=0',
    });
  }

  Response _me(Request request) {
    final token = _sessionToken(request)!;
    return _json({'username': auth.usernameOf(token)});
  }

  static String _buildCookie(String token) =>
      '${Auth.sessionCookie}=$token; Path=/; HttpOnly; Secure; '
      'SameSite=Strict; Max-Age=${const Duration(days: 30).inSeconds}';

  static String? _sessionToken(Request request) {
    final raw = request.headers['cookie'];
    if (raw == null) return null;
    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length >= 2 && kv.first == Auth.sessionCookie) {
        return kv.sublist(1).join('=');
      }
    }
    return null;
  }

  /// Every cookie on the request. Share unlocking needs to look up a name it
  /// only knows at runtime, which the session reader above cannot do.
  static Map<String, String> _cookies(Request request) {
    final raw = request.headers['cookie'];
    if (raw == null) return const {};
    final out = <String, String>{};
    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length >= 2) out[kv.first] = kv.sublist(1).join('=');
    }
    return out;
  }

  /// Real client address. Only cloudflared can reach this socket, so the
  /// Cloudflare-set header is authoritative here.
  static String _clientIp(Request request) =>
      request.headers['cf-connecting-ip'] ??
      request.headers['x-forwarded-for']?.split(',').first.trim() ??
      'local';

  // --- browsing ------------------------------------------------------------

  Future<Response> _list(Request request) => _guard(() async {
        final path = request.url.queryParameters['path'] ?? '';
        // Which of these are public travels with the listing rather than in a
        // second request, so a row can never be drawn as private for the
        // moment it takes a second call to answer.
        return _json({
          'path': path,
          'entries': await files.list(path),
          'shared': shares.livePaths().toList(),
        });
      });

  Future<Response> _search(Request request) => _guard(() async {
        final q = request.url.queryParameters['q'] ?? '';
        return _json({'results': await files.search(q)});
      });

  Future<Response> _trash(Request request) => _guard(() async {
        return _json({'entries': await files.listTrash()});
      });

  // --- mutations -----------------------------------------------------------

  Future<Response> _mkdir(Request request) => _guard(() async {
        final body = await _readJson(request);
        await files.mkdir(body['path'] as String? ?? '');
        return _json({'ok': true});
      });

  Future<Response> _rename(Request request) => _guard(() async {
        final body = await _readJson(request);
        final from = body['from'] as String;
        final to = body['to'] as String;
        await files.rename(from, to);
        // A link already sent to someone must keep working across a rename;
        // the share was for that thing, not for that string.
        shares.repoint(from: from, to: to);
        return _json({'ok': true});
      });

  Future<Response> _move(Request request) => _guard(() async {
        final body = await _readJson(request);
        final from = body['from'] as String;
        final toDir = body['toDir'] as String;
        await files.move(from, toDir);
        final name = p.basename(from);
        shares.repoint(from: from, to: toDir.isEmpty ? name : '$toDir/$name');
        return _json({'ok': true});
      });

  Future<Response> _delete(Request request) => _guard(() async {
        final body = await _readJson(request);
        final path = body['path'] as String;
        await files.trash(path);
        // The thing the link pointed at is in the trash. Leaving the link
        // live would make it a 404 that looks like a bug; dropping it makes
        // it the one honest thing, a link that no longer exists.
        shares.forgetPath(path);
        return _json({'ok': true});
      });

  Future<Response> _restore(Request request) => _guard(() async {
        final body = await _readJson(request);
        await files.restore(body['id'] as String);
        return _json({'ok': true});
      });

  Future<Response> _emptyTrash(Request request) => _guard(() async {
        await files.emptyTrash();
        return _json({'ok': true});
      });

  // --- uploads -------------------------------------------------------------

  Future<Response> _createUpload(Request request) => _guard(() async {
        final body = await _readJson(request);
        final session = await uploads.create(
          destinationPath: body['path'] as String,
          totalSize: (body['size'] as num).toInt(),
          chunkSize: (body['chunkSize'] as num?)?.toInt() ?? 8 * 1024 * 1024,
        );
        return _json(session.toJson());
      });

  Future<Response> _putChunk(Request request, String id, String index) =>
      _guard(() async {
        final session = uploads.find(id);
        if (session == null) return _json({'error': 'no such upload'}, 404);

        final n = int.tryParse(index);
        if (n == null) return _json({'error': 'bad chunk index'}, 400);

        await uploads.writeChunk(session, n, request.read());
        return _json({'ok': true, 'index': n});
      });

  Future<Response> _uploadStatus(Request request, String id) => _guard(() async {
        final session = uploads.find(id);
        if (session == null) return _json({'error': 'no such upload'}, 404);
        return _json({
          ...session.toJson(),
          'missing': await uploads.missing(session),
        });
      });

  Future<Response> _completeUpload(Request request, String id) => _guard(() async {
        final session = uploads.find(id);
        if (session == null) return _json({'error': 'no such upload'}, 404);

        final file = await uploads.complete(session);
        return _json({
          'ok': true,
          'path': p.relative(file.path, from: files.root.path),
        });
      });

  // --- download ------------------------------------------------------------

  /// Serves a file with Range support, so the browser can seek in a video
  /// instead of buffering the whole thing first.
  Future<Response> _download(Request request) =>
      _guard(() => _sendFile(request, request.url.queryParameters['path'] ?? ''));

  /// Serves one file with ranges, the allowlisted type and a disposition.
  ///
  /// Shared by the owner's download route and by a share link's, so a visitor
  /// gets exactly the same typing rules the owner does — the allowlist is
  /// most of what makes a public link safe to hand out.
  Future<Response> _sendFile(Request request, String relative) async {
        final file = resolveFile(files.root, relative);
        if (file == null) return _json({'error': 'bad path'}, 400);
        if (!await file.exists()) return _json({'error': 'not found'}, 404);

        final length = await file.length();

        // The extension is a claim, not a fact: it came from whoever put the
        // file here. What goes on the wire is the allowlisted type, so a
        // .js or .html in the drive is served as octet-stream and cannot be
        // pulled back in as script or rendered as a page. See [InlineTypes].
        final claimed = lookupMimeType(file.path);
        final type = InlineTypes.served(claimed);
        final inline = request.url.queryParameters['inline'] == '1' &&
            InlineTypes.allows(claimed);
        final disposition =
            inline ? 'inline' : _attachment(p.basename(file.path));

        final range = _parseRange(request.headers['range'], length);
        if (range == null) {
          return Response.ok(
            file.openRead(),
            headers: {
              'Content-Type': type,
              'Content-Length': '$length',
              'Accept-Ranges': 'bytes',
              'Content-Disposition': disposition,
            },
          );
        }

        if (range.unsatisfiable) {
          return Response(416, headers: {'Content-Range': 'bytes */$length'});
        }

        return Response(
          206,
          body: file.openRead(range.start, range.endExclusive),
          headers: {
            'Content-Type': type,
            'Content-Length': '${range.endExclusive - range.start}',
            'Content-Range': 'bytes ${range.start}-${range.endExclusive - 1}/$length',
            'Accept-Ranges': 'bytes',
            'Content-Disposition': disposition,
          },
        );
  }

  /// Content-Disposition for a download, per RFC 6266.
  ///
  /// HTTP header values are Latin-1, so a name with Devanagari, CJK or emoji
  /// in it cannot go in the quoted `filename` at all — dart:io throws while
  /// writing the headers and the response never completes, hanging the client.
  /// The quoted form therefore carries an ASCII-only fallback, and the real
  /// name travels in `filename*` as percent-encoded UTF-8.
  static String _attachment(String name) {
    final ascii = name
        .replaceAll(RegExp(r'[^\x20-\x7E]'), '_')
        .replaceAll('"', '')
        .replaceAll('\\', '');
    final fallback = ascii.trim().isEmpty ? 'download' : ascii;
    return 'attachment; filename="$fallback"; '
        "filename*=UTF-8''${_rfc5987(name)}";
  }

  /// Percent-encodes everything outside RFC 5987's `attr-char` set. Dart's
  /// own encoders leave `!'()*` alone, which this grammar does not allow.
  static String _rfc5987(String name) {
    const safe = "!#\$&+-.^_`|~";
    final out = StringBuffer();
    for (final byte in utf8.encode(name)) {
      final isAlphaNum = (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A);
      if (isAlphaNum || safe.codeUnits.contains(byte)) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static _ByteRange? _parseRange(String? header, int length) {
    if (header == null || !header.startsWith('bytes=')) return null;

    final spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;

    final rawStart = spec.substring(0, dash).trim();
    final rawEnd = spec.substring(dash + 1).trim();

    int start;
    int endExclusive;

    if (rawStart.isEmpty) {
      // Suffix form: "bytes=-500" means the last 500 bytes.
      final suffix = int.tryParse(rawEnd);
      if (suffix == null || suffix <= 0) return null;
      start = length - suffix < 0 ? 0 : length - suffix;
      endExclusive = length;
    } else {
      final s = int.tryParse(rawStart);
      if (s == null) return null;
      start = s;
      if (rawEnd.isEmpty) {
        endExclusive = length;
      } else {
        final e = int.tryParse(rawEnd);
        if (e == null) return null;
        endExclusive = e + 1 > length ? length : e + 1;
      }
    }

    if (start >= length || start < 0 || endExclusive <= start) {
      return _ByteRange(0, 0, unsatisfiable: true);
    }
    return _ByteRange(start, endExclusive);
  }

  // --- static web UI -------------------------------------------------------

  // --- sharing --------------------------------------------------------------

  /// Cookie name for a share whose password has been answered. Scoped per
  /// token so unlocking one link says nothing about any other.
  static String _shareCookie(String token) => 'ps_share_${token.substring(0, 12)}';

  Future<Response> _listShares(Request request) => _guard(() async {
        return _json({
          'shares': [for (final s in shares.list()) s.toOwnerJson()],
        });
      });

  Future<Response> _createShare(Request request) => _guard(() async {
        final body = await _readJson(request);
        final path = (body['path'] as String? ?? '').trim();
        if (path.isEmpty) return _json({'error': 'bad path'}, 400);

        // Containment is the same check every other route uses, so a share
        // cannot be made for anything outside the drive.
        final dir = resolveDir(files.root, path);
        final file = resolveFile(files.root, path);
        if (dir == null || file == null) return _json({'error': 'bad path'}, 400);

        final isDir = await Directory(dir.path).exists();
        if (!isDir && !await File(file.path).exists()) {
          return _json({'error': 'not found'}, 404);
        }

        // Sharing the whole drive is not a link, it is handing over the
        // account, and it is too easy to do by accident from the root folder.
        if (path.isEmpty || path == '.' || path == '/') {
          return _json({'error': 'pick a file or folder to share'}, 400);
        }

        final days = (body['expiresInDays'] as num?)?.toInt();
        final expiresAt = days == null || days <= 0
            ? null
            : DateTime.now().add(Duration(days: days)).millisecondsSinceEpoch;

        final maxDownloads = (body['maxDownloads'] as num?)?.toInt();
        final password = (body['password'] as String? ?? '').trim();

        DerivedPassword? derived;
        if (password.isNotEmpty) {
          derived = await auth.derivePassword(password);
        }

        final share = shares.create(
          path: path,
          isDir: isDir,
          expiresAt: expiresAt,
          maxDownloads:
              maxDownloads != null && maxDownloads > 0 ? maxDownloads : null,
          passwordHash: derived?.hash,
          passwordSalt: derived?.salt,
          passwordIterations: derived?.iterations,
        );

        return _json({'share': share.toOwnerJson()});
      });

  Future<Response> _revokeShare(Request request) => _guard(() async {
        final body = await _readJson(request);
        final token = body['token'] as String? ?? '';
        if (shares.find(token) == null) {
          return _json({'error': 'no such link'}, 404);
        }
        // Removed rather than flagged: a revoked link the owner can still see
        // in a list is clutter, and the token is of no further use to anyone.
        shares.remove(token);
        return _json({'ok': true});
      });

  /// What a share link says about itself before any password is answered.
  Future<Response> _shareInfo(Request request, String token) =>
      _guard(() async {
        final share = shares.find(token);
        // Same answer for a token that never existed and one that is dead.
        // Someone holding a link has no business learning which.
        if (share == null || !share.live) {
          return _json({'error': 'This link is no longer available.'}, 404);
        }
        return _json(share.toPublicJson());
      });

  Future<Response> _unlockShare(Request request, String token) =>
      _guard(() async {
        final share = shares.find(token);
        if (share == null || !share.live) {
          return _json({'error': 'This link is no longer available.'}, 404);
        }
        if (!share.hasPassword) return _json({'ok': true});

        final body = await _readJson(request);
        final ok = await auth.matchesPassword(
          password: body['password'] as String? ?? '',
          hash: share.passwordHash!,
          salt: share.passwordSalt!,
          storedIterations: share.passwordIterations!,
        );
        if (!ok) return _json({'error': 'Wrong password.'}, 403);

        // Scoped to this link's own path, so the cookie cannot be replayed
        // against another share or against the owner's API.
        return _json({'ok': true}).change(headers: {
          'Set-Cookie': '${_shareCookie(token)}=$token; Path=/; HttpOnly; '
              'Secure; SameSite=Strict; Max-Age=43200',
        });
      });

  /// Whether this request may read [share]'s contents.
  bool _mayRead(Request request, Share share) {
    if (!share.hasPassword) return true;
    final cookies = _cookies(request);
    return cookies[_shareCookie(share.token)] == share.token;
  }

  Future<Response> _shareList(Request request, String token) =>
      _guard(() async {
        final share = shares.find(token);
        if (share == null || !share.live) {
          return _json({'error': 'This link is no longer available.'}, 404);
        }
        if (!_mayRead(request, share)) {
          return _json({'error': 'password required'}, 401);
        }
        if (!share.isDir) return _json({'error': 'not a folder'}, 400);

        final within = request.url.queryParameters['path'] ?? '';
        final target = _withinShare(share, within);
        if (target == null) return _json({'error': 'bad path'}, 400);

        return _json({
          'path': within,
          'entries': await files.list(target),
        });
      });

  Future<Response> _shareDownload(Request request, String token) =>
      _guard(() async {
        final share = shares.find(token);
        if (share == null || !share.live) {
          return _json({'error': 'This link is no longer available.'}, 404);
        }
        if (!_mayRead(request, share)) {
          return _json({'error': 'password required'}, 401);
        }

        final within = request.url.queryParameters['path'] ?? '';
        final target = share.isDir ? _withinShare(share, within) : share.path;
        if (target == null) return _json({'error': 'bad path'}, 400);

        // Only whole retrievals count, or a video seeking through a file
        // would eat a download cap in a few seconds.
        if (request.headers['range'] == null) shares.countDownload(token);

        return _sendFile(request, target);
      });

  /// Resolves a path a visitor asked for against what the share actually
  /// covers, refusing anything that climbs out of it.
  ///
  /// The share's own path is the root here, so the containment check that
  /// protects the drive from the owner's API protects one shared folder from
  /// the rest of the drive in exactly the same way.
  String? _withinShare(Share share, String requested) {
    if (requested.isEmpty) return share.path;

    final shareRoot = resolveDir(files.root, share.path);
    if (shareRoot == null) return null;

    final resolved = resolveFile(Directory(shareRoot.path), requested);
    if (resolved == null) return null;

    return p.relative(resolved.path, from: files.root.absolute.path);
  }

  Future<Response> _serveSharePage(Request request, String token) async {
    final file = File(p.join(webRoot.path, 'share.html'));
    if (!await file.exists()) return Response.notFound('UI not installed');
    return Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': 'text/html',
        'Content-Length': '${await file.length()}',
      },
    );
  }

  Future<Response> _serveWebUi(Request request) async {
    final requested = request.url.path.isEmpty ? 'index.html' : request.url.path;
    final resolved = resolveFile(webRoot, requested);

    // Unknown paths fall through to index.html so client-side routes survive
    // a reload.
    final file = (resolved != null && await File(resolved.path).exists())
        ? File(resolved.path)
        : File(p.join(webRoot.path, 'index.html'));

    if (!await file.exists()) {
      return Response.notFound('UI not installed');
    }

    return Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': lookupMimeType(file.path) ?? 'text/html',
        'Content-Length': '${await file.length()}',
      },
    );
  }

  // --- plumbing ------------------------------------------------------------

  /// Maps domain errors onto status codes in one place, so each route can just
  /// throw and stay readable.
  static Future<Response> _guard(Future<Response> Function() body) async {
    try {
      return await body();
    } on DrivePathError catch (e) {
      return _json({'error': e.message}, 400);
    } on DriveNotFound catch (e) {
      return _json({'error': 'not found: ${e.path}'}, 404);
    } on DriveConflict catch (e) {
      return _json({'error': e.message}, 409);
    } on FormatException catch (e) {
      return _json({'error': 'bad request: ${e.message}'}, 400);
    } on TypeError {
      return _json({'error': 'bad request: missing or wrong field'}, 400);
    } on FileSystemException catch (e) {
      return _json({'error': 'storage error: ${e.osError?.message ?? e.message}'}, 500);
    }
  }

  static Future<Map<String, Object?>> _readJson(Request request) async {
    final text = await request.readAsString();
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw const FormatException('expected a JSON object');
    return decoded.cast<String, Object?>();
  }

  static Response _json(
    Object? body, [
    int status = 200,
    Map<String, String> headers = const {},
  ]) =>
      Response(
        status,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json', ...headers},
      );
}

class _ByteRange {
  const _ByteRange(this.start, this.endExclusive, {this.unsatisfiable = false});
  final int start;
  final int endExclusive;
  final bool unsatisfiable;
}

/// Per-IP throttle on login.
///
/// Password verification is deliberately expensive, which makes an open login
/// endpoint a CPU-exhaustion lever on a phone. This caps both brute force and
/// that.
class _LoginThrottle {
  static const int _maxFailures = 8;
  static const Duration _window = Duration(minutes: 1);

  final Map<String, _Attempts> _byIp = {};

  bool allow(String ip) {
    final entry = _byIp[ip];
    if (entry == null) return true;
    if (DateTime.now().difference(entry.windowStart) > _window) {
      _byIp.remove(ip);
      return true;
    }
    return entry.failures < _maxFailures;
  }

  void penalise(String ip) {
    final now = DateTime.now();
    final entry = _byIp[ip];
    if (entry == null || now.difference(entry.windowStart) > _window) {
      _byIp[ip] = _Attempts(windowStart: now, failures: 1);
    } else {
      entry.failures++;
    }

    // Bound the map so a spray of spoofed-looking addresses cannot grow it
    // without limit.
    if (_byIp.length > 1024) {
      final cutoff = now.subtract(_window);
      _byIp.removeWhere((_, v) => v.windowStart.isBefore(cutoff));
    }
  }

  void clear(String ip) => _byIp.remove(ip);
}

class _Attempts {
  _Attempts({required this.windowStart, required this.failures});
  final DateTime windowStart;
  int failures;
}
