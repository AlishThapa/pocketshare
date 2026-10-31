import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Metadata database. Holds accounts and sessions only; file contents live on
/// disk under [DriveStore.root] so the drive stays readable without this app.
class DriveStore {
  DriveStore._(this._db, this.root);

  final Database _db;

  /// Directory every served file lives under. Nothing outside it is reachable.
  final Directory root;

  static Future<DriveStore> open({
    required Directory root,
    required File dbFile,
  }) async {
    await root.create(recursive: true);
    await dbFile.parent.create(recursive: true);

    final db = sqlite3.open(dbFile.path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('''
      CREATE TABLE IF NOT EXISTS account (
        id            INTEGER PRIMARY KEY CHECK (id = 1),
        username      TEXT    NOT NULL,
        password_hash TEXT    NOT NULL,
        salt          TEXT    NOT NULL,
        iterations    INTEGER NOT NULL,
        created_at    INTEGER NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS session (
        token_hash   TEXT    PRIMARY KEY,
        created_at   INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        user_agent   TEXT
      )
    ''');

    return DriveStore._(db, root);
  }

  /// The open database, so features that live alongside the drive (invite
  /// codes) can keep their tables in the same file and the same transaction
  /// boundary as everything else.
  Database get db => _db;

  bool get hasAccount =>
      _db.select('SELECT 1 FROM account WHERE id = 1').isNotEmpty;

  AccountRow? get account {
    final rows = _db.select('SELECT * FROM account WHERE id = 1');
    if (rows.isEmpty) return null;
    final r = rows.first;
    return AccountRow(
      username: r['username'] as String,
      passwordHash: r['password_hash'] as String,
      salt: r['salt'] as String,
      iterations: r['iterations'] as int,
    );
  }

  void createAccount({
    required String username,
    required String passwordHash,
    required String salt,
    required int iterations,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO account '
      '(id, username, password_hash, salt, iterations, created_at) '
      'VALUES (1, ?, ?, ?, ?, ?)',
      [username, passwordHash, salt, iterations, _now()],
    );
  }

  void putSession(String tokenHash, String? userAgent) {
    final now = _now();
    _db.execute(
      'INSERT OR REPLACE INTO session '
      '(token_hash, created_at, last_seen_at, user_agent) VALUES (?, ?, ?, ?)',
      [tokenHash, now, now, userAgent],
    );
  }

  /// Returns true and refreshes the session when [tokenHash] is live.
  bool touchSession(String tokenHash, {Duration maxAge = const Duration(days: 30)}) {
    final rows = _db.select(
      'SELECT created_at FROM session WHERE token_hash = ?',
      [tokenHash],
    );
    if (rows.isEmpty) return false;

    final createdAt = rows.first['created_at'] as int;
    if (_now() - createdAt > maxAge.inMilliseconds) {
      dropSession(tokenHash);
      return false;
    }

    _db.execute(
      'UPDATE session SET last_seen_at = ? WHERE token_hash = ?',
      [_now(), tokenHash],
    );
    return true;
  }

  void dropSession(String tokenHash) =>
      _db.execute('DELETE FROM session WHERE token_hash = ?', [tokenHash]);

  /// Invalidates every browser session. Used after a password change.
  void dropAllSessions() => _db.execute('DELETE FROM session');

  /// Forgets who owns this drive: the account and every signed-in browser.
  ///
  /// Only for disconnecting. The database itself is kept rather than deleted,
  /// because the drive's files and its trash index live on the card and are
  /// none of this file's business — a disconnect gives up an address, not
  /// somebody's photos.
  void wipeCredentials() {
    _db.execute('DELETE FROM session');
    _db.execute('DELETE FROM account');
    // Share links are credentials too — each one lets a stranger read a file
    // without signing in — and they name a hostname that is about to stop
    // existing. DROP rather than DELETE so a table from a since-changed
    // schema cannot survive a disconnect.
    _db.execute('DROP TABLE IF EXISTS share');
  }

  void close() => _db.dispose();

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}

class AccountRow {
  const AccountRow({
    required this.username,
    required this.passwordHash,
    required this.salt,
    required this.iterations,
  });

  final String username;
  final String passwordHash;
  final String salt;
  final int iterations;
}

/// Resolves a client-supplied path against the drive root, refusing anything
/// that escapes it. Every filesystem route goes through this.
File? resolveFile(Directory root, String requested) {
  final target = _resolveWithin(root, requested);
  return target == null ? null : File(target);
}

Directory? resolveDir(Directory root, String requested) {
  final target = _resolveWithin(root, requested);
  return target == null ? null : Directory(target);
}

String? _resolveWithin(Directory root, String requested) {
  final rootPath = p.normalize(root.absolute.path);
  final joined = p.normalize(p.join(rootPath, requested.replaceAll('\\', '/')));

  if (joined == rootPath) return joined;
  if (!p.isWithin(rootPath, joined)) return null;
  return joined;
}
