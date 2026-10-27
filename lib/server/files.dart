import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart';

/// Filesystem operations scoped to the drive root.
///
/// Every public method takes a client-supplied relative path and resolves it
/// through [resolveDir]/[resolveFile], which reject anything escaping the root.
class DriveFiles {
  DriveFiles(this.root);

  final Directory root;

  /// Deleted items move here instead of being unlinked, so a bad tap on a
  /// phone screen is recoverable.
  Directory get trashDir => Directory(p.join(root.path, '.pocketshare', 'trash'));

  File get _trashIndex =>
      File(p.join(root.path, '.pocketshare', 'trash', 'index.json'));

  /// Internal bookkeeping that should never show up as user content.
  static bool _isInternal(String name) => name == '.pocketshare';

  Future<List<Map<String, Object?>>> list(String relative) async {
    final dir = resolveDir(root, relative);
    if (dir == null) throw DrivePathError('path outside drive');
    if (!await dir.exists()) throw DriveNotFound(relative);

    final out = <Map<String, Object?>>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (_isInternal(name)) continue;

      final stat = await entity.stat();
      out.add({
        'name': name,
        'path': p.relative(entity.path, from: root.path),
        'isDir': stat.type == FileSystemEntityType.directory,
        'size': stat.size,
        'modified': stat.modified.millisecondsSinceEpoch,
      });
    }

