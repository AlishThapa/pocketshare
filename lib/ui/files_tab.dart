import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;

import '../files/listing.dart';
import '../native.dart';
import '../state/drive_controller.dart';
import '../storage/migrate.dart';
import 'folder_picker.dart';
import 'widgets.dart';

/// Browses the drive's own folder, from inside the app.
///
/// The point is that the folder is a real, ordinary folder on the phone: this
/// shows exactly what is in it and can hand it to the phone's file manager.
/// Everything here is read-only. Adding and deleting happen over the web UI,
/// which already has the whole upload, trash and restore story; duplicating
/// that here would be two half-implementations of the same thing.
/// Reads one directory. Injectable so a widget test can render this screen
/// without real file I/O, which never completes under the fake clock a
/// widget test runs on.
typedef DirectoryReader = Future<List<Entry>> Function(Directory dir);

class FilesTab extends StatefulWidget {
  const FilesTab({
    super.key,
    required this.controller,
    required this.active,
    this.read = Listing.read,
  });

  final DriveController controller;

  final DirectoryReader read;

  /// Whether this tab is the one on screen. The tabs stay alive behind each
  /// other, so the back button must only be claimed by the visible one.
  final bool active;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  String? _root;
  String? _path;
  List<Entry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// Where the drive ought to live: `PocketShare` on internal storage. Only
  /// filled when the drive is somewhere it should not stay, so the one-tap
  /// offer never appears next to a folder the user chose on purpose.
  String? _suggested;

  @override
  void initState() {
    super.initState();
    _syncRoot();
    _findSuggestion();
  }

  Future<void> _findSuggestion() async {
    if (widget.controller.storageSurvivesUninstall) return;
    try {
      final volumes = await widget.controller.storageVolumes();
      if (!mounted || volumes.isEmpty) return;
      setState(() => _suggested = volumes.first.drivePath);
    } on MissingPluginException {
      // Not on Android; the offer simply does not appear.
    }
  }

  @override
  void didUpdateWidget(FilesTab old) {
    super.didUpdateWidget(old);
    // The folder can be changed from this very screen, and the controller is
    // the one that knows where it ended up.
    if (widget.controller.driveRootPath != _root) _syncRoot();
  }

  void _syncRoot() {
    final root = widget.controller.driveRootPath;
    _root = root;
    if (root == null) {
      setState(() => _loading = false);
      return;
    }
    _open(root);
  }

