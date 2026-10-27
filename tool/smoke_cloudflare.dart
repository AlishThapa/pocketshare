// Exercises the Cloudflare client and the host provisioner against a fake
// Cloudflare. Run: dart run tool/smoke_cloudflare.dart
import 'dart:convert';
import 'dart:io';

import 'package:pocketshare/cloudflare/api.dart';
import 'package:pocketshare/cloudflare/host_provisioner.dart';
import 'package:pocketshare/cloudflare/names.dart';

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

/// Stands in for api.cloudflare.com. Records what it was asked to do, so a
/// test can assert on the calls as well as the result.
class FakeCloudflare {
  FakeCloudflare();

  late HttpServer _server;
  final List<String> calls = [];
  final Map<String, Map<String, Object?>> tunnels = {};
  final List<Map<String, Object?>> dns = [];

  /// path fragment -> (status, errorCode, message)
  final Map<String, (int, int, String)> failures = {};

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  void failOn(String fragment, {int status = 403, int code = 9109, String message = 'denied'}) {
    failures[fragment] = (status, code, message);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;
    calls.add('$method $path');

    final auth = req.headers.value('authorization');
    if (auth != 'Bearer good-token') {
      return _send(req, 401, {
        'success': false,
        'errors': [
          {'code': 1000, 'message': 'Invalid API Token'}
        ],
      });
    }

    for (final entry in failures.entries) {
      if (path.contains(entry.key)) {
        final (status, code, message) = entry.value;
        return _send(req, status, {
          'success': false,
          'errors': [
            {'code': code, 'message': message}
          ],
        });
      }
    }

    final body = await utf8.decoder.bind(req).join();
    final json = body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(body) as Map<String, Object?>;

    if (path.endsWith('/user/tokens/verify')) {
      return _ok(req, {'status': 'active'});
    }

    if (path.endsWith('/zones') && method == 'GET') {
      final wanted = req.uri.queryParameters['name'];
      final all = [
        {'id': 'zone-1', 'name': 'thapaalish.com.np'},
        {'id': 'zone-2', 'name': 'example.com'},
      ];
      return _ok(req,
          wanted == null ? all : all.where((z) => z['name'] == wanted).toList());
    }

    if (path.endsWith('/accounts') && method == 'GET') {
      return _ok(req, [
        {'id': 'acct-1', 'name': 'Alish'}
      ]);
    }

    if (path.endsWith('/cfd_tunnel') && method == 'POST') {
      final name = json['name'] as String;
      if (tunnels.values.any((t) => t['name'] == name)) {
        return _send(req, 409, {
          'success': false,
          'errors': [
            {'code': 1013, 'message': 'tunnel with name already exists'}
          ],
        });
      }
      final id = 'tun-${tunnels.length + 1}';
      tunnels[id] = {'id': id, 'name': name, 'ingress': null};
      return _ok(req, {'id': id, 'name': name, 'token': 'tunnel-token-$id'});
    }

    if (path.contains('/cfd_tunnel/') && path.endsWith('/configurations')) {
      final id = path.split('/cfd_tunnel/')[1].split('/').first;
      tunnels[id]?['ingress'] = json['config'];
      return _ok(req, {'ok': true});
    }

    if (path.contains('/cfd_tunnel/') && path.endsWith('/token')) {
      final id = path.split('/cfd_tunnel/')[1].split('/').first;
      return _ok(req, 'tunnel-token-$id');
    }

    if (path.contains('/cfd_tunnel/') && method == 'DELETE') {
      tunnels.remove(path.split('/cfd_tunnel/')[1]);
      return _ok(req, {'ok': true});
    }

    if (path.endsWith('/dns_records') && method == 'GET') {
      final name = req.uri.queryParameters['name'];
      return _ok(req, dns.where((r) => r['name'] == name).toList());
    }

    if (path.endsWith('/dns_records') && method == 'POST') {
      dns.add({...json, 'id': 'rec-${dns.length + 1}'});
      return _ok(req, {'id': 'rec-${dns.length}'});
    }

    if (path.contains('/dns_records/') && method == 'PUT') {
      final id = path.split('/dns_records/').last;
      final i = dns.indexWhere((r) => r['id'] == id);
      if (i >= 0) dns[i] = {...json, 'id': id};
      return _ok(req, {'id': id});
    }

    if (path.contains('/dns_records/') && method == 'DELETE') {
      dns.removeWhere((r) => r['id'] == path.split('/dns_records/').last);
      return _ok(req, {'ok': true});
    }

    return _send(req, 404, {
      'success': false,
      'errors': [
        {'code': 7003, 'message': 'no route for $path'}
      ],
    });
  }

  Future<void> _ok(HttpRequest req, Object? result) =>
      _send(req, 200, {'success': true, 'errors': [], 'result': result});

  Future<void> _send(HttpRequest req, int status, Object body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }
}

