import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The crypto behind reinstall recovery.
///
/// The problem: a phone that has just been reinstalled holds nothing except
/// its own ANDROID_ID. It has to find its backup on a server it does not
/// trust, and decrypt it, using only that.
///
/// The shape of the answer is one expensive derivation and three cheap,
/// one-way splits of it:
///
///   master    = PBKDF2(ANDROID_ID, fixed salt, 600k)
///   lookupId  = HMAC(master, "lookup")   → sent, names the record
///   writeAuth = HMAC(master, "write")    → sent, proves the right to replace it
///   encKey    = HMAC(master, "enc")      → never sent, decrypts the record
///
/// The server holds lookupId and writeAuth. Neither can be walked back to
/// master, so neither yields encKey: the record is ciphertext the server
/// cannot read, which is the whole point of putting it there.
///
/// PBKDF2 is what makes lookupId safe to publish. ANDROID_ID is only 64 bits
/// — a plain SHA-256 of it could be brute-forced from a stolen record in
/// months on rented GPUs. At 600k iterations that becomes 2^64 × 600k, which
/// nobody is doing. The phone pays it once per save and once per restore.
///
/// Pure: no Flutter, no platform channels, so every line below is testable
/// off-device.
class RecoveryCrypto {
  RecoveryCrypto._();

  /// Fixed, and in the APK. It is not a secret and does not need to be: its
  /// job is domain separation, so a hash of this ANDROID_ID here cannot be
  /// compared against a hash of it computed anywhere else.
  static const String salt = 'pocketshare-recovery-v1';

  /// Matches [Auth.iterations]. The cost lands on a background isolate, once.
  static const int iterations = 600000;

  static final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );

  static final _aes = AesGcm.with256bits();

  /// The three values a device derives from its ANDROID_ID.
  static Future<RecoveryKeys> derive(String androidId) async {
    final master = await _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(androidId)),
      nonce: utf8.encode(salt),
    );
    final bytes = await master.extractBytes();

    Future<List<int>> split(String info) async =>
        (await Hmac.sha256().calculateMac(
          utf8.encode(info),
          secretKey: SecretKey(bytes),
        ))
            .bytes;

    return RecoveryKeys(
      lookupId: _b64(await split('lookup')),
      writeAuth: _b64(await split('write')),
      encKey: await split('enc'),
    );
  }

  /// AES-256-GCM. The nonce is random per save and carried in the output, so
  /// re-saving the same drive never produces the same ciphertext twice —
  /// otherwise the server could tell that nothing had changed, which is more
  /// than it needs to know.
  ///
  /// Output is `v1.<nonce>.<ciphertext+tag>`, all base64url. The version
  /// prefix is there so a later format change can be recognised rather than
  /// failing as corruption.
  static Future<String> seal(String plaintext, List<int> encKey) async {
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(encKey),
    );
    return [
      'v1',
      _b64(box.nonce),
      _b64([...box.cipherText, ...box.mac.bytes]),
    ].join('.');
  }

  /// Null when the input is not ours, is damaged, or was sealed with another
  /// key. GCM's tag makes that one check rather than three: a record edited
  /// by the server fails exactly as a record from another phone does.
  static Future<String?> open(String sealed, List<int> encKey) async {
    final parts = sealed.split('.');
    if (parts.length != 3 || parts.first != 'v1') return null;

    try {
      final nonce = _unb64(parts[1]);
      final body = _unb64(parts[2]);
      if (body.length < 16) return null;

      final cut = body.length - 16;
      final clear = await _aes.decrypt(
        SecretBox(
          body.sublist(0, cut),
          nonce: nonce,
          mac: Mac(body.sublist(cut)),
        ),
        secretKey: SecretKey(encKey),
      );
      return utf8.decode(clear);
    } catch (_) {
      // SecretBoxAuthenticationError, bad base64, bad UTF-8 — all of them
      // mean the same thing to the caller: this is not readable here.
      return null;
    }
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _unb64(String s) =>
      base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
}

class RecoveryKeys {
  const RecoveryKeys({
    required this.lookupId,
    required this.writeAuth,
    required this.encKey,
  });

  /// Names the record on the server. Safe to send.
  final String lookupId;

  /// Proves this device owns the record, so another caller who learned the
  /// lookupId cannot overwrite it. Safe to send.
  final String writeAuth;

  /// Never leaves the phone.
  final List<int> encKey;
}
