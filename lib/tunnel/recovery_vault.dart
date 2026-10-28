import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../native.dart';
import 'device_id.dart';
import 'recovery_crypto.dart';
import 'recovery_payload.dart';

/// Stores an encrypted backup of this drive's identity on the Worker, and
/// fetches it back after a reinstall.
///
/// Everything that makes the backup findable and readable is derived from
/// ANDROID_ID, which survives uninstalling and never leaves the phone. So
/// recovery needs nothing from the user: no passphrase, no file to keep, no
/// account anywhere.
///
/// The limit of that, stated plainly because the UI has to say it too: it
/// works on *this* phone. A factory reset or a new handset changes
/// ANDROID_ID, and the backup becomes both unfindable and unreadable. That is
/// the price of not asking the user to hold a secret, and it is why this is a
/// convenience rather than a backup strategy.
class RecoveryVault {
  RecoveryVault({required this.endpoint, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String endpoint;
  final http.Client _http;

  static const _timeout = Duration(seconds: 20);

  /// Whether this device can do recovery at all. False where ANDROID_ID is
  /// missing or is the known-shared value — in which case the feature is
  /// hidden rather than offered and quietly broken.
  Future<bool> available() async => DeviceId.usable(await Native.androidId());

  /// Writes a backup. Returns false on any failure, including being offline:
  /// this is called after things that already succeeded, and a failed backup
  /// must never turn into a failed save.
  Future<bool> save(RecoveryPayload payload) async {
    final keys = await _keys();
    if (keys == null) return false;

    try {
      final blob = await RecoveryCrypto.seal(payload.toJson(), keys.encKey);
      final res = await _http
          .put(
            Uri.parse('$endpoint/recovery'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': keys.lookupId,
              'writeAuth': keys.writeAuth,
              'blob': blob,
            }),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetches and decrypts this phone's backup, or null when there is none,
  /// the phone is offline, or the record cannot be read with this device's
  /// key — which is also what a tampered record looks like.
  Future<RecoveryPayload?> restore() async {
    final keys = await _keys();
    if (keys == null) return null;

    try {
      final res = await _http
          .get(Uri.parse('$endpoint/recovery?id=${keys.lookupId}'))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body) as Map<String, Object?>;
      final blob = body['blob'];
      if (blob is! String) return null;

      final clear = await RecoveryCrypto.open(blob, keys.encKey);
      if (clear == null) return null;

      return RecoveryPayload.parse(clear);
    } catch (_) {
      return null;
    }
  }

  /// Removes the backup. Used when the user turns the feature off, so "off"
  /// means the copy is gone rather than merely not being updated.
  Future<bool> forget() async {
    final keys = await _keys();
    if (keys == null) return false;

    try {
      final res = await _http
          .delete(
            Uri.parse('$endpoint/recovery'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': keys.lookupId,
              'writeAuth': keys.writeAuth,
            }),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 600k PBKDF2 rounds, moved off the UI isolate so the derivation cannot
  /// drop frames on the screen that triggered it.
  Future<RecoveryKeys?> _keys() async {
    final raw = await Native.androidId();
    if (!DeviceId.usable(raw)) return null;
    return Isolate.run(() => RecoveryCrypto.derive(raw!));
  }
}
