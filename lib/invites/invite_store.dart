import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

class Invite {
  const Invite({
    required this.code,
    required this.label,
    required this.uses,
    required this.maxUses,
    required this.revoked,
    required this.createdAt,
  });

  final String code;
  final String label;
  final int uses;
  final int maxUses;
  final bool revoked;
  final DateTime createdAt;

  int get remaining => (maxUses - uses).clamp(0, maxUses);
  bool get exhausted => uses >= maxUses;
  bool get usable => !revoked && !exhausted;

  /// What the host hands over. The host address travels with the code because
  /// the guest's phone has no other way to find out where to send its claim —
  /// there is no central service left to ask.
  String shareString(String hostname) => '$code@$hostname';
}

/// Invite codes, kept on the host's own phone.
///
/// The host is the only device that can honour one: redeeming a code means
/// creating a tunnel and a DNS record, which needs the Cloudflare token that
/// never leaves this device. A guest holds no token, so it can neither issue
/// nor validate codes — which is why the card is host-only.
class InviteStore {
  InviteStore(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS invite (
        code       TEXT    PRIMARY KEY,
        label      TEXT    NOT NULL DEFAULT '',
        uses       INTEGER NOT NULL DEFAULT 0,
        max_uses   INTEGER NOT NULL,
        revoked    INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  final Database _db;

  /// Ambiguous characters are left out, because these get read aloud and
  /// copied off screens: no O/0, no I/1/L, and no U, which reads as V in
  /// some fonts.
  static const alphabet = 'ABCDEFGHJKMNPQRSTWXYZ23456789';

  /// Six characters over 29 letters is about 594 million codes. The host is
  /// the only thing that can answer a guess, it refuses an unknown code
  /// outright, and every code carries its own use limit — so more length buys
  /// nothing and costs typing.
  static const codeLength = 6;

  static final _rng = Random.secure();

  static String generateCode() => List.generate(
        codeLength,
        (_) => alphabet[_rng.nextInt(alphabet.length)],
      ).join();

  /// Normalises what a person typed: case, stray spaces or hyphens, and the
  /// hostname if they pasted the whole share string.
  static String normalize(String raw) {
    final trimmed = raw.trim();
    final at = trimmed.indexOf('@');
    final code = at >= 0 ? trimmed.substring(0, at) : trimmed;
    return code.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  }

  /// The host part of a pasted share string, or null if there was none.
  static String? hostFrom(String raw) {
    final at = raw.indexOf('@');
    if (at < 0) return null;
    final host = raw.substring(at + 1).trim().toLowerCase();
    return host.isEmpty ? null : host;
  }

  Invite create({String label = '', int maxUses = 1}) {
    final limit = maxUses < 1 ? 1 : maxUses;

    // Retry on the astronomically unlikely collision rather than letting the
    // primary key throw in the user's face.
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = generateCode();
      if (_db.select('SELECT 1 FROM invite WHERE code = ?', [code]).isNotEmpty) {
        continue;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      _db.execute(
        'INSERT INTO invite (code, label, uses, max_uses, revoked, created_at) '
        'VALUES (?, ?, 0, ?, 0, ?)',
        [code, label, limit, now],
      );
      return Invite(
        code: code,
        label: label,
        uses: 0,
        maxUses: limit,
        revoked: false,
        createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      );
    }
    throw StateError('could not generate an unused invite code');
  }

  List<Invite> list() => _db
      .select('SELECT * FROM invite ORDER BY created_at DESC')
      .map(_fromRow)
      .toList();

  Invite? find(String rawCode) {
    final rows =
        _db.select('SELECT * FROM invite WHERE code = ?', [normalize(rawCode)]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Null when the code may be redeemed, otherwise why not — phrased for the
  /// guest, who can see none of this.
  String? problem(String rawCode) {
    final invite = find(rawCode);
    if (invite == null) return 'that invite code is not valid';
    if (invite.revoked) return 'that invite code was cancelled';
    if (invite.exhausted) return 'that invite code has been used up';
    return null;
  }

  /// Spends one use. Called only after a claim has actually succeeded: a
  /// failed provision must not burn the invite, a mistake this project has
  /// already made once.
  void consume(String rawCode) => _db.execute(
        'UPDATE invite SET uses = uses + 1 WHERE code = ?',
        [normalize(rawCode)],
      );

  void revoke(String rawCode) => _db.execute(
        'UPDATE invite SET revoked = 1 WHERE code = ?',
        [normalize(rawCode)],
      );

  /// Every code, as plain maps, for a recovery backup.
  List<Map<String, Object?>> export() => [
        for (final i in list())
          {
            'code': i.code,
            'label': i.label,
            'uses': i.uses,
            'maxUses': i.maxUses,
            'revoked': i.revoked,
            'createdAt': i.createdAt.millisecondsSinceEpoch,
          },
      ];

  /// Writes codes back after a reinstall.
  ///
  /// `uses` is restored as it was: a code that had been redeemed twice comes
  /// back having been redeemed twice. Resetting it would quietly hand out
  /// more invitations than the host ever agreed to.
  ///
  /// Rows that make no sense are skipped rather than failing the restore —
  /// getting the drive back matters more than getting every code back, and a
  /// missing code can be reissued.
  int restore(List<Map<String, Object?>> rows) {
    var written = 0;
    for (final row in rows) {
      final code = row['code'];
      final maxUses = row['maxUses'];
      if (code is! String || code.isEmpty || maxUses is! int || maxUses < 1) {
        continue;
      }
      final uses = row['uses'];
      _db.execute(
        'INSERT OR REPLACE INTO invite '
        '(code, label, uses, max_uses, revoked, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          normalize(code),
          row['label'] as String? ?? '',
          uses is int && uses >= 0 ? uses : 0,
          maxUses,
          row['revoked'] == true ? 1 : 0,
          row['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        ],
      );
      written++;
    }
    return written;
  }

  void remove(String rawCode) =>
      _db.execute('DELETE FROM invite WHERE code = ?', [normalize(rawCode)]);

  static Invite _fromRow(Row r) => Invite(
        code: r['code'] as String,
        label: r['label'] as String? ?? '',
        uses: r['uses'] as int,
        maxUses: r['max_uses'] as int,
        revoked: (r['revoked'] as int) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
}
