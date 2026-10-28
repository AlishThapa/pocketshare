import 'dart:convert';

import 'package:http/http.dart' as http;

/// A failure reported by Cloudflare, carrying enough to tell the user what to
/// fix rather than just that something broke.
class CloudflareError implements Exception {
  CloudflareError(this.message, {this.status, this.code});

  final String message;
  final int? status;
  final int? code;

  /// The token is not a valid Cloudflare API token at all.
  bool get isUnauthorized => status == 401 || code == 1000;

  /// The token is real but was not given the scopes this needs. Worth telling
  /// apart from [isUnauthorized]: the fix is editing the token, not replacing
  /// it, and users routinely create one with no permissions ticked.
  bool get isForbidden => status == 403 || code == 9109;

  /// A tunnel of that name already exists on the account. Reachable when a
  /// name is re-claimed after its drive was wiped but its tunnel was left
  /// behind, so the message has to point at the leftover.
  bool get isDuplicateTunnel =>
      code == 1013 || message.toLowerCase().contains('already exists');

  @override
  String toString() => message;
}

class CfZone {
  const CfZone({required this.id, required this.name, required this.accountId});
  final String id;
  final String name;

  /// The account that owns this zone. Taken from the zone itself because
  /// listing accounts needs a permission of its own: a token scoped to
  /// Cloudflare Tunnel can create tunnels in an account without being
  /// allowed to enumerate accounts, so GET /accounts comes back empty for a
  /// perfectly good token. Empty only if Cloudflare omits the field.
  final String accountId;
}

class CfAccount {
  const CfAccount({required this.id, required this.name});
  final String id;
  final String name;
}

/// A tunnel that already exists on the account, as the list endpoint
/// describes it. Distinct from [CfTunnel] because a listed tunnel carries no
/// token — that has to be fetched — but does say whether anything is
/// currently connected to it.
class CfExistingTunnel {
  const CfExistingTunnel({
    required this.id,
    required this.name,
    required this.active,
  });

  final String id;
  final String name;

  /// True when cloudflared is connected to this tunnel right now, so a drive
  /// is serving through it. Adopting an active tunnel would hand its token to
  /// a second device, and Cloudflare reads two connections as high
  /// availability: both phones would serve, splitting requests between two
  /// different sets of files. So this is the difference between a leftover
  /// worth reusing and a live drive worth refusing.
  final bool active;
}

class CfTunnel {
  const CfTunnel({required this.id, required this.token});
  final String id;

  /// The credential that runs this one tunnel. Distinct from the API token:
  /// it cannot create anything, which is why it is the only secret handed to
  /// a guest device.
  final String token;
}

/// Thin client over the Cloudflare v4 API.
///
/// This runs on the phone that owns the domain, holding that phone's own API
/// token. Nothing here is reachable by a guest device: a guest asks its host
/// to provision, and the host makes these calls.
class CloudflareApi {
  CloudflareApi({
    required this.token,
    http.Client? httpClient,
    Uri? baseUrl,
  })  : _http = httpClient ?? http.Client(),
        _base = baseUrl ?? Uri.parse('https://api.cloudflare.com/client/v4');

  final String token;
  final http.Client _http;
  final Uri _base;

  /// Where a tunnel points on the phone. The drive binds loopback only, so
  /// the tunnel is the single way in.
  static const serviceUrl = 'http://127.0.0.1:8080';