    out.sort((a, b) {
      final ad = a['isDir'] as bool, bd = b['isDir'] as bool;
      if (ad != bd) return ad ? -1 : 1;
      return (a['name'] as String)
          .toLowerCase()
          .compareTo((b['name'] as String).toLowerCase());
    });
    return out;
  }

  Future<Directory> mkdir(String relative) async {
    final dir = resolveDir(root, relative);
    if (dir == null) throw DrivePathError('path outside drive');
    if (await dir.exists()) throw DriveConflict('already exists');
    return dir.create(recursive: true);
  }

  Future<void> rename(String from, String to) async {
    final src = _resolveExisting(from);
    final dst = _resolveTarget(to);
    if (await _exists(dst)) throw DriveConflict('target already exists');
    await Directory(p.dirname(dst)).create(recursive: true);
    await _rename(src, dst);
  }

  /// Moves [from] *into* the directory [toDir], keeping its basename.
  Future<void> move(String from, String toDir) async {
    final src = _resolveExisting(from);
    final destDir = resolveDir(root, toDir);
    if (destDir == null) throw DrivePathError('path outside drive');
    if (!await destDir.exists()) throw DriveNotFound(toDir);

    final dst = p.join(destDir.path, p.basename(src));
    if (p.equals(src, dst)) return;
    // Moving a directory into itself would detach the subtree.
    if (p.isWithin(src, destDir.path)) {
      throw DriveConflict('cannot move a folder into itself');
    }
    if (await _exists(dst)) throw DriveConflict('target already exists');
    await _rename(src, dst);
  }

  /// Moves an entry to trash and records where it came from.
  Future<void> trash(String relative) async {
    final src = _resolveExisting(relative);
    await trashDir.create(recursive: true);

    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final parked = p.join(trashDir.path, id);
    final originalPath = p.relative(src, from: root.path);

    await _rename(src, parked);

    final index = await _readTrashIndex();
    index.add({
      'id': id,
      'name': p.basename(src),
      'originalPath': originalPath,
      'deletedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await _writeTrashIndex(index);
  }

  Future<List<Map<String, Object?>>> listTrash() async => _readTrashIndex();

  Future<void> restore(String id) async {
    final index = await _readTrashIndex();
    final entry = index.cast<Map<String, Object?>?>().firstWhere(
          (e) => e!['id'] == id,
          orElse: () => null,
        );
    if (entry == null) throw DriveNotFound(id);

    final parked = p.join(trashDir.path, id);
    final dst = _resolveTarget(entry['originalPath'] as String);
    if (await _exists(dst)) throw DriveConflict('something is back at that path');

    await Directory(p.dirname(dst)).create(recursive: true);
    await _rename(parked, dst);

    index.removeWhere((e) => e['id'] == id);
    await _writeTrashIndex(index);
  }

  Future<void> emptyTrash() async {
    if (await trashDir.exists()) {
      await for (final e in trashDir.list(followLinks: false)) {
        if (p.basename(e.path) == 'index.json') continue;
        await e.delete(recursive: true);
      }
    }
    await _writeTrashIndex([]);
  }

  /// Case-insensitive substring match on names, depth-first, capped so a huge
  /// card cannot pin the CPU on one request.
  Future<List<Map<String, Object?>>> search(String query, {int limit = 200}) async {
    final needle = query.toLowerCase().trim();
    if (needle.isEmpty) return const [];

    final out = <Map<String, Object?>>[];
    final queue = <Directory>[root];

    while (queue.isNotEmpty && out.length < limit) {
      final dir = queue.removeAt(0);
      try {
        await for (final entity in dir.list(followLinks: false)) {
          final name = p.basename(entity.path);
          if (_isInternal(name)) continue;

          final stat = await entity.stat();
          final isDir = stat.type == FileSystemEntityType.directory;
          if (isDir) queue.add(Directory(entity.path));

          if (name.toLowerCase().contains(needle)) {
            out.add({
              'name': name,
              'path': p.relative(entity.path, from: root.path),
              'isDir': isDir,
              'size': stat.size,
              'modified': stat.modified.millisecondsSinceEpoch,
            });
            if (out.length >= limit) break;
          }
        }
      } on FileSystemException {
        // Unreadable directory (permissions, vanished mid-walk) — skip it
        // rather than failing the whole search.
        continue;
      }
    }
    return out;
  }

  Future<int> usedBytes() async {
    var total = 0;
    final queue = <Directory>[root];
    while (queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      try {
        await for (final e in dir.list(followLinks: false)) {
          final stat = await e.stat();
          if (stat.type == FileSystemEntityType.directory) {
            queue.add(Directory(e.path));
          } else {
            total += stat.size;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return total;
  }

  // --- helpers -------------------------------------------------------------

  String _resolveExisting(String relative) {
    final f = resolveFile(root, relative);
    if (f == null) throw DrivePathError('path outside drive');
    if (!(File(f.path).existsSync() || Directory(f.path).existsSync())) {
      throw DriveNotFound(relative);
    }
    return f.path;
  }

  String _resolveTarget(String relative) {
    final f = resolveFile(root, relative);
    if (f == null) throw DrivePathError('path outside drive');
    return f.path;
  }

  static Future<bool> _exists(String path) async =>
      await File(path).exists() || await Directory(path).exists();

  /// rename(2) fails across filesystems; fall back to copy+delete so moving
  /// between internal storage and the SD card still works.
  static Future<void> _rename(String src, String dst) async {
    final isDir = await Directory(src).exists();
    try {
      if (isDir) {
        await Directory(src).rename(dst);
      } else {
        await File(src).rename(dst);
      }
    } on FileSystemException {
      if (isDir) {
        await _copyDir(Directory(src), Directory(dst));
        await Directory(src).delete(recursive: true);
      } else {
        await File(src).copy(dst);
        await File(src).delete();
      }
    }
  }

  static Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final target = p.join(dst.path, p.basename(e.path));
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }

  Future<List<Map<String, Object?>>> _readTrashIndex() async {
    if (!await _trashIndex.exists()) return [];
    try {
      final raw = jsonDecode(await _trashIndex.readAsString());
      return (raw as List).cast<Map<String, Object?>>();
    } on FormatException {
      // A truncated index must not make the whole drive unusable.
      return [];
    }
  }

  Future<void> _writeTrashIndex(List<Map<String, Object?>> index) async {
    await _trashIndex.parent.create(recursive: true);
    await _trashIndex.writeAsString(jsonEncode(index));
  }
}

class DrivePathError implements Exception {
  DrivePathError(this.message);
  final String message;
}

class DriveNotFound implements Exception {
  DriveNotFound(this.path);
  final String path;
}

class DriveConflict implements Exception {
  DriveConflict(this.message);
  final String message;
}
