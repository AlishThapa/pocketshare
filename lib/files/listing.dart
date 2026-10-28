import 'dart:io';

import 'package:path/path.dart' as p;

/// One row in the in-app file browser.
class Entry {
  const Entry({
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String path;
  final bool isDirectory;

  /// Bytes for a file; for a directory, the number of items directly inside.
  final int size;
  final DateTime? modified;

  String get name => p.basename(path);
}

/// Reads one directory, without descending.
///
/// Deliberately shallow: the drive's folder can hold tens of thousands of
/// files, and a recursive walk to draw one screen would stall the UI isolate
/// for as long as the card is slow.
class Listing {
  /// The drive's own bookkeeping: the trash and its index. The web UI hides
  /// it, so this hides it too — otherwise deleting a file in the browser
  /// makes it reappear here, inside a folder the user never made.
  static const String internalFolder = '.pocketshare';

  static Future<List<Entry>> read(Directory dir) async {
    final entries = <Entry>[];

    await for (final entity in dir.list(followLinks: false)) {
      if (p.basename(entity.path) == internalFolder) continue;

      // A listing is drawn from whatever is on the card, including files
      // another app wrote a moment ago and deleted a moment later. A stat
      // that fails is a row to skip, not a screen to fail.
      try {
        final stat = await entity.stat();

        // The entity decides, not the stat: stat() follows links, so a
        // symlink to a directory reports itself as one while the entity is
        // still a Link — and casting that to Directory throws a TypeError
        // that no FileSystemException catch will ever see.
        final isDir = entity is Directory;
        entries.add(Entry(
          path: entity.path,
          isDirectory: isDir,
          size: isDir ? await _count(entity) : stat.size,
          modified: stat.modified,
        ));
      } on FileSystemException {
        continue;
      }
    }

    return sort(entries);
  }

  static Future<int> _count(Directory dir) async {
    try {
      var n = 0;
      await for (final _ in dir.list(followLinks: false)) {
        n++;
        // Nobody reads "4,812 items" differently from "999+", and counting
        // the rest costs a syscall each on a slow card.
        if (n > 999) return 1000;
      }
      return n;
    } on FileSystemException {
      return 0;
    }
  }

  /// Folders first, then by name, case-insensitively — the order every file
  /// manager uses, so it needs no explaining.
  static List<Entry> sort(List<Entry> entries) {
    final sorted = [...entries];
    sorted.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  static String humanSize(int bytes) {
    if (bytes < 0) return '';
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
  }

  static String humanCount(int items) => switch (items) {
        0 => 'Empty',
        1 => '1 item',
        > 999 => '999+ items',
        _ => '$items items',
      };

  /// Dates on a phone screen: the time today, the weekday this week, the
  /// date otherwise. Never a timestamp nobody reads.
  static String humanWhen(DateTime? when, {DateTime? now}) {
    if (when == null) return '';
    final today = now ?? DateTime.now();
    final difference = today.difference(when);

    if (difference.inDays == 0 && when.day == today.day) {
      final hour = when.hour.toString().padLeft(2, '0');
      final minute = when.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    if (difference.inDays < 7 && !difference.isNegative) {
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return names[when.weekday - 1];
    }
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final label = '${when.day} ${months[when.month - 1]}';
    return when.year == today.year ? label : '$label ${when.year}';
  }
}