  Future<void> _open(String path) async {
    setState(() {
      _path = path;
      _loading = true;
      _error = null;
    });

    try {
      final entries = await widget.read(Directory(path));
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on FileSystemException catch (e) {
      // Covers the folder having been deleted or unmounted since the last
      // look, as well as a permission the user revoked while away.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _entries = const [];
        _error = e.osError?.message ?? e.message;
      });
    }
  }

  bool get _atRoot {
    final path = _path;
    final root = _root;
    return path == null || root == null || p.equals(path, root);
  }

  void _up() {
    if (_atRoot) return;
    _open(p.dirname(_path!));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return PopScope(
      canPop: !widget.active || _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: RefreshIndicator(
        onRefresh: () async {
          final path = _path;
          if (path != null) await _open(path);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _LocationPanel(
              path: c.driveRootPath,
              survivesUninstall: c.storageSurvivesUninstall,
              suggested: _suggested,
              onMoveToSuggested: _moveToSuggested,
              onChangeFolder: _changeFolder,
              onOpenExternally: _openInFileManager,
            ),
            if (!_atRoot) ...[
              const SizedBox(height: 16),
              _Breadcrumb(
                root: _root!,
                path: _path!,
                onUp: _up,
                onJump: _open,
              ),
            ],
            const SizedBox(height: 8),
            ..._rows(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _rows(BuildContext context) {
    if (_loading) {
      return const [
        SizedBox(height: 120),
        Center(child: CircularProgressIndicator()),
      ];
    }

    final error = _error;
    if (error != null) {
      return [
        const SizedBox(height: 60),
        _Message(
          icon: Icons.error_outline,
          title: 'Cannot read this folder',
          body: error,
        ),
      ];
    }

    if (_entries.isEmpty) {
      return [
        const SizedBox(height: 60),
        _Message(
          icon: Icons.inbox_outlined,
          title: 'Nothing here yet',
          body: _atRoot
              ? 'Open your address in a browser and upload something, or drop '
                  'files into this folder from the phone itself.'
              : 'This folder is empty.',
        ),
      ];
    }

    return [
      PanelList(
        children: [
          for (final entry in _entries) _entryTile(context, entry),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        Listing.humanCount(_entries.length),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    ];
  }

  Widget _entryTile(BuildContext context, Entry entry) {
    final when = Listing.humanWhen(entry.modified);
    final detail = entry.isDirectory
        ? Listing.humanCount(entry.size)
        : Listing.humanSize(entry.size);

    return PanelTile(
      icon: entry.isDirectory ? Icons.folder_rounded : _iconFor(entry.name),
      title: entry.name,
      subtitle: when.isEmpty ? detail : '$detail · $when',
      trailing: entry.isDirectory
          ? const Icon(Icons.chevron_right, size: 20)
          : const Icon(Icons.open_in_new, size: 18),
      onTap: () =>
          entry.isDirectory ? _open(entry.path) : _openFile(entry),
    );
  }

  static IconData _iconFor(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' || '.heic' =>
        Icons.image_outlined,
      '.mp4' || '.mkv' || '.mov' || '.webm' || '.avi' =>
        Icons.movie_outlined,
      '.mp3' || '.m4a' || '.wav' || '.flac' || '.ogg' =>
        Icons.audiotrack_outlined,
      '.pdf' => Icons.picture_as_pdf_outlined,
      '.zip' || '.rar' || '.7z' || '.tar' || '.gz' => Icons.folder_zip_outlined,
      '.txt' || '.md' || '.csv' || '.json' || '.log' =>
        Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Future<void> _openFile(Entry entry) async {
    final opened = await Native.openFile(entry.path);
    if (!mounted || opened) return;
    _say('No app on this phone can open ${entry.name}.');
  }

  Future<void> _openInFileManager() async {
    final path = _path ?? _root;
    if (path == null) return;
    final opened = await Native.openFolder(path);
    if (!mounted || opened) return;
    _say('This phone has no file manager that will open a folder directly.');
  }

  /// Moves the drive to the obvious folder — `PocketShare` on internal
  /// storage — without making the user walk a picker to find it.
  ///
  /// This exists because the drive only sits in app-private storage when
  /// all-files access was missing at first run, and the way out of that is
  /// always the same folder. Offering it as one tap beats asking someone to
  /// navigate to a place they have no particular reason to know about.
  Future<void> _moveToSuggested() async {
    final target = _suggested;
    if (target == null || !await _ensureAllFilesAccess()) return;

    try {
      await Directory(target).create(recursive: true);
    } on FileSystemException catch (e) {
      _say('Could not create $target: ${e.osError?.message ?? e.message}');
      return;
    }
    if (!mounted) return;
    await _moveTo(target);
  }

  /// True when the drive may write outside its own sandbox. Returns false
  /// after sending the user to the system screen, since the answer only
  /// changes once they come back.
  Future<bool> _ensureAllFilesAccess() async {
    if (await Native.hasAllFilesAccess()) return true;
    if (!mounted) return false;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Allow access to all files'),
        content: const Text(
          'To keep your files in a folder of your own — one that survives '
          'uninstalling this app, and that you can open in the phone\'s '
          'Files app — Android needs to grant this app access to storage.\n\n'
          'You will be taken to a system screen to turn it on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
    await Native.requestAllFilesAccess();
    return false; // The user comes back and taps again.
  }

  Future<void> _changeFolder() async {
    final c = widget.controller;
    if (!await _ensureAllFilesAccess()) return;

    final volumes = await c.storageVolumes();
    if (!mounted) return;

    final chosen = await pickFolder(
      context,
      volumes: volumes,
      current: c.driveRootPath,
    );
    if (chosen == null || !mounted) return;
    await _moveTo(chosen);
  }

  Future<void> _moveTo(String target) async {
    final c = widget.controller;
    final was = c.driveRootPath ?? '';
    if (p.equals(target, was)) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Moving your files…')),
    );

    try {
      final result = await c.changeStorageToPath(target);
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(_moveReport(result, from: was, to: target)),
        ),
      );
      if (mounted) _syncRoot();
    } on FileSystemException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }


  /// Says plainly whether the old folder is still there.
  ///
  /// It usually is: a folder the user picked is copied out of and left alone,
  /// because it may be Download or DCIM and full of things that were never
  /// "the drive's files". Saying so is the difference between the user
  /// tidying up the leftovers themselves and the user hunting for photos.
  static String _moveReport(
    MoveResult result, {
    required String from,
    required String to,
  }) {
    if (result.moved == 0) return 'Your drive now uses $to';

    final files = result.moved == 1 ? '1 file' : '${result.moved} files';
    return result.sourceRemoved
        ? 'Moved $files to $to'
        : 'Copied $files to $to. The old folder, $from, was left as it was — '
            'delete it yourself once you are happy.';
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LocationPanel extends StatelessWidget {
  const _LocationPanel({
    required this.path,
    required this.survivesUninstall,
    required this.suggested,
    required this.onMoveToSuggested,
    required this.onChangeFolder,
    required this.onOpenExternally,
  });

  final String? path;
  final bool survivesUninstall;

  /// The folder the drive should move to, when it is somewhere temporary.
  final String? suggested;

  final VoidCallback onMoveToSuggested;
  final VoidCallback onChangeFolder;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_special_outlined,
                  size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Text('Your drive folder', style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            path ?? 'Working it out…',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (path != null && !survivesUninstall) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'This folder belongs to the app. Uninstalling PocketShare '
                    'deletes everything in it, and the phone\'s Files app '
                    'cannot open it. Move it somewhere permanent.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),

          // When the folder is temporary, the fix is always the same folder,
          // so it is one labelled button rather than a picker the user has
          // to navigate on their own.
          if (!survivesUninstall && suggested != null) ...[
            FilledButton.icon(
              onPressed: onMoveToSuggested,
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: Text('Move to ${p.basename(suggested!)}'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              suggested!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: onOpenExternally,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open in Files'),
              ),
              OutlinedButton.icon(
                onPressed: onChangeFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(
                  survivesUninstall ? 'Change folder' : 'Choose a folder',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Where you are, relative to the drive's root, with a tap back to any level.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.root,
    required this.path,
    required this.onUp,
    required this.onJump,
  });

  final String root;
  final String path;
  final VoidCallback onUp;
  final void Function(String) onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parts = p.split(p.relative(path, from: root));

    final crumbs = <Widget>[
      _crumb(context, p.basename(root), () => onJump(root)),
    ];
    var walked = root;
    for (var i = 0; i < parts.length; i++) {
      walked = p.join(walked, parts[i]);
      final target = walked;
      crumbs
        ..add(Icon(Icons.chevron_right,
            size: 16, color: scheme.onSurfaceVariant))
        ..add(_crumb(
          context,
          parts[i],
          i == parts.length - 1 ? null : () => onJump(target),
        ));
    }

    return Row(
      children: [
        IconButton(
          onPressed: onUp,
          icon: const Icon(Icons.arrow_back, size: 20),
          tooltip: 'Up one level',
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(children: crumbs),
          ),
        ),
      ],
    );
  }

  Widget _crumb(BuildContext context, String label, VoidCallback? onTap) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: onTap == null
                ? theme.colorScheme.onSurface
                : theme.colorScheme.primary,
            fontWeight: onTap == null ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
