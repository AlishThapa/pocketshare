import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

/// A link that lets someone who is not signed in reach one file or folder.
///
/// The token *is* the permission — there is no account behind it — so it is
/// 256 bits of `Random.secure()`. Guessing one is not a threat worth modelling
/// at that size; losing one is, which is why links expire by default, can be
/// revoked, and can carry a download cap.
class Share {
  const Share({
    required this.token,
    required this.path,
    required this.isDir,
    required this.createdAt,
    required this.expiresAt,
    required this.downloads,
    required this.maxDownloads,
    required this.revoked,
    required this.hasPassword,
    required this.passwordHash,
    required this.passwordSalt,
    required this.passwordIterations,
  });

  final String token;
  final String path;
  final bool isDir;
  final int createdAt;

  /// Null means it never expires, which the UI makes the user choose.
  final int? expiresAt;

  final int downloads;
  final int? maxDownloads;
  final bool revoked;
  final bool hasPassword;

  final String? passwordHash;
  final String? passwordSalt;
  final int? passwordIterations;

  bool get expired =>
      expiresAt != null && DateTime.now().millisecondsSinceEpoch > expiresAt!;

  bool get usedUp => maxDownloads != null && downloads >= maxDownloads!;

  /// Whether the link still opens anything.
  bool get live => !revoked && !expired && !usedUp;

  /// Why it does not, in words fit to show a stranger. Deliberately vague
  /// about which of the three it was: someone holding a dead link has no
  /// business learning whether the owner revoked it or it simply ran out.
  String? get deadReason => live ? null : 'This link is no longer available.';

  /// The public shape. Never includes the password material, and never says
  /// more about a dead link than that it is dead.
  Map<String, Object?> toPublicJson() => {
        'name': path.split('/').last,
        'isDir': isDir,
        'needsPassword': hasPassword,
      };

  /// The owner's view. Carries the token, because a link you cannot copy
  /// again is a link you have to recreate every time you want to send it.
  Map<String, Object?> toOwnerJson() => {
        'token': token,
        'path': path,
        'isDir': isDir,
        'createdAt': createdAt,
        'expiresAt': expiresAt,
        'downloads': downloads,
        'maxDownloads': maxDownloads,
        'revoked': revoked,
        'hasPassword': hasPassword,
        'live': live,
      };
}

/// Storage for share links.
///
/// Tokens are kept as they are rather than hashed, which is a deliberate
/// departure from how session tokens are stored. A session token is hashed
/// because it grants the whole account and is never shown again; a share
/// token grants one path, and the owner has to be able to re-copy the link
/// weeks later. Hashing would make the feature mean "generate a link you can
/// only paste once". The database sits in app-private storage with
/// `allowBackup="false"`, and anyone who can read it can read the files it
/// points at anyway, so hashing would be protecting the lock and not the door.
class ShareStore {
  ShareStore(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS share (
        token               TEXT    PRIMARY KEY,
        path                TEXT    NOT NULL,
        is_dir              INTEGER NOT NULL,
        created_at          INTEGER NOT NULL,
        expires_at          INTEGER,
        downloads           INTEGER NOT NULL DEFAULT 0,
        max_downloads       INTEGER,
        revoked             INTEGER NOT NULL DEFAULT 0,
        password_hash       TEXT,
        password_salt       TEXT,
        password_iterations INTEGER
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS share_path ON share (path)');
  }

  final Database _db;

  static final _rng = Random.secure();

  /// 32 bytes, base64url, unpadded: 43 characters of address bar that nobody
  /// is going to guess.
  static String newToken() => base64Url
      .encode(List<int>.generate(32, (_) => _rng.nextInt(256)))
      .replaceAll('=', '');

  Share create({
    required String path,
    required bool isDir,
    int? expiresAt,
    int? maxDownloads,
    String? passwordHash,
    String? passwordSalt,
    int? passwordIterations,
  }) {
    final share = Share(
      token: newToken(),
      path: path,
      isDir: isDir,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      expiresAt: expiresAt,
      downloads: 0,
      maxDownloads: maxDownloads,
      revoked: false,
      hasPassword: passwordHash != null,
      passwordHash: passwordHash,
      passwordSalt: passwordSalt,
      passwordIterations: passwordIterations,
    );

    _db.execute(
      'INSERT INTO share (token, path, is_dir, created_at, expires_at, '
      'downloads, max_downloads, revoked, password_hash, password_salt, '
      'password_iterations) VALUES (?, ?, ?, ?, ?, 0, ?, 0, ?, ?, ?)',
      [
        share.token,
        path,
        isDir ? 1 : 0,
        share.createdAt,
        expiresAt,
        maxDownloads,
        passwordHash,
        passwordSalt,
        passwordIterations,
      ],
    );
    return share;
  }

  Share? find(String token) {
    if (token.isEmpty) return null;
    final rows = _db.select('SELECT * FROM share WHERE token = ?', [token]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<Share> list() => _db
      .select('SELECT * FROM share ORDER BY created_at DESC')
      .map(_fromRow)
      .toList();

  /// Paths with at least one link that still opens. What the file list uses
  /// to mark a row as shared, so "public" is visible without opening a menu.
  Set<String> livePaths() =>
      list().where((s) => s.live).map((s) => s.path).toSet();

  void revoke(String token) =>
      _db.execute('UPDATE share SET revoked = 1 WHERE token = ?', [token]);

  void remove(String token) =>
      _db.execute('DELETE FROM share WHERE token = ?', [token]);

  void countDownload(String token) => _db.execute(
        'UPDATE share SET downloads = downloads + 1 WHERE token = ?',
        [token],
      );

  /// Follows a rename, so sharing a file and then renaming it does not
  /// silently break the link you already sent someone.
  void repoint({required String from, required String to}) {
    _db.execute('UPDATE share SET path = ? WHERE path = ?', [to, from]);
    // Anything inside a renamed folder moves with it.
    _db.execute(
      "UPDATE share SET path = ? || substr(path, ?) WHERE path LIKE ? || '/%'",
      [to, from.length + 1, from],
    );
  }

  /// Drops links to a path that no longer exists, and to everything under it.
  void forgetPath(String path) {
    _db.execute('DELETE FROM share WHERE path = ?', [path]);
    _db.execute("DELETE FROM share WHERE path LIKE ? || '/%'", [path]);
  }

  void clear() => _db.execute('DELETE FROM share');

  static Share _fromRow(Row r) => Share(
        token: r['token'] as String,
        path: r['path'] as String,
        isDir: (r['is_dir'] as int) == 1,
        createdAt: r['created_at'] as int,
        expiresAt: r['expires_at'] as int?,
        downloads: r['downloads'] as int,
        maxDownloads: r['max_downloads'] as int?,
        revoked: (r['revoked'] as int) == 1,
        hasPassword: r['password_hash'] != null,
        passwordHash: r['password_hash'] as String?,
        passwordSalt: r['password_salt'] as String?,
        passwordIterations: r['password_iterations'] as int?,
      );
}
