import 'dart:convert';

/// What a recovery backup contains — and, as importantly, what it does not.
///
/// The Cloudflare API token is deliberately absent. It can create tunnels and
/// rewrite DNS across a whole zone, and recovery does not need it: the tunnel
/// token alone is enough to serve the drive at the address it already has.
/// So a restored host comes back running, and is asked for the API token only
/// when it wants to do something that actually requires one — a new address,
/// a rename, an invite. That keeps the worst case of a stolen-and-cracked
/// backup down to one hostname rather than a domain.
class RecoveryPayload {
  const RecoveryPayload({
    required this.hostname,
    required this.tunnelToken,
    required this.driveRoot,
    required this.rootAppCreated,
    required this.username,
    required this.passwordHash,
    required this.passwordSalt,
    required this.passwordIterations,
    required this.invites,
    required this.savedAt,
  });

  static const int version = 1;

  final String hostname;
  final String tunnelToken;

  /// Where the drive's files were. A path, not the files: the files are on
  /// the phone's shared storage and survive uninstalling on their own.
  final String driveRoot;
  final bool rootAppCreated;

  /// The login, carried as the stored hash and its parameters rather than
  /// anything reversible — exactly what `meta.db` held. Restoring it means
  /// the same password keeps working without the password itself ever being
  /// part of the backup.
  final String username;
  final String passwordHash;
  final String passwordSalt;
  final int passwordIterations;

  /// Invite codes, which are otherwise the one thing a reinstall destroys
  /// with no way back: they live only on the host.
  final List<Map<String, Object?>> invites;

  final int savedAt;

  String toJson() => jsonEncode({
        'v': version,
        'hostname': hostname,
        'tunnelToken': tunnelToken,
        'driveRoot': driveRoot,
        'rootAppCreated': rootAppCreated,
        'username': username,
        'passwordHash': passwordHash,
        'passwordSalt': passwordSalt,
        'passwordIterations': passwordIterations,
        'invites': invites,
        'savedAt': savedAt,
      });

  /// Null for anything this build cannot use. A backup written by a newer
  /// version is refused rather than half-read: a partially restored drive —
  /// an address back but no login, say — is worse than an honest "set this
  /// up again".
  static RecoveryPayload? parse(String json) {
    try {
      final map = jsonDecode(json) as Map<String, Object?>;
      if (map['v'] is! int || (map['v'] as int) > version) return null;

      final hostname = map['hostname'];
      final tunnelToken = map['tunnelToken'];
      final username = map['username'];
      final passwordHash = map['passwordHash'];
      final passwordSalt = map['passwordSalt'];
      final iterations = map['passwordIterations'];
      if (hostname is! String ||
          tunnelToken is! String ||
          username is! String ||
          passwordHash is! String ||
          passwordSalt is! String ||
          iterations is! int ||
          hostname.isEmpty ||
          tunnelToken.isEmpty ||
          username.isEmpty) {
        return null;
      }

      return RecoveryPayload(
        hostname: hostname,
        tunnelToken: tunnelToken,
        driveRoot: map['driveRoot'] as String? ?? '',
        rootAppCreated: map['rootAppCreated'] as bool? ?? true,
        username: username,
        passwordHash: passwordHash,
        passwordSalt: passwordSalt,
        passwordIterations: iterations,
        invites: [
          for (final row in (map['invites'] as List<Object?>? ?? const []))
            if (row is Map) row.cast<String, Object?>(),
        ],
        savedAt: map['savedAt'] as int? ?? 0,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