Future<void> main() async {
  final fake = FakeCloudflare();
  await fake.start();
  final base = Uri.parse(fake.base);

  CloudflareApi api([String token = 'good-token']) =>
      CloudflareApi(token: token, baseUrl: base);

  print('\n-- name rules --');
  check('accepts a normal name', DriveName.isValid('alishdrive'));
  check('accepts digits and inner hyphens', DriveName.isValid('alish-2026'));
  check('rejects 2 characters', !DriveName.isValid('ab'));
  check('rejects a leading hyphen', !DriveName.isValid('-alish'));
  check('rejects a trailing hyphen', !DriveName.isValid('alish-'));
  check('rejects uppercase after normalize',
      DriveName.normalize('ALISH') == 'alish');
  check('rejects a dot (two labels deep)', !DriveName.isValid('a.b'));
  check('rejects reserved "www"', !DriveName.isValid('www'));
  check('rejects reserved "provision"', !DriveName.isValid('provision'));
  check('tunnel name is prefixed',
      DriveName.tunnelName('Alish') == 'ps-alish');
  check('problem() explains itself',
      (DriveName.problem('ab') ?? '').contains('3 characters'));

  print('\n-- token and zones --');
  try {
    await api('wrong-token').verify();
    check('bad token rejected', false, 'no error thrown');
  } on CloudflareError catch (e) {
    check('bad token rejected', e.isUnauthorized, '${e.status}/${e.code}');
    check('bad token is not reported as a scope problem', !e.isForbidden);
  }

  await api().verify();
  check('good token verifies', true);

  final zones = await api().zones();
  check('lists zones for the picker', zones.length == 2, '${zones.length}');
  check('zone carries id and name',
      zones.first.id == 'zone-1' && zones.first.name == 'thapaalish.com.np');

  final accounts = await api().accounts();
  check('lists accounts', accounts.single.id == 'acct-1');

  fake.failOn('/zones', status: 403, code: 9109, message: 'insufficient permissions');
  try {
    await api().zones();
    check('wrong-scope token rejected', false, 'no error thrown');
  } on CloudflareError catch (e) {
    check('wrong-scope token rejected', e.isForbidden, '${e.status}/${e.code}');
    check('message names the real problem',
        e.message.contains('insufficient permissions'), e.message);
  }
  fake.failures.clear();

  print('\n-- provisioning --');
  final host = HostProvisioner(
    api: api(),
    accountId: 'acct-1',
    zoneId: 'zone-1',
    zone: 'thapaalish.com.np',
  );

  final made = await host.provision('alishdrive');
  check('hostname is name + zone',
      made.hostname == 'alishdrive.thapaalish.com.np', made.hostname);
  check('returns a tunnel token', made.tunnelToken.startsWith('tunnel-token-'));
  check('tunnel created once', fake.tunnels.length == 1);
  check('tunnel named ps-<name>',
      fake.tunnels.values.single['name'] == 'ps-alishdrive');
  check('ingress configured', fake.tunnels.values.single['ingress'] != null);
  check('one DNS record written', fake.dns.length == 1);
  check('record is a proxied CNAME',
      fake.dns.single['type'] == 'CNAME' && fake.dns.single['proxied'] == true);
  check('record points at the tunnel',
      (fake.dns.single['content'] as String).endsWith('.cfargotunnel.com'));

  check('name is normalized before use', await () async {
    final r = await host.provision('MiXeD');
    return r.hostname == 'mixed.thapaalish.com.np';
  }());

  try {
    await host.provision('ab');
    check('rejects a bad name before any call', false, 'no error thrown');
  } on CloudflareError {
    check('rejects a bad name before any call', true);
  }
  check('no tunnel made for a bad name', fake.tunnels.length == 2);

  print('\n-- duplicate tunnel --');
  try {
    await host.provision('alishdrive');
    check('duplicate tunnel name refused', false, 'no error thrown');
  } on CloudflareError catch (e) {
    check('duplicate tunnel name refused', e.isDuplicateTunnel, '${e.code}');
  }

  print('\n-- rollback --');
  final tunnelsBefore = fake.tunnels.length;
  final dnsBefore = fake.dns.length;
  fake.failOn('/dns_records');
  try {
    await host.provision('rollbackme');
    check('DNS failure surfaces', false, 'no error thrown');
  } on CloudflareError {
    check('DNS failure surfaces', true);
  }
  fake.failures.clear();
  check('the half-made tunnel was deleted',
      fake.tunnels.length == tunnelsBefore, '${fake.tunnels.length}');
  check('no DNS record left behind', fake.dns.length == dnsBefore);
  check('the name is claimable again after rollback', await () async {
    final r = await host.provision('rollbackme');
    return r.hostname == 'rollbackme.thapaalish.com.np';
  }());

  print('\n-- rename keeps the tunnel --');
  final before = fake.tunnels.entries
      .firstWhere((e) => e.value['name'] == 'ps-alishdrive');
  fake.dns.clear();
  await api().upsertCname(
      zoneId: 'zone-1',
      fqdn: 'alishdrive.thapaalish.com.np',
      content: '${before.key}.cfargotunnel.com');
  final renamed = await host.rename(
    from: 'alishdrive',
    to: 'alishmanandhar',
    tunnelId: before.key,
  );
  check('new hostname returned',
      renamed == 'alishmanandhar.thapaalish.com.np', renamed);
  check('tunnel untouched', fake.tunnels.containsKey(before.key));
  check('old name released',
      !fake.dns.any((r) => r['name'] == 'alishdrive.thapaalish.com.np'));
  check('new name published',
      fake.dns.any((r) => r['name'] == 'alishmanandhar.thapaalish.com.np'));

  print('\n-- upsert does not duplicate --');
  fake.dns.clear();
  for (var i = 0; i < 3; i++) {
    await api().upsertCname(
        zoneId: 'zone-1', fqdn: 'x.thapaalish.com.np', content: 'tun-x.cfargotunnel.com');
  }
  check('three upserts leave one record', fake.dns.length == 1, '${fake.dns.length}');

  await fake.stop();
  print('\n$passed passed, $failed failed\n');
  if (failed > 0) exitCode = 1;
}
