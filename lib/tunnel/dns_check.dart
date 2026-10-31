import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Asks public DNS whether a hostname exists, without asking this device's
/// own resolver.
///
/// That distinction is the whole point. A plain lookup for a name that does
/// not exist yet is not free: the resolver caches the "no such name" answer
/// for the zone's SOA minimum — half an hour on a Cloudflare zone — and keeps
/// handing it back long after the record is live everywhere else. So a phone
/// that checks a brand-new address a few seconds too early teaches itself
/// that its own drive is unreachable, and nothing it does afterwards helps.
///
/// These queries go over DNS-over-HTTPS instead, which is an ordinary HTTPS
/// request to a name that already resolves. The local resolver is never asked
/// about the new name, so it has nothing to get wrong.
class DnsCheck {
  DnsCheck._();

  static final Uri _endpoint = Uri.parse('https://cloudflare-dns.com/dns-query');

  static const Duration _timeout = Duration(seconds: 10);

  /// True when public DNS has an address record for [hostname], false when it
  /// definitely does not, and null when the question could not be asked —
  /// offline, or the resolver itself unreachable. Null is deliberately not
  /// folded into false: "I could not find out" and "it is not there" lead to
  /// different advice.
  static Future<bool?> published(String hostname, {http.Client? client}) async {
    final http = client ?? _client();
    try {
      final res = await http
          .get(
            _endpoint.replace(
              queryParameters: {'name': hostname, 'type': 'A'},
            ),
            headers: {'Accept': 'application/dns-json'},
          )
          .timeout(_timeout);

      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body) as Map<String, Object?>;
      // 0 is NOERROR, 3 is NXDOMAIN. Anything else is the resolver having a
      // problem of its own, which is not an answer about this name.
      final status = (body['Status'] as num?)?.toInt();
      if (status == 3) return false;
      if (status != 0) return null;

      final answers = (body['Answer'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>();
      // NOERROR with no A record is the same as not published, for our
      // purposes: nothing will answer at it.
      return answers.any((a) => (a['data'] as String?)?.isNotEmpty ?? false);
    } catch (_) {
      return null;
    } finally {
      if (client == null) http.close();
    }
  }

  /// Waits for [hostname] to appear in public DNS.
  ///
  /// Returns true as soon as it does, false if the budget runs out or the
  /// question cannot be asked. A false is not a reason to stop: the caller
  /// carries on and lets the ordinary health check report what it finds. The
  /// point of waiting was never certainty, only to avoid asking the local
  /// resolver too early.
  static Future<bool> waitUntilPublished(
    String hostname, {
    Duration budget = const Duration(seconds: 45),
    Duration interval = const Duration(seconds: 3),
    http.Client? client,
  }) async {
    final http = client ?? _client();
    final deadline = DateTime.now().add(budget);
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (await published(hostname, client: http) == true) return true;
        await Future<void>.delayed(interval);
      }
      return false;
    } finally {
      if (client == null) http.close();
    }
  }

  /// Whether this device's own resolver can see [hostname] right now.
  ///
  /// Only for explaining a failure that has already happened. Never call it
  /// to find out whether a new name is ready — that is the query that does
  /// the damage.
  static Future<bool> resolvesLocally(String hostname) async {
    try {
      final found = await InternetAddress.lookup(hostname).timeout(_timeout);
      return found.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether a socket failure was the name failing to resolve, as opposed to
  /// the connection failing once it had.
  static bool isLookupFailure(SocketException e) {
    final message = e.message.toLowerCase();
    return message.contains('failed host lookup') ||
        message.contains('nodename nor servname') ||
        message.contains('name or service not known') ||
        message.contains('no address associated');
  }

  static http.Client _client() => http.Client();
}
