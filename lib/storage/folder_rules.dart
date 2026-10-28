import 'package:path/path.dart' as p;

/// Which folders the drive may be pointed at.
///
/// This matters more than a normal folder picker: whatever is chosen becomes
/// the root of something published on the internet behind one password. The
/// rules exist so that a stray tap cannot turn the phone's entire storage —
/// camera roll, downloads, WhatsApp media, other apps' exported files — into
/// the drive without the user ever meaning to.
///
/// Pure, so it can be tested without a device.
class FolderRules {
  /// Directory names directly under a volume root that are never a sensible
  /// drive root, because picking one publishes a system-managed pile of
  /// everything rather than a folder the user curates.
  static const Set<String> _offLimits = {
    'Android', // app sandboxes, including this app's own
  };

  /// Whether a folder sitting directly under a volume root is one the drive
  /// may never use. The picker hides these rather than offering a door that
  /// is always locked — and in `Android/data`'s case, one that Android will
  /// not even let it read the inside of.
  static bool isOffLimitsName(String name) => _offLimits.contains(name);

  /// True when [path] is inside app-sandbox storage.
  ///
  /// The picker needs this separately from [problem]: a folder it must not
  /// *start* in, because the way back out runs through `Android/data`, which
  /// is unreadable even with all-files access, so an up-by-one walk hits a
  /// wall instead of reaching the volume root.
  static bool isAppPrivate(String path, List<String> volumeRoots) {
    final norm = p.normalize(path);
    final root = _owningRoot(norm, volumeRoots);
    if (root == null || p.equals(norm, root)) return false;
    return _offLimits.contains(p.split(p.relative(norm, from: root)).first);
  }

  /// The volume [norm] sits on — the longest matching root, so a volume
  /// mounted inside another is attributed to the inner one.
  static String? _owningRoot(String norm, List<String> volumeRoots) =>
      volumeRoots
          .map(p.normalize)
          .where((r) => p.equals(norm, r) || p.isWithin(r, norm))
          .fold<String?>(
              null,
              (longest, r) =>
                  longest == null || r.length > longest.length ? r : longest);

  /// Returns a human explanation when [path] cannot be the drive's folder, or
  /// null when it can.
  ///
  /// [volumeRoots] are the storage roots the device reports, e.g.
  /// `/storage/emulated/0` and an SD card mount.
  static String? problem(String path, List<String> volumeRoots) {
    if (path.isEmpty) return 'Pick a folder.';
    if (!p.isAbsolute(path)) return 'That is not a full path.';

    final norm = p.normalize(path);
    if (norm != path) {
      // Anything that normalises differently contains `..`, a doubled
      // separator or a trailing slash. Rather than silently accept the
      // normalised form, refuse: the path shown must be the path served.
      return 'That path is not a plain folder path.';
    }

    final root = _owningRoot(norm, volumeRoots);

    if (root == null) {
      return 'That folder is not on the phone\'s storage. Pick somewhere '
          'under internal storage or a memory card.';
    }

    if (p.equals(norm, root)) {
      // Serving the volume root would publish every file on the phone, which
      // is never what someone picking a drive folder means to do.
      return 'That is the whole of your storage. Pick a folder inside it — '
          'everything in the folder you choose is published.';
    }

    final parts = p.split(p.relative(norm, from: root));
    if (_offLimits.contains(parts.first)) {
      return 'That folder belongs to installed apps. Android deletes parts of '
          'it when apps are uninstalled, and other apps cannot read it. Pick '
          'a normal folder.';
    }

    return null;
  }
}
