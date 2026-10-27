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

  client.close(force: true);
  await server.stop();
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
