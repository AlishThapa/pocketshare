import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../native.dart';
import 'migrate.dart';

/// Where the drive keeps its files.
///
/// The UI picks a volume and stores an absolute path; the foreground service
/// only ever reads that path. It has to work that way because enumerating
/// volumes needs a method channel, and the service isolate has no Activity to
/// provide one.
class DriveLocation {
  static const _storage = FlutterSecureStorage();
  static const _key = 'drive_root';

  /// Whether the folder at [_key] is one this app created, as opposed to one
  /// the user pointed us at. Only an app-made folder may be deleted when the
  /// drive moves somewhere else.
  static const _keyAppMade = 'drive_root_app_made';

  /// Folder name created on whichever volume the user picks. Deliberately
  /// plain, so it reads as theirs in the phone's own Files app rather than
  /// looking like app internals.
  static const String folderName = 'PocketShare';

  static Future<String?> savedPath() => _storage.read(key: _key);

  static Future<void> save(String path, {required bool appCreated}) async {
    await _storage.write(key: _key, value: path);
    await _storage.write(key: _keyAppMade, value: appCreated ? 'yes' : 'no');
  }

  /// True only when the saved folder is one this app made for itself. Absent
  /// means an older install, whose folder could only ever have been an
  /// app-made `PocketShare` one.
  static Future<bool> rootIsAppCreated() async =>
      (await _storage.read(key: _keyAppMade) ?? 'yes') == 'yes';

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

    // A drive that disappears when the app is uninstalled is not a drive, so
    // the shared folder is the default rather than a thing to opt into. It
    // needs all-files access, and only when that is missing does this fall
    // back to the app's own directory.
    final shared = await sharedRoot();
    if (shared != null && await _isUsable(shared)) return shared;

    return fallbackRoot();
  }

  /// `/storage/emulated/0/PocketShare` — the folder a person can actually
  /// find in Files, and which survives uninstalling the app. Null when the
  /// volume cannot be located or all-files access has not been granted.
  static Future<Directory?> sharedRoot() async {
    try {
      final externals = await getExternalStorageDirectories();
      if (externals == null || externals.isEmpty) return null;

      // getExternalStorageDirectories gives the app-private path on each
      // volume; trimming /Android/data/... yields the volume root.
      final appDir = externals.first.path;
      final marker = '${p.separator}Android${p.separator}data';
      final cut = appDir.indexOf(marker);
      if (cut <= 0) return null;

      final dir = Directory(p.join(appDir.substring(0, cut), folderName));
      await dir.create(recursive: true);
      return dir;
    } on MissingPluginException {
      return null;
    } on FileSystemException {
      // No all-files access: creating outside Android/data is refused.
      return null;
    }
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

  /// Moves everything from [from] into [to]. See [FolderMigration.move].
  static Future<MoveResult> migrate(
    Directory from,
    Directory to, {
    required bool deleteSource,
  }) =>
      FolderMigration.move(from, to, deleteSource: deleteSource);
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
