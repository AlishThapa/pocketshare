import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../native.dart';

/// Where the drive keeps its files.
///
/// The UI picks a volume and stores an absolute path; the foreground service
/// only ever reads that path. It has to work that way because enumerating
/// volumes needs a method channel, and the service isolate has no Activity to
/// provide one.
class DriveLocation {
  static const _storage = FlutterSecureStorage();
  static const _key = 'drive_root';

  /// Folder name created on whichever volume the user picks. Deliberately
  /// plain, so it reads as theirs in the phone's own Files app rather than
  /// looking like app internals.
  static const String folderName = 'PocketShare';

  static Future<String?> savedPath() => _storage.read(key: _key);

  static Future<void> save(String path) =>
      _storage.write(key: _key, value: path);

  /// The directory to serve from, in order of preference:
  /// the user's choice, then app-private storage as a usable fallback.
  static Future<Directory> resolve() async {
    final chosen = await savedPath();
    if (chosen != null) {
      final dir = Directory(chosen);
      if (await _isUsable(dir)) return dir;
      // Saved path gone: an SD card pulled out, or all-files access revoked.
      // Fall through rather than leaving the drive dead.
    }
    return fallbackRoot();
  }

  /// Always-writable location inside the app's own storage. No permission
  /// needed, but Android deletes it when the app is uninstalled.
  static Future<Directory> fallbackRoot() async {
    try {
      final externals = await getExternalStorageDirectories();
      if (externals != null && externals.isNotEmpty) {
        final dir = Directory(p.join(externals.first.path, folderName));
        await dir.create(recursive: true);
        return dir;
      }
    } on MissingPluginException {
      // Not Android; fall through.
    } on FileSystemException {
      // Unwritable; fall through.
    }

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, folderName));
    await dir.create(recursive: true);
    return dir;
  }

  /// True when the app's files survive uninstall — i.e. the drive is not
  /// inside the app's private directory.
  static bool survivesUninstall(String path) =>
      !path.contains('/Android/data/');

  static Future<bool> _isUsable(Directory dir) async {
    try {
      await dir.create(recursive: true);

      // canWrite() lies on some ROMs; an actual write is the only honest test.
      final probe = File(p.join(dir.path, '.pocketshare-write-test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  // --- UI isolate only -------------------------------------------------------

  /// Volumes the user can choose between. Needs the method channel, so this
  /// works only where an Activity exists.
  static Future<List<StorageVolume>> volumes() async {
    final raw = await Native.storageVolumes();
    return [
      for (final v in raw)
        StorageVolume(
          path: v['path'] as String,
          removable: v['removable'] as bool? ?? false,
          totalBytes: (v['totalBytes'] as num?)?.toInt() ?? 0,
          freeBytes: (v['freeBytes'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// Moves everything from [from] into [to], then removes the old folder.
  ///
  /// Copies rather than renames across volumes, since rename(2) cannot cross
  /// filesystems and internal storage and an SD card are never the same one.
  static Future<int> migrate(Directory from, Directory to) async {
    if (p.equals(from.path, to.path)) return 0;
    if (!await from.exists()) return 0;

    await to.create(recursive: true);
    var moved = 0;

    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, relative);

      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
        moved++;
      }
    }

    try {
      await from.delete(recursive: true);
    } on FileSystemException {
      // Copies are safely in place; leaving the originals is the safe failure.
    }
    return moved;
  }
}

class StorageVolume {
  const StorageVolume({
    required this.path,
    required this.removable,
    required this.totalBytes,
    required this.freeBytes,
  });

  final String path;
  final bool removable;
  final int totalBytes;
  final int freeBytes;

  /// Where the drive would live on this volume.
  String get drivePath => p.join(path, DriveLocation.folderName);

  String get label => removable ? 'SD card' : 'Internal storage';
}
