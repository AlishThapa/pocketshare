import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Pure helpers for showing and comparing a Cloudflare API token without
/// revealing it. No Flutter imports, so these are testable on their own.
///
/// A token cannot be hashed for storage: the app has to send the original
/// bytes to Cloudflare on every provision, so it must be recoverable. Hashing
/// is only useful here for the two jobs below — proving two tokens are the
/// same, and labelling one on screen.
class TokenFormat {
  TokenFormat._();

  /// Dots shown in place of the hidden middle. Fixed, so the display does
  /// not leak the token's length.
  static const _dots = '••••••••••';

  /// `cfut_••••••••••9a2f` — enough to recognise which token this is,
  /// not enough to use it. Short or malformed input is masked entirely.
  static String mask(String token) {
    final t = token.trim();
    if (t.length < 12) return _dots;

    final underscore = t.indexOf('_');
    final prefix = (underscore > 0 && underscore <= 8)
        ? t.substring(0, underscore + 1)
        : '';
    return '$prefix$_dots${t.substring(t.length - 4)}';
  }

  /// Stable short digest, for telling "same token as before" from "a new one"
  /// without storing or displaying the token itself. Truncated because it is
  /// only ever compared against another fingerprint of the same kind.
  static String fingerprint(String token) =>
      sha256.convert(utf8.encode(token.trim())).toString().substring(0, 12);

  /// Whether two tokens are the same, compared by digest so neither has to
  /// be held in a variable the UI might render.
  static bool sameToken(String a, String b) =>
      fingerprint(a) == fingerprint(b);

  /// Cloudflare API tokens are 40+ URL-safe characters, sometimes with a
  /// `cfut_` style prefix. This rejects obvious paste errors (a tunnel token,
  /// a truncated copy) before a network call, not as a security check.
  static bool looksLikeApiToken(String token) {
    final t = token.trim();
    if (t.length < 40) return false;
    // A tunnel token is base64 JSON and starts with `eyJ` — a common mix-up,
    // and worth catching here because it fails much later otherwise.
    if (t.startsWith('eyJ')) return false;
    return RegExp(r'^[A-Za-z0-9_\-\.]+$').hasMatch(t);
  }

  /// True for the `eyJ…` credential that runs one existing tunnel. It cannot
  /// create tunnels or DNS records, so it can never mint a subdomain.
  static bool looksLikeTunnelToken(String token) =>
      token.trim().startsWith('eyJ');
}
