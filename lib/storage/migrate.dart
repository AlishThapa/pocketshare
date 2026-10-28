import 'dart:io';

import 'package:path/path.dart' as p;

/// Carries the drive's files from one folder to another.
///
/// Lives apart from [DriveLocation] so it can be tested on a laptop: this is
/// the one piece of the app that moves a person's entire drive around, and
/// "it worked when I tried it on the phone" is not a standard for code that
/// deletes the source afterwards.
class FolderMigration {
  /// Copies everything under [from] into [to], and removes [from] only when
  /// [deleteSource] says the app made that folder itself.
  ///
  /// Copies rather than renames, since rename(2) cannot cross filesystems and
  /// internal storage and an SD card are never the same one.
  ///
  /// [deleteSource] exists because the drive's folder is no longer always a
  /// `PocketShare` folder this app created. It can be `DCIM/Camera` or
  /// `Download` — a folder full of things the user has never thought of as
  /// "the drive's files". Emptying one of those and then deleting it, on a
  /// tap labelled "Change folder", would be the worst thing this app could
  /// do to someone. So a folder the app did not create is copied out of and
  /// left exactly as it was found.
  static Future<MoveResult> move(
    Directory from,
    Directory to, {
    required bool deleteSource,
  }) async {
    if (p.equals(from.path, to.path)) {
      return const MoveResult(moved: 0, sourceRemoved: false);
    }
    if (!await from.exists()) {
      return const MoveResult(moved: 0, sourceRemoved: false);
    }

    // Moving into a subfolder of the drive's own folder would copy everything
    // inwards and then delete the old folder — which by then contains the
    // copies. Everything, gone, on a tap meant to tidy up.
    if (p.isWithin(from.path, to.path)) {
      throw FileSystemException(
        'That folder is inside the one the drive uses now. Pick one somewhere '
        'else, or the files would be deleted on the way across.',
        to.path,
      );
    }

    await to.create(recursive: true);
    var moved = 0;

    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, relative);

      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        // The destination is now any folder the user picked, so a name can
        // already be taken by something that has nothing to do with the
        // drive. Overwriting it is silent data loss; landing beside it is not.
        await entity.copy(await freeName(target));
        moved++;
      }
    }

    if (!deleteSource) {
      return MoveResult(moved: moved, sourceRemoved: false);
    }

    try {
      await from.delete(recursive: true);
      return MoveResult(moved: moved, sourceRemoved: true);
    } on FileSystemException {
      // The copies are safely in place; leaving the originals behind is the
      // safe way for this to fail.
      return MoveResult(moved: moved, sourceRemoved: false);
    }
  }

  /// [target], or the next `name (n).ext` beside it that is still free.
  static Future<String> freeName(String target) async {
    if (!await _taken(target)) return target;

    final dir = p.dirname(target);
    final extension = p.extension(target);
    final stem = p.basenameWithoutExtension(target);

    for (var n = 1; n < 1000; n++) {
      final candidate = p.join(dir, '$stem ($n)$extension');
      if (!await _taken(candidate)) return candidate;
    }
    throw FileSystemException('too many files named $stem', target);
  }

  static Future<bool> _taken(String path) async =>
      await File(path).exists() || await Directory(path).exists();
}

/// What a move did, so the UI can say whether the old folder is still there.
class MoveResult {
  const MoveResult({required this.moved, required this.sourceRemoved});

  final int moved;
  final bool sourceRemoved;
}
