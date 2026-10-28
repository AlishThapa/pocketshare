import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../native.dart';
import 'device_id.dart';

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

  /// Stable id for this phone. Lets it re-claim its own name after a
  /// reinstall instead of being told the name is taken.
  ///
  /// Derived from ANDROID_ID, which survives uninstalling, and hashed so the
  /// raw value never leaves the phone — see [DeviceId]. Stored as well as
  /// derived, because an install that predates this change has a random id
  /// the Worker already knows — changing it under a live claim would lock
  /// the phone out of its own name. [stableId] and [rebind] are how such an
  /// install moves across deliberately.
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _kDeviceId);
    if (existing != null && existing.length >= 8) return existing;

    final id = await stableId() ?? _randomId();
    await _storage.write(key: _kDeviceId, value: id);
    return id;
  }

  /// The id this phone derives from its hardware, or null when ANDROID_ID is
  /// unavailable or known-untrustworthy. Null means reinstall recovery
  /// cannot work on this device, not that anything is broken.
  Future<String?> stableId() async {
    final raw = await Native.androidId();
    if (!DeviceId.usable(raw)) return null;
    return DeviceId.fromAndroidId(raw!);
  }

  static String _randomId() {
    final rng = Random.secure();
    return base64Url
        .encode(List<int>.generate(24, (_) => rng.nextInt(256)))
        .replaceAll('=', '');
  }

  /// Moves an existing claim from the id it was made with onto this phone's
  /// derived id, so the next uninstall does not strand it.
  ///
  /// Only ever runs for an install that claimed its name before derived ids
  /// existed. Authorised by the current id, which is the same secret that
  /// already authorises re-claiming the name, so this grants nothing that
  /// possession of the id did not already grant.
  ///
  /// Best effort and silent: it runs at startup, the phone may be offline,
  /// and nothing about the running drive depends on it.
  Future<bool> adoptStableId(String hostname) async {
    final target = await stableId();
    if (target == null) return false;

    final current = await _storage.read(key: _kDeviceId);
    if (current == null || current == target) return false;

    final name = hostname.split('.').first;
    if (name.isEmpty) return false;

    try {
      final res = await _http
          .post(
            Uri.parse('$endpoint/rebind'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'deviceId': current,
              'newDeviceId': target,
            }),
          )
          .timeout(const Duration(seconds: 20));

      // Only record the new id once the Worker has accepted it. Storing it
      // first would leave the phone holding an id the Worker does not know,
      // which is the exact lockout this is meant to prevent.
      if (res.statusCode != 200) return false;
      await _storage.write(key: _kDeviceId, value: target);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Checks an invite code and learns which domain it is for.
  ///
  /// The guest has no other way to know the domain: it belongs to whoever
  /// invited them, and the app is not told it until a code proves they were
  /// invited. This is why it runs before the name field exists — a name is
  /// meaningless until there is a domain to hang it on.
  Future<InviteCheck> checkInvite(String code) async {
    final uri = Uri.parse('$endpoint/invite')
        .replace(queryParameters: {'code': code});
    try {
      final res = await _http.get(uri).timeout(const Duration(seconds: 15));
      final body = _decode(res);
      return InviteCheck(
        ok: body['ok'] == true,
        domain: body['domain'] as String?,
        remaining: (body['remaining'] as num?)?.toInt(),
      );
    } on ProvisionError catch (e) {
      return InviteCheck(ok: false, reason: e.message);
    } catch (e) {
      return InviteCheck(
        ok: false,
        reason: 'could not reach ${uri.host} (${e.runtimeType})',
      );
    }
  }

  Future<NameCheck> checkAvailable(
    String name, {
    required String inviteCode,
  }) async {
    final uri = Uri.parse('$endpoint/available')
        .replace(queryParameters: {'name': name, 'code': inviteCode});
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

/// What the Worker says about an invite code. [domain] is set only when the
/// code is good, which is also what unlocks the rest of the screen.
class InviteCheck {
  const InviteCheck({
    required this.ok,
    this.domain,
    this.remaining,
    this.reason,
  });

  final bool ok;
  final String? domain;
  final int? remaining;
  final String? reason;
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
