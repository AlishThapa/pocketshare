// End-to-end exercise of the drive server. Run: dart run tool/smoke_server.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:pocketshare/server/auth.dart';
import 'package:pocketshare/server/files.dart';
import 'package:pocketshare/server/server.dart';
import 'package:pocketshare/server/store.dart';
import 'package:pocketshare/server/uploads.dart';

int passed = 0, failed = 0;

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    passed++;
    print('  PASS  $label');
  } else {
    failed++;
    print('  FAIL  $label  $detail');
  }
}

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('ps_smoke');
  final root = Directory('${tmp.path}/drive')..createSync(recursive: true);
  final web = Directory('${tmp.path}/web')..createSync(recursive: true);
  File('${web.path}/index.html').writeAsStringSync('<h1>drive</h1>');

  final store = await DriveStore.open(root: root, dbFile: File('${tmp.path}/meta.db'));
  final auth = Auth(store);
  await auth.createAccount(username: 'alish', password: 'a-long-enough-pass');

  final server = DriveServer(
    store: store,
    auth: auth,
    files: DriveFiles(root),
    uploads: UploadManager(root: root, staging: Directory('${tmp.path}/staging')),
    webRoot: web,
    port: 0,
  );
  await server.start();
  final base = 'http://127.0.0.1:${server.boundPort}';
  final client = HttpClient();

  Future<HttpClientResponse> req(
    String method,
    String path, {
    Object? json,
    String? cookie,
    Map<String, String> headers = const {},
    List<int>? raw,
  }) async {
    final r = await client.openUrl(method, Uri.parse('$base$path'));
    if (cookie != null) r.headers.set('cookie', cookie);
    // Stand in for a browser: state-changing requests carry an Origin, and
    // the server refuses them without one.
    r.headers.set('origin', base);
    headers.forEach(r.headers.set);
    if (json != null) {
      r.headers.contentType = ContentType.json;
      r.add(utf8.encode(jsonEncode(json)));
    }
    if (raw != null) r.add(raw);
    return r.close();
  }

  Future<Map<String, Object?>> body(HttpClientResponse r) async {
    final t = await r.transform(utf8.decoder).join();
    return t.isEmpty ? {} : (jsonDecode(t) as Map).cast<String, Object?>();
  }

  print('\n-- health (unauthenticated) --');
  var r = await req('GET', '/api/health');
  var b = await body(r);
  check('health 200', r.statusCode == 200, '${r.statusCode}');
  check('reports claimed', b['claimed'] == true);

  print('\n-- auth --');
  r = await req('GET', '/api/files');
  await body(r);
  check('files requires session', r.statusCode == 401, '${r.statusCode}');

  r = await req('POST', '/api/auth/login', json: {'username': 'alish', 'password': 'wrong'});
  await body(r);
  check('bad password rejected', r.statusCode == 401, '${r.statusCode}');

  r = await req('POST', '/api/auth/login',
      json: {'username': 'alish', 'password': 'a-long-enough-pass'});
  await body(r);
  final setCookie = r.headers['set-cookie']?.first ?? '';
  final cookie = setCookie.split(';').first;
  check('login 200', r.statusCode == 200, '${r.statusCode}');
  check('cookie is HttpOnly', setCookie.contains('HttpOnly'));
  check('cookie is Secure', setCookie.contains('Secure'));
  check('cookie is SameSite=Strict', setCookie.contains('SameSite=Strict'));

  print('\n-- path traversal --');
  for (final evil in ['../../etc/passwd', '..%2f..%2fetc', '/etc/passwd', 'a/../../..']) {
    r = await req('GET', '/api/files?path=${Uri.encodeQueryComponent(evil)}',
        cookie: cookie);
    await body(r);
    check('refuses "$evil"', r.statusCode == 400 || r.statusCode == 404,
        'got ${r.statusCode}');
  }

  print('\n-- folders --');
  r = await req('POST', '/api/folders', json: {'path': 'Photos'}, cookie: cookie);
  await body(r);
  check('mkdir 200', r.statusCode == 200, '${r.statusCode}');

  r = await req('GET', '/api/files', cookie: cookie);
  b = await body(r);
  check('folder listed', (b['entries'] as List).length == 1);

  print('\n-- chunked upload --');
  final payload = List<int>.generate(5 * 1024 * 1024, (i) => (i * 31) % 256);
  const chunkSize = 1024 * 1024;

  r = await req('POST', '/api/uploads',
      json: {'path': 'Photos/big.bin', 'size': payload.length, 'chunkSize': chunkSize},
      cookie: cookie);
  b = await body(r);
  final uploadId = b['id'] as String;
  final chunkCount = b['chunkCount'] as int;
  check('upload session created', r.statusCode == 200 && chunkCount == 5,
      'chunks=$chunkCount');

  // Deliberately skip chunk 2, then verify completion refuses and resume works.
  for (var i = 0; i < chunkCount; i++) {
    if (i == 2) continue;
    final start = i * chunkSize;
    final end = min(start + chunkSize, payload.length);
    r = await req('PUT', '/api/uploads/$uploadId/chunks/$i',
        cookie: cookie, raw: payload.sublist(start, end));
    final cb = await body(r);
    if (r.statusCode != 200) check('chunk $i accepted', false, '${r.statusCode} $cb');
  }

  r = await req('POST', '/api/uploads/$uploadId/complete', cookie: cookie);
  b = await body(r);
  check('incomplete upload refused', r.statusCode == 409, '${r.statusCode}');

  r = await req('GET', '/api/uploads/$uploadId', cookie: cookie);
  b = await body(r);
  check('reports the missing chunk', (b['missing'] as List).join() == '2',
      '${b['missing']}');

  r = await req('PUT', '/api/uploads/$uploadId/chunks/2',
      cookie: cookie, raw: payload.sublist(2 * chunkSize, 3 * chunkSize));
  b = await body(r);
  check('resent chunk accepted', r.statusCode == 200, '${r.statusCode} $b');

  r = await req('POST', '/api/uploads/$uploadId/complete', cookie: cookie);
  b = await body(r);
  check('upload completes after resume', r.statusCode == 200, '${r.statusCode}');

  final written = File('${root.path}/Photos/big.bin');
  check('file size matches', written.lengthSync() == payload.length,
      '${written.lengthSync()} vs ${payload.length}');
  check('bytes match', _sameBytes(written.readAsBytesSync(), payload));

  print('\n-- download + range --');
  r = await req('GET', '/api/download?path=Photos%2Fbig.bin', cookie: cookie);
  final full = await _collect(r);
  check('full download 200', r.statusCode == 200, '${r.statusCode}');
  check('full body intact', _sameBytes(full, payload));
  check('advertises ranges', r.headers.value('accept-ranges') == 'bytes');

  r = await req('GET', '/api/download?path=Photos%2Fbig.bin',
      cookie: cookie, headers: {'range': 'bytes=100-199'});
  final part = await _collect(r);
  check('range 206', r.statusCode == 206, '${r.statusCode}');
  check('range length 100', part.length == 100, '${part.length}');
  check('range bytes correct', _sameBytes(part, payload.sublist(100, 200)));
  check('content-range header',
      r.headers.value('content-range') == 'bytes 100-199/${payload.length}',
      '${r.headers.value('content-range')}');

  r = await req('GET', '/api/download?path=Photos%2Fbig.bin',
      cookie: cookie, headers: {'range': 'bytes=-50'});
  final suffix = await _collect(r);
  check('suffix range', r.statusCode == 206 && suffix.length == 50,
      '${r.statusCode}/${suffix.length}');

  r = await req('GET', '/api/download?path=Photos%2Fbig.bin',
      cookie: cookie, headers: {'range': 'bytes=99999999-'});
  await _collect(r);
  check('unsatisfiable range 416', r.statusCode == 416, '${r.statusCode}');

  // A non-ASCII filename used to be written straight into Content-Disposition.
  // HTTP header values are Latin-1, so dart:io threw while writing the headers
  // and the response never completed: the client hung forever rather than
  // failing. These names are ordinary here, so the hang was reachable by just
  // uploading a file named in Nepali.
  print('\n-- non-ASCII filenames --');
  for (final name in ['नेपाली फाइल.txt', '🎉 party.txt', 'café.txt']) {
    File('${root.path}/$name').writeAsStringSync('hello');
    final encoded = Uri.encodeQueryComponent(name);
    r = await req('GET', '/api/download?path=$encoded', cookie: cookie)
        .timeout(const Duration(seconds: 10), onTimeout: () => throw 'hung');
    final got = await _collect(r);
    check('download "$name" 200', r.statusCode == 200, '${r.statusCode}');
    check('download "$name" body', got.length == 5, '${got.length}');
    final cd = r.headers.value('content-disposition') ?? '';
    check('"$name" carries filename*', cd.contains("filename*=UTF-8''"), cd);
    check('"$name" ascii fallback is latin-1',
        cd.runes.every((c) => c < 0x100), cd);
  }

  // Moving a folder into itself reached rename(2) and surfaced as a 500,
  // because `isWithin` is false for a path against itself.
  print('\n-- move guards --');
  r = await req('POST', '/api/folders', json: {'path': 'SelfMove'}, cookie: cookie);
  await body(r);
  r = await req('POST', '/api/move',
      json: {'from': 'SelfMove', 'toDir': 'SelfMove'}, cookie: cookie);
  await body(r);
  check('move folder into itself 409', r.statusCode == 409, '${r.statusCode}');
  check('folder survived the attempt',
      Directory('${root.path}/SelfMove').existsSync());

  r = await req('POST', '/api/folders', json: {'path': 'SelfMove/Inner'}, cookie: cookie);
  await body(r);
  r = await req('POST', '/api/move',
      json: {'from': 'SelfMove', 'toDir': 'SelfMove/Inner'}, cookie: cookie);
  await body(r);
  check('move folder into descendant 409', r.statusCode == 409, '${r.statusCode}');

  // The Origin check used to run only when an Origin was present, so a client
  // outside the same-origin policy passed while browsers were held to it.
  print('\n-- origin --');
  final noOrigin = await client.openUrl('POST', Uri.parse('$base/api/folders'));
  noOrigin.headers.set('cookie', cookie);
  noOrigin.headers.contentType = ContentType.json;
  noOrigin.add(utf8.encode(jsonEncode({'path': 'NoOriginFolder'})));
  final noOriginRes = await noOrigin.close();
  await _collect(noOriginRes);
  check('mutation without Origin 403', noOriginRes.statusCode == 403,
      '${noOriginRes.statusCode}');
  check('no folder created',
      !Directory('${root.path}/NoOriginFolder').existsSync());

  r = await req('POST', '/api/folders',
      json: {'path': 'EvilFolder'},
      cookie: cookie,
      headers: {'origin': 'https://evil.example'});
  await body(r);
  check('mutation from foreign Origin 403', r.statusCode == 403, '${r.statusCode}');

  print('\n-- trash --');
  r = await req('POST', '/api/delete', json: {'path': 'Photos/big.bin'}, cookie: cookie);
  await body(r);
  check('delete 200', r.statusCode == 200, '${r.statusCode}');
  check('file gone from drive', !written.existsSync());

  r = await req('GET', '/api/trash', cookie: cookie);
  b = await body(r);
  final trashed = (b['entries'] as List).cast<Map<String, Object?>>();
  check('one item in trash', trashed.length == 1, '${trashed.length}');

  r = await req('POST', '/api/trash/restore',
      json: {'id': trashed.first['id']}, cookie: cookie);
  await body(r);
  check('restore 200', r.statusCode == 200, '${r.statusCode}');
  check('file is back', written.existsSync());
  check('restored size intact', written.lengthSync() == payload.length);

  print('\n-- logout --');
  r = await req('POST', '/api/auth/logout', cookie: cookie);
  await body(r);
  r = await req('GET', '/api/files', cookie: cookie);
  await body(r);
  check('session dead after logout', r.statusCode == 401, '${r.statusCode}');

  print('\n-- share links --');
  {
    // Fresh session: an earlier case signed the first one out.
    r = await req('POST', '/api/auth/login',
        json: {'username': 'alish', 'password': 'a-long-enough-pass'});
    await body(r);
    final owner = (r.headers['set-cookie']?.first ?? '').split(';').first;

    File('${root.path}/shared.txt').writeAsStringSync('the shared bytes');
    Directory('${root.path}/ShareDir').createSync();
    File('${root.path}/ShareDir/inside.txt').writeAsStringSync('inside');
    File('${root.path}/secret.txt').writeAsStringSync('not shared');

    r = await req('POST', '/api/shares',
        json: {'path': 'shared.txt', 'expiresInDays': 7}, cookie: owner);
    var out = await body(r);
    check('a link is created', r.statusCode == 200, '${r.statusCode}');
    final share = (out['share'] as Map).cast<String, Object?>();
    final token = share['token'] as String;
    check('the token is long enough to be unguessable',
        token.length >= 40, '${token.length}');
    check('it reports an expiry', share['expiresAt'] != null);

    // The point of the whole feature: this works with no cookie at all.
    r = await req('GET', '/api/share/$token');
    out = await body(r);
    check('a stranger can read the link without signing in',
        r.statusCode == 200, '${r.statusCode}');
    check('it names the file', out['name'] == 'shared.txt', '${out['name']}');
    check('it does not leak the path',
        !out.containsKey('path'), '${out.keys}');

    r = await req('GET', '/api/share/$token/download');
    List<int> bytes = await _collect(r);
    check('and download it', r.statusCode == 200 && utf8.decode(bytes) == 'the shared bytes',
        '${r.statusCode}');

    // A link is for one path. Nothing else on the drive comes with it.
    r = await req('GET', '/api/share/$token/download?path=../secret.txt');
    bytes = await _collect(r);
    final served = utf8.decode(bytes, allowMalformed: true);
    check('a single-file link ignores any other path it is handed',
        r.statusCode == 200 && served == 'the shared bytes', served);
    check('and certainly does not serve the other file',
        !served.contains('not shared'), served);

    r = await req('GET', '/api/share/bogus-token-that-never-existed');
    await body(r);
    check('an unknown token is a 404', r.statusCode == 404, '${r.statusCode}');

    print('\n-- a shared folder is a root, not a doorway --');
    r = await req('POST', '/api/shares',
        json: {'path': 'ShareDir', 'expiresInDays': 0}, cookie: owner);
    out = await body(r);
    final dirToken = ((out['share'] as Map)['token']) as String;

    r = await req('GET', '/api/share/$dirToken/list');
    out = await body(r);
    check('the folder lists', r.statusCode == 200, '${r.statusCode}');
    check('it shows what is inside',
        (out['entries'] as List).length == 1, '${out['entries']}');

    for (final escape in ['..', '../', '../secret.txt', '/etc/passwd']) {
      r = await req(
          'GET', '/api/share/$dirToken/download?path=${Uri.encodeQueryComponent(escape)}');
      final got = await _collect(r);
      final leaked = utf8.decode(got, allowMalformed: true).contains('not shared');
      check('"$escape" cannot climb out of the shared folder', !leaked,
          '${r.statusCode}');
    }

    print('\n-- expiry, caps and revocation --');
    r = await req('POST', '/api/shares',
        json: {'path': 'shared.txt', 'expiresInDays': 7, 'maxDownloads': 1},
        cookie: owner);
    out = await body(r);
    final capped = ((out['share'] as Map)['token']) as String;

    r = await req('GET', '/api/share/$capped/download');
    await _collect(r);
    check('the first download of a capped link works', r.statusCode == 200,
        '${r.statusCode}');
    r = await req('GET', '/api/share/$capped/download');
    await body(r);
    check('the second is refused', r.statusCode == 404, '${r.statusCode}');

    r = await req('POST', '/api/shares/revoke',
        json: {'token': token}, cookie: owner);
    await body(r);
    check('revoking succeeds', r.statusCode == 200, '${r.statusCode}');
    r = await req('GET', '/api/share/$token/download');
    await body(r);
    check('a revoked link stops working', r.statusCode == 404, '${r.statusCode}');

    print('\n-- a password on a link --');
    r = await req('POST', '/api/shares',
        json: {'path': 'shared.txt', 'expiresInDays': 7, 'password': 'open-sesame-please'},
        cookie: owner);
    out = await body(r);
    final locked = ((out['share'] as Map)['token']) as String;

    r = await req('GET', '/api/share/$locked');
    out = await body(r);
    check('the link says a password is needed', out['needsPassword'] == true);

    r = await req('GET', '/api/share/$locked/download');
    await body(r);
    check('and refuses the bytes without one', r.statusCode == 401,
        '${r.statusCode}');

    r = await req('POST', '/api/share/$locked/unlock',
        json: {'password': 'wrong-one-entirely'});
    await body(r);
    check('a wrong password is refused', r.statusCode == 403, '${r.statusCode}');

    r = await req('POST', '/api/share/$locked/unlock',
        json: {'password': 'open-sesame-please'});
    await body(r);
    check('the right one is accepted', r.statusCode == 200, '${r.statusCode}');
    final unlockCookie =
        (r.headers['set-cookie']?.first ?? '').split(';').first;
    check('and hands back a cookie', unlockCookie.isNotEmpty, unlockCookie);

    r = await req('GET', '/api/share/$locked/download', cookie: unlockCookie);
    bytes = await _collect(r);
    check('which then opens it',
        r.statusCode == 200 && utf8.decode(bytes) == 'the shared bytes',
        '${r.statusCode}');

    // The cookie is named for its own token, so it cannot be carried across.
    r = await req('POST', '/api/shares',
        json: {'path': 'secret.txt', 'expiresInDays': 7, 'password': 'another-password'},
        cookie: owner);
    out = await body(r);
    final other = ((out['share'] as Map)['token']) as String;
    r = await req('GET', '/api/share/$other/download', cookie: unlockCookie);
    await body(r);
    check('unlocking one link does not unlock another', r.statusCode == 401,
        '${r.statusCode}');

    print('\n-- a share is not a session --');
    for (final ownerOnly in ['/api/files', '/api/shares', '/api/trash', '/api/me']) {
      r = await req('GET', ownerOnly, cookie: unlockCookie);
      await body(r);
      check('$ownerOnly stays shut to a share cookie', r.statusCode == 401,
          '${r.statusCode}');
    }

    print('\n-- links follow their file --');
    r = await req('POST', '/api/shares',
        json: {'path': 'shared.txt', 'expiresInDays': 7}, cookie: owner);
    out = await body(r);
    final following = ((out['share'] as Map)['token']) as String;

    r = await req('POST', '/api/rename',
        json: {'from': 'shared.txt', 'to': 'renamed.txt'}, cookie: owner);
    await body(r);
    r = await req('GET', '/api/share/$following/download');
    bytes = await _collect(r);
    check('a rename does not break a link already sent out',
        r.statusCode == 200 && utf8.decode(bytes) == 'the shared bytes',
        '${r.statusCode}');

    r = await req('POST', '/api/delete',
        json: {'path': 'renamed.txt'}, cookie: owner);
    await body(r);
    r = await req('GET', '/api/share/$following');
    await body(r);
    check('trashing the file retires its links', r.statusCode == 404,
        '${r.statusCode}');

    print('\n-- the listing says what is public --');
    File('${root.path}/marked.txt').writeAsStringSync('x');
    r = await req('POST', '/api/shares',
        json: {'path': 'marked.txt', 'expiresInDays': 7}, cookie: owner);
    await body(r);
    r = await req('GET', '/api/files?path=', cookie: owner);
    out = await body(r);
    check('a shared path is reported with the listing',
        (out['shared'] as List).contains('marked.txt'), '${out['shared']}');
  }

  print('\n-- what a file is allowed to be --');
  // An earlier case signs the first session out, so take a fresh one.
  r = await req('POST', '/api/auth/login',
      json: {'username': 'alish', 'password': 'a-long-enough-pass'});
  await body(r);
  final liveCookie =
      (r.headers['set-cookie']?.first ?? '').split(';').first;
  check('signed back in for the type checks', r.statusCode == 200,
      '${r.statusCode}');

  // The attack this closes: a file in the drive pulled back in as a
  // subresource. Content-Disposition does not apply to those, so the MIME
  // type is the only thing standing between an uploaded .js and it running
  // as the signed-in owner. Anything off the allowlist is octet-stream.
  for (final hostile in ['evil.js', 'page.html', 'sneaky.svg', 'style.css']) {
    File('${root.path}/$hostile').writeAsStringSync('x');
    final q = Uri.encodeQueryComponent(hostile);

    r = await req('GET', '/api/download?path=$q&inline=1', cookie: liveCookie);
    await _collect(r);
    final type = r.headers.contentType?.mimeType;
    check('$hostile is served as octet-stream',
        type == 'application/octet-stream', '$type');
    check('$hostile is not served inline',
        (r.headers.value('content-disposition') ?? '').startsWith('attachment'),
        r.headers.value('content-disposition') ?? '');
  }

  for (final safe in {
    'photo.png': 'image/png',
    'clip.mp4': 'video/mp4',
    'notes.txt': 'text/plain',
    'paper.pdf': 'application/pdf',
  }.entries) {
    File('${root.path}/${safe.key}').writeAsStringSync('x');
    final q = Uri.encodeQueryComponent(safe.key);

    r = await req('GET', '/api/download?path=$q&inline=1', cookie: liveCookie);
    await _collect(r);
    check('${safe.key} keeps its type',
        r.headers.contentType?.mimeType == safe.value,
        '${r.headers.contentType?.mimeType}');
    check('${safe.key} may be shown inline',
        r.headers.value('content-disposition') == 'inline',
        r.headers.value('content-disposition') ?? '');

    // Without inline=1 it is still a download, and still truthfully typed:
    // an image cannot execute, so there is nothing to hide from.
    r = await req('GET', '/api/download?path=$q', cookie: liveCookie);
    await _collect(r);
    check('${safe.key} defaults to a download',
        (r.headers.value('content-disposition') ?? '').startsWith('attachment'),
        r.headers.value('content-disposition') ?? '');
  }

  print('\n-- framing --');
  r = await req('GET', '/', cookie: liveCookie);
  await _collect(r);
  check('this origin may frame its own preview',
      r.headers.value('x-frame-options') == 'SAMEORIGIN',
      r.headers.value('x-frame-options') ?? '');
  check('nobody else may frame it',
      (r.headers.value('content-security-policy') ?? '')
          .contains("frame-ancestors 'self'"),
      r.headers.value('content-security-policy') ?? '');

  client.close(force: true);
  await server.stop();
  print('\n-- disconnecting forgets who owns the drive --');
  // The point of the disconnect teardown: nobody can sign in afterwards, and
  // everyone already signed in is out, while nothing about the files moves.
  const liveSession = 'a-session-token-hash';
  store.putSession(liveSession, 'a browser');

  final before = store.account?.username;
  check('there was an account', before == 'alish', '$before');
  check('there was a live session', store.touchSession(liveSession));

  store.wipeCredentials();

  check('the account is gone', !store.hasAccount);
  check('account() reads as empty', store.account == null);
  check('the session no longer validates', !store.touchSession(liveSession));
  check('a new owner can be created afterwards', await () async {
    await auth.createAccount(username: 'someoneelse', password: 'another-long-pass');
    return store.account?.username == 'someoneelse';
  }());

  store.close();
  tmp.deleteSync(recursive: true);

  print('\n$passed passed, $failed failed\n');
  exit(failed == 0 ? 0 : 1);
}

Future<List<int>> _collect(HttpClientResponse r) async {
  final out = <int>[];
  await for (final c in r) {
    out.addAll(c);
  }
  return out;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
