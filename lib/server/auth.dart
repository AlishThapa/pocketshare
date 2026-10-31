import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// Password hashing and browser sessions.
///
/// Passwords go through PBKDF2-HMAC-SHA256. Session tokens are random 256-bit
/// values; only their SHA-256 is stored, so a stolen database cannot be
/// replayed as a login.
class Auth {
  Auth(this._store);

  final DriveStore _store;
  static final _rng = Random.secure();

  /// OWASP's 2023 floor for PBKDF2-HMAC-SHA256. Costs ~250ms on a mid phone,
  /// which is only paid on login, not per request.
  static const int iterations = 600000;

  static const int _saltBytes = 16;
  static const int _keyBytes = 32;
  static const int _tokenBytes = 32;

  static const String sessionCookie = 'ps_session';

  bool get hasAccount => _store.hasAccount;

  Future<void> createAccount({
    required String username,
    required String password,
  }) async {
    final salt = _randomBytes(_saltBytes);
    final hash = await _deriveOffThread(
      password: utf8.encode(password),
      salt: salt,
      iterations: iterations,
      keyLength: _keyBytes,
    );

    _store.createAccount(
      username: username,
      passwordHash: base64.encode(hash),
      salt: base64.encode(salt),
      iterations: iterations,
    );
  }

  /// Returns a fresh session token on success, null on bad credentials.
  Future<String?> login({
    required String username,
    required String password,
    String? userAgent,
  }) async {
    final account = _store.account;
    if (account == null) return null;

    // Compare both fields in constant time so neither a wrong username nor a
    // wrong password is distinguishable by how long the request took.
    final userOk = _constantTimeEquals(
      utf8.encode(username),
      utf8.encode(account.username),
    );

    final candidate = await _deriveOffThread(
      password: utf8.encode(password),
      salt: base64.decode(account.salt),
      iterations: account.iterations,
      keyLength: _keyBytes,
    );
    final passOk = _constantTimeEquals(
      candidate,
      base64.decode(account.passwordHash),
    );

    if (!userOk || !passOk) return null;

    final token = base64Url.encode(_randomBytes(_tokenBytes));
    _store.putSession(_hashToken(token), userAgent);
    return token;
  }

  /// Derives password material for something that is not the account login —
  /// today, a share link's optional password.
  ///
  /// Same KDF, same cost, same off-thread isolate. A share password guards a
  /// link that is already public knowledge to whoever holds it, so it tends
  /// to be short and memorable; that is exactly the case where the iteration
  /// count has to carry the weight.
  Future<DerivedPassword> derivePassword(String password) async {
    final salt = _randomBytes(_saltBytes);
    final hash = await _deriveOffThread(
      password: utf8.encode(password),
      salt: salt,
      iterations: iterations,
      keyLength: _keyBytes,
    );
    return DerivedPassword(
      hash: base64.encode(hash),
      salt: base64.encode(salt),
      iterations: iterations,
    );
  }

  /// Constant-time check of a password against stored material.
  Future<bool> matchesPassword({
    required String password,
    required String hash,
    required String salt,
    required int storedIterations,
  }) async {
    final candidate = await _deriveOffThread(
      password: utf8.encode(password),
      salt: base64.decode(salt),
      iterations: storedIterations,
      keyLength: _keyBytes,
    );
    return _constantTimeEquals(candidate, base64.decode(hash));
  }

  bool validate(String token) => _store.touchSession(_hashToken(token));

  void logout(String token) => _store.dropSession(_hashToken(token));

  String? usernameOf(String token) =>
      validate(token) ? _store.account?.username : null;

  /// Runs the KDF on a worker isolate so a login cannot stall in-flight
  /// uploads on the server isolate.
  static Future<Uint8List> _deriveOffThread({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int keyLength,
  }) {
    final pw = List<int>.from(password);
    final st = List<int>.from(salt);
    return Isolate.run(() => _pbkdf2(
          password: pw,
          salt: st,
          iterations: iterations,
          keyLength: keyLength,
        ));
  }

  static String _hashToken(String token) =>
      base64.encode(sha256.convert(utf8.encode(token)).bytes);

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    // Fold the length difference in rather than returning early, so the
    // comparison leaks neither length nor position of the first mismatch.
    var diff = a.length ^ b.length;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _pbkdf2({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int keyLength,
  }) {
    final hmac = Hmac(sha256, password);
    const blockLength = 32;
    final blocks = (keyLength + blockLength - 1) ~/ blockLength;
    final out = Uint8List(blocks * blockLength);

    for (var block = 1; block <= blocks; block++) {
      // U1 = PRF(password, salt || INT_32_BE(block))
      final first = hmac.convert([...salt, ..._intToBytes(block)]).bytes;
      final acc = Uint8List.fromList(first);
      var prev = first;

      for (var i = 1; i < iterations; i++) {
        prev = hmac.convert(prev).bytes;
        for (var j = 0; j < blockLength; j++) {
          acc[j] ^= prev[j];
        }
      }

      out.setRange((block - 1) * blockLength, block * blockLength, acc);
    }

    return Uint8List.sublistView(out, 0, keyLength);
  }

  static List<int> _intToBytes(int value) => [
        (value >> 24) & 0xff,
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff,
      ];
}

/// Password material ready to store. Carries its own iteration count so a
/// future increase does not invalidate what is already saved.
class DerivedPassword {
  const DerivedPassword({
    required this.hash,
    required this.salt,
    required this.iterations,
  });

  final String hash;
  final String salt;
  final int iterations;
}
