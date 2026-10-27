import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_format.dart';

/// Everything secret the app holds, in one place.
///
/// Values go to platform secure storage, which on Android encrypts them with a
/// key held in the Keystore — hardware-backed where the phone has a TEE. The
/// key never leaves that hardware and no other app can ask for it.
///
/// What this does *not* protect against: a rooted phone, or malware running as
/// this app. Keystore stops another app reading the token and stops it being
/// recovered from a copied data directory; it does not stop code running with
/// this app's own identity. That is the honest limit, and it is why the token
/// should be scoped to one zone rather than the whole account.
class Secrets {
  Secrets._();

  // One shared handle. The options must stay identical everywhere: changing
  // them changes the backing store, and anything written under the old
  // options becomes unreadable — which would strand a drive that is already
  // running by losing its saved claim.
  static const _storage = FlutterSecureStorage();

  static const _kApiToken = 'cf_api_token';
  static const _kApiTokenFingerprint = 'cf_api_token_fp';
  static const _kZone = 'cf_zone';
  static const _kZoneId = 'cf_zone_id';
  static const _kAccountId = 'cf_account_id';

  /// Stores the Cloudflare API token, with the zone it was chosen for.
  ///
  /// The token is kept whole, not hashed: the app has to send these exact
  /// bytes to Cloudflare on every provision, so a one-way digest would
  /// destroy it. The fingerprint stored alongside is for telling one token
  /// from another on screen without reading the token back.
  static Future<void> saveCloudflare({
    required String apiToken,
    required String zone,
    required String zoneId,
    required String accountId,
  }) async {
    final token = apiToken.trim();
    await _storage.write(key: _kApiToken, value: token);
    await _storage.write(
      key: _kApiTokenFingerprint,
      value: TokenFormat.fingerprint(token),
    );
    await _storage.write(key: _kZone, value: zone);
    await _storage.write(key: _kZoneId, value: zoneId);
    await _storage.write(key: _kAccountId, value: accountId);
  }

  /// The token itself. Call this only to make a Cloudflare request — never to
  /// show it, log it, or put it in an error message.
  static Future<String?> apiToken() => _storage.read(key: _kApiToken);

  static Future<String?> zone() => _storage.read(key: _kZone);
  static Future<String?> zoneId() => _storage.read(key: _kZoneId);
  static Future<String?> accountId() => _storage.read(key: _kAccountId);

  /// Short digest of the stored token, safe to display. Null when no token is
  /// stored, which is also how the UI knows this device is not a host.
  static Future<String?> apiTokenFingerprint() =>
      _storage.read(key: _kApiTokenFingerprint);

  static Future<bool> get isHost async => await apiToken() != null;

  /// Forgets the Cloudflare connection. This does not revoke the token at
  /// Cloudflare — only the dashboard can do that — so the UI has to say so.
  static Future<void> disconnectCloudflare() async {
    await _storage.delete(key: _kApiToken);
    await _storage.delete(key: _kApiTokenFingerprint);
    await _storage.delete(key: _kZone);
    await _storage.delete(key: _kZoneId);
    await _storage.delete(key: _kAccountId);
  }
}
