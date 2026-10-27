import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Client for the provisioning Worker.
///
/// The app never sees a Cloudflare credential: it sends an invite code and a
/// desired name, and gets back a hostname plus a token scoped to one tunnel.
class Provisioner {
  Provisioner({
    required this.endpoint,
    http.Client? httpClient,
    FlutterSecureStorage? storage,
  })  : _http = httpClient ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  /// Base URL of the deployed Worker, e.g.
  /// `https://pocketshare-provision.<subdomain>.workers.dev`
  final String endpoint;

  final http.Client _http;
  final FlutterSecureStorage _storage;

  static const _kDeviceId = 'device_id';
  static const _kTunnelToken = 'tunnel_token';
  static const _kHostname = 'hostname';

  /// Stable per-install id. Lets the same phone re-claim its own name after a
  /// reinstall instead of being told the name is taken.
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _kDeviceId);
    if (existing != null && existing.length >= 8) return existing;

    final rng = Random.secure();
    final id = base64Url
        .encode(List<int>.generate(24, (_) => rng.nextInt(256)))
        .replaceAll('=', '');
    await _storage.write(key: _kDeviceId, value: id);
    return id;
  }

  Future<NameCheck> checkAvailable(String name) async {
    final uri = Uri.parse('$endpoint/available')
        .replace(queryParameters: {'name': name});
    try {
      final res = await _http.get(uri).timeout(const Duration(seconds: 15));
      final body = _decode(res);
      return NameCheck(
        available: body['available'] == true,
        reason: body['reason'] as String?,
        hostname: body['hostname'] as String?,
      );
    } on ProvisionError catch (e) {
      return NameCheck(available: false, reason: e.message);
    } catch (e) {
      // Name the host: the two ways this fails are the phone being offline and
      // the build pointing at a Worker URL that does not exist, and a bare
      // "could not reach" cannot tell them apart.
      return NameCheck(
        available: false,
        reason: 'could not reach ${uri.host} (${e.runtimeType})',
      );
    }
  }

  /// Claims [name] and persists the resulting credentials.
  Future<Claim> claim({required String name, required String inviteCode}) async {
    final res = await _http
        .post(
          Uri.parse('$endpoint/claim'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'name': name,
            'inviteCode': inviteCode,
            'deviceId': await deviceId(),
          }),
        )
        .timeout(const Duration(seconds: 45));

    final body = _decode(res);
    final hostname = body['hostname'] as String?;
    final token = body['tunnelToken'] as String?;
    if (hostname == null || token == null) {
      throw ProvisionError('the signup service returned an incomplete response');
    }

    await _storage.write(key: _kHostname, value: hostname);
    await _storage.write(key: _kTunnelToken, value: token);

    return Claim(
      hostname: hostname,
      tunnelToken: token,
      reused: body['reused'] == true,
    );
  }

  /// Records a claim this device made itself, through its own Cloudflare
  /// token, so the host path lands in the same storage the rest of the app
  /// already reads.
  Future<Claim> adopt({
    required String hostname,
    required String tunnelToken,
  }) async {
    await _storage.write(key: _kHostname, value: hostname);
    await _storage.write(key: _kTunnelToken, value: tunnelToken);
    return Claim(hostname: hostname, tunnelToken: tunnelToken, reused: false);
  }

  Future<Claim?> saved() async {
    final hostname = await _storage.read(key: _kHostname);
    final token = await _storage.read(key: _kTunnelToken);
    if (hostname == null || token == null) return null;
    return Claim(hostname: hostname, tunnelToken: token, reused: true);
  }

  Future<void> forget() async {
    await _storage.delete(key: _kHostname);
    await _storage.delete(key: _kTunnelToken);
  }

  /// Unwraps the Worker's JSON, turning its error field into an exception that
  /// carries a message fit to show the user.
  static Map<String, Object?> _decode(http.Response res) {
    Map<String, Object?> body;
    try {
      body = (jsonDecode(res.body) as Map).cast<String, Object?>();
    } on FormatException {
      throw ProvisionError('the signup service is misbehaving (HTTP ${res.statusCode})');
    }

    if (res.statusCode >= 400) {
      throw ProvisionError(
        body['error'] as String? ?? 'signup failed (HTTP ${res.statusCode})',
      );
    }
    return body;
  }
}

class NameCheck {
  const NameCheck({required this.available, this.reason, this.hostname});
  final bool available;
  final String? reason;
  final String? hostname;
}

class Claim {
  const Claim({
    required this.hostname,
    required this.tunnelToken,
    required this.reused,
  });
  final String hostname;
  final String tunnelToken;
  final bool reused;
}

class ProvisionError implements Exception {
  ProvisionError(this.message);
  final String message;
  @override
  String toString() => message;
}
