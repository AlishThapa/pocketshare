// Exercises the DoH check that keeps a fresh rename from poisoning this
// phone's resolver. Run: dart run tool/smoke_dns.dart
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pocketshare/tunnel/dns_check.dart';

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

/// Stands in for cloudflare-dns.com. Answers whatever the test tells it to,
/// including the ways a resolver fails that are not an answer about the name.
class FakeDoh {
  late HttpServer _server;
  int queries = 0;

  /// name -> JSON body to return.
  final Map<String, Object> answers = {};
  int status = 200;

  /// Names that start as missing and appear after this many queries, which is
  /// what a record being written looks like from the outside.
  final Map<String, int> appearAfter = {};

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      queries++;
      final name = req.uri.queryParameters['name'] ?? '';

      if (status != 200) {
        req.response.statusCode = status;
        await req.response.close();
        return;
      }

      final threshold = appearAfter[name];
      final body = threshold != null && queries < threshold
          ? {'Status': 3}
          : answers[name] ??
              {
                'Status': 0,
                'Answer': [
                  {'name': name, 'type': 1, 'TTL': 300, 'data': '104.21.0.1'}
                ],
              };

      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// Points DnsCheck's queries at the fake by rewriting the host of each
/// request, which is the one thing the class takes from outside.
class RedirectClient extends http.BaseClient {
  RedirectClient(this.base);
  final String base;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final target = Uri.parse(base);
    return _inner.send(
      http.Request(request.method, request.url.replace(
        scheme: target.scheme,
        host: target.host,
        port: target.port,
      ))
        ..headers.addAll(request.headers),
    );
  }

  @override
  void close() => _inner.close();
}

Future<void> main() async {
  final fake = FakeDoh();
  await fake.start();
  final client = RedirectClient(fake.base);

  print('\n-- reading an answer --');
  check('a published name reads as published',
      await DnsCheck.published('newtest.example.com', client: client) == true);

  fake.answers['gone.example.com'] = {'Status': 3};
  check('NXDOMAIN reads as not published',
      await DnsCheck.published('gone.example.com', client: client) == false);

  fake.answers['empty.example.com'] = {'Status': 0, 'Answer': <Object>[]};
  check('NOERROR with no record reads as not published',
      await DnsCheck.published('empty.example.com', client: client) == false);

  print('\n-- a non-answer is not a no --');
  // The distinction that matters: "it is not there" sends the user to fix
  // their address, "I could not ask" sends them to fix their connection.
  fake.answers['broken.example.com'] = {'Status': 2};
  check('SERVFAIL reads as unknown, not as absent',
      await DnsCheck.published('broken.example.com', client: client) == null);

  fake.status = 503;
  check('an HTTP failure reads as unknown',
      await DnsCheck.published('newtest.example.com', client: client) == null);
  fake.status = 200;

  final offline = RedirectClient('http://127.0.0.1:1');
  check('an unreachable resolver reads as unknown',
      await DnsCheck.published('newtest.example.com', client: offline) == null);
  offline.close();

  print('\n-- waiting for a record to appear --');
  fake.queries = 0;
  fake.appearAfter['slow.example.com'] = 3;
  final appeared = await DnsCheck.waitUntilPublished(
    'slow.example.com',
    budget: const Duration(seconds: 5),
    interval: const Duration(milliseconds: 50),
    client: client,
  );
  check('waits through NXDOMAIN until the record lands', appeared);
  check('it really did poll more than once', fake.queries >= 3, '${fake.queries}');

  fake.answers['never.example.com'] = {'Status': 3};
  final gaveUp = await DnsCheck.waitUntilPublished(
    'never.example.com',
    budget: const Duration(milliseconds: 300),
    interval: const Duration(milliseconds: 50),
    client: client,
  );
  check('gives up rather than hanging', !gaveUp);

  print('\n-- telling a lookup failure from a connection failure --');
  check('Android host lookup',
      DnsCheck.isLookupFailure(
          const SocketException("Failed host lookup: 'newtest.example.com'")));
  check('macOS host lookup',
      DnsCheck.isLookupFailure(
          const SocketException('nodename nor servname provided')));
  check('Linux host lookup',
      DnsCheck.isLookupFailure(
          const SocketException('Name or service not known')));
  check('a refused connection is not a lookup failure',
      !DnsCheck.isLookupFailure(
          const SocketException('Connection refused')));
  check('a reset connection is not a lookup failure',
      !DnsCheck.isLookupFailure(
          const SocketException('Connection reset by peer')));

  client.close();
  await fake.stop();
  print('\n$passed passed, $failed failed\n');
  if (failed > 0) exitCode = 1;
}