  static const _timeout = Duration(seconds: 30);

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String> query = const {},
  }) async {
    final uri = Uri.parse('$_base$path').replace(
      queryParameters: query.isEmpty ? null : query,
    );
    final request = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);

    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(request))
          .timeout(_timeout);
    } catch (e) {
      throw CloudflareError('could not reach Cloudflare ($e)');
    }

    Map<String, Object?> payload;
    try {
      payload = jsonDecode(res.body) as Map<String, Object?>;
    } catch (_) {
      throw CloudflareError(
        'Cloudflare returned an unreadable response (HTTP ${res.statusCode})',
        status: res.statusCode,
      );
    }

    final errors = (payload['errors'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .toList();

    if (res.statusCode >= 400 || payload['success'] == false) {
      final detail = errors
          .map((e) => e['message'] as String? ?? '')
          .where((m) => m.isNotEmpty)
          .join('; ');
      throw CloudflareError(
        detail.isEmpty ? 'Cloudflare rejected the request' : detail,
        status: res.statusCode,
        code: errors.isEmpty ? null : errors.first['code'] as int?,
      );
    }

    return payload['result'];
  }

  Future<List<Map<String, Object?>>> _list(
    String path, {
    Map<String, String> query = const {},
  }) async {
    final result = await _send('GET', path, query: query);
    return (result as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .toList();
  }

  Future<Map<String, Object?>> _object(
    String method,
    String path, {
    Object? body,
  }) async {
    final result = await _send(method, path, body: body);
    return result as Map<String, Object?>? ?? const {};
  }

  /// Confirms the token is live. Does not prove it has the right scopes —
  /// only [zones] and a real tunnel call can show that — so the connect
  /// screen calls this and then [zones].
  Future<void> verify() => _send('GET', '/user/tokens/verify');

  /// Domains this token can reach. The connect screen offers these as the
  /// picker, which makes a wrong-scope token fail here rather than three
  /// screens later, when a name has already been chosen.
  Future<List<CfZone>> zones() async {
    final rows = await _list('/zones', query: {'per_page': '50'});
    return [
      for (final r in rows)
        if (r['id'] is String && r['name'] is String)
          CfZone(
            id: r['id'] as String,
            name: r['name'] as String,
            accountId:
                (r['account'] as Map<String, Object?>?)?['id'] as String? ?? '',
          ),
    ];
  }

  Future<List<CfAccount>> accounts() async {
    final rows = await _list('/accounts', query: {'per_page': '50'});
    return [
      for (final r in rows)
        if (r['id'] is String)
          CfAccount(
            id: r['id'] as String,
            name: r['name'] as String? ?? 'account',
          ),
    ];
  }

  /// Creates a remotely-managed tunnel. `config_src: cloudflare` keeps ingress
  /// in the API rather than a config file, so the phone never writes one.
  Future<CfTunnel> createTunnel({
    required String accountId,
    required String name,
  }) async {
    final result = await _object(
      'POST',
      '/accounts/$accountId/cfd_tunnel',
      body: {'name': name, 'config_src': 'cloudflare'},
    );
    final id = result['id'] as String?;
    if (id == null) {
      throw CloudflareError('Cloudflare created a tunnel with no id');
    }
    return CfTunnel(id: id, token: result['token'] as String? ?? '');
  }

  Future<void> configureIngress({
    required String accountId,
    required String tunnelId,
    required String hostname,
    String service = serviceUrl,
  }) =>
      _send(
        'PUT',
        '/accounts/$accountId/cfd_tunnel/$tunnelId/configurations',
        body: {
          'config': {
            'ingress': [
              {'hostname': hostname, 'service': service},
              {'service': 'http_status:404'},
            ],
          },
        },
      );

  Future<String> tunnelToken({
    required String accountId,
    required String tunnelId,
  }) async {
    final result =
        await _send('GET', '/accounts/$accountId/cfd_tunnel/$tunnelId/token');
    if (result is! String || result.isEmpty) {
      throw CloudflareError('Cloudflare returned no tunnel token');
    }
    return result;
  }

  Future<void> deleteTunnel({
    required String accountId,
    required String tunnelId,
  }) =>
      _send('DELETE', '/accounts/$accountId/cfd_tunnel/$tunnelId');

  Future<List<Map<String, Object?>>> listTunnels({
    required String accountId,
    String? name,
  }) =>
      _list('/accounts/$accountId/cfd_tunnel', query: {
        'is_deleted': 'false',
        if (name != null) 'name': name,
      });

  /// The tunnel with exactly this name, or null when the account has none.
  ///
  /// Used after a duplicate-name refusal, to tell a leftover tunnel from a
  /// live one. The name filter is server-side, but it is matched again here:
  /// Cloudflare treats `name` as a prefix-ish search on some plans, and
  /// adopting `ps-alishdrive-old` when asked for `ps-alishdrive` would point
  /// the wrong tunnel at the drive.
  Future<CfExistingTunnel?> findTunnel({
    required String accountId,
    required String name,
  }) async {
    final rows = await listTunnels(accountId: accountId, name: name);
    for (final row in rows) {
      if (row['id'] is! String || row['name'] != name) continue;
      return CfExistingTunnel(
        id: row['id'] as String,
        name: name,
        active: _hasLiveConnection(row),
      );
    }
    return null;
  }

  /// Whether a listed tunnel has cloudflared attached to it right now.
  ///
  /// Read from whichever fields Cloudflare actually sent, erring towards
  /// "yes": a false positive only costs the user a rename, while a false
  /// negative quietly puts two phones behind one hostname. `down` and
  /// `inactive` both mean nothing is connected — `down` has been connected
  /// before, which is exactly what a leftover from a wiped install looks
  /// like.
  static bool _hasLiveConnection(Map<String, Object?> row) {
    final conns = row['connections'];
    if (conns is List && conns.isNotEmpty) return true;

    final status = (row['status'] as String?)?.toLowerCase();
    if (status == 'healthy' || status == 'degraded') return true;

    // Older payloads carry no status, only a pair of timestamps.
    if (status == null &&
        row['conns_active_at'] is String &&
        row['conns_inactive_at'] == null) {
      return true;
    }
    return false;
  }

  /// Points `<name>.<zone>` at the tunnel, updating any record already there.
  ///
  /// Updating rather than failing is what lets a name be re-claimed after a
  /// reinstall: the old record is repointed at the new tunnel instead of
  /// blocking the claim.
  Future<void> upsertCname({
    required String zoneId,
    required String fqdn,
    required String content,
  }) async {
    final existing = await _list(
      '/zones/$zoneId/dns_records',
      query: {'type': 'CNAME', 'name': fqdn},
    );

    final record = {
      'type': 'CNAME',
      'name': fqdn,
      'content': content,
      'proxied': true,
      'comment': 'pocketshare',
    };

    if (existing.isNotEmpty && existing.first['id'] is String) {
      await _send(
        'PUT',
        '/zones/$zoneId/dns_records/${existing.first['id']}',
        body: record,
      );
      return;
    }
    await _send('POST', '/zones/$zoneId/dns_records', body: record);
  }

  Future<void> deleteCname({
    required String zoneId,
    required String fqdn,
  }) async {
    final existing = await _list(
      '/zones/$zoneId/dns_records',
      query: {'type': 'CNAME', 'name': fqdn},
    );
    for (final r in existing) {
      if (r['id'] is String) {
        await _send('DELETE', '/zones/$zoneId/dns_records/${r['id']}');
      }
    }
  }

  void close() => _http.close();
}
