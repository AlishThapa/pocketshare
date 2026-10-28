import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../files/listing.dart';
import '../storage/drive_location.dart';
import '../storage/folder_rules.dart';
import 'widgets.dart';

/// Lets the user point the drive at any folder on the phone.
///
/// Deliberately not Android's own folder picker (ACTION_OPEN_DOCUMENT_TREE):
/// that returns a document URI, and the drive serves files through plain
/// paths from a background isolate that has no Activity to re-grant such a
/// URI to. With all-files access already held, a plain browser is both
/// honest about what will be served and the same path the server will open.
Future<String?> pickFolder(
  BuildContext context, {
  required List<StorageVolume> volumes,
  String? current,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FolderPicker(volumes: volumes, current: current),
    ),
  );
}

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.volumes, this.current});

  final List<StorageVolume> volumes;
  final String? current;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  /// Null means the volume list — the level above any single volume root.
  String? _path;
  List<Entry> _folders = const [];
  int _itemCount = 0;
  bool _loading = false;
  String? _readError;

  List<String> get _roots => widget.volumes.map((v) => v.path).toList();

  @override
  void initState() {
    super.initState();

    // Start where the drive already is, so "change folder" opens next to the
    // current one rather than at the top of the card.
    final current = widget.current;
    if (current != null && Directory(current).existsSync()) {
      _open(p.dirname(current));
    } else if (widget.volumes.length == 1) {
      _open(widget.volumes.single.path);
    }
  }

  Future<void> _open(String path) async {
    setState(() {
      _path = path;
      _loading = true;
      _readError = null;
    });

    try {
      final entries = await Listing.read(Directory(path));
      if (!mounted) return;
      setState(() {
        _folders = entries.where((e) => e.isDirectory).toList();
        _itemCount = entries.length;
        _loading = false;
      });
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() {
        _folders = const [];
        _itemCount = 0;
        _loading = false;
        _readError = e.osError?.message ?? e.message;
      });
    }
  }

  void _up() {
    final path = _path;
    if (path == null) return;

    // At a volume root, "up" is the list of volumes — but only when there is
    // more than one, otherwise it would be a list of one.
    if (_roots.any((r) => p.equals(r, path))) {
      if (widget.volumes.length > 1) {
        setState(() {
          _path = null;
          _folders = const [];
        });
      }
      return;
    }
    _open(p.dirname(path));
  }

  bool get _canGoUp {
    final path = _path;
    if (path == null) return false;
    if (_roots.any((r) => p.equals(r, path))) return widget.volumes.length > 1;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final path = _path;
    final problem = path == null ? null : FolderRules.problem(path, _roots);

    return PopScope(
      canPop: !_canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Choose a folder'),
          actions: [
            if (path != null && problem == null)
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: 'New folder',
                onPressed: _newFolder,
              ),
          ],
        ),
        body: Column(
          children: [
            if (path != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: Text(
                  path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Expanded(child: _body()),
            if (path != null)
              _Footer(
                problem: problem,
                itemCount: _itemCount,
                onUse: problem != null ? null : () => _use(path),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_path == null) return _volumeList();
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_readError != null) {
      return _Empty(
        icon: Icons.lock_outline,
        title: 'Cannot read this folder',
        body: _readError!,
      );
    }

    if (_folders.isEmpty) {
      return _Empty(
        icon: Icons.folder_open_outlined,
        title: 'No folders in here',
        body: _itemCount == 0
            ? 'This folder is empty. You can still use it, or make a new one.'
            : 'There are $_itemCount files here but no folders to go into.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: _folders.length + (_canGoUp ? 1 : 0),
      itemBuilder: (context, index) {
        if (_canGoUp && index == 0) {
          return ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('Up one level'),
            onTap: _up,
          );
        }
        final folder = _folders[index - (_canGoUp ? 1 : 0)];
        return ListTile(
          leading: Icon(Icons.folder,
              color: Theme.of(context).colorScheme.primary),
          title: Text(folder.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(Listing.humanCount(folder.size)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(folder.path),
        );
      },
    );
  }

  Widget _volumeList() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (final volume in widget.volumes)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Panel(
              onTap: () => _open(volume.path),
              child: Row(
                children: [
                  Icon(volume.removable ? Icons.sd_card : Icons.smartphone),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(volume.label,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(
                          '${Listing.humanSize(volume.freeBytes)} free of '
                          '${Listing.humanSize(volume.totalBytes)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _newFolder() async {
    final parent = _path;
    if (parent == null) return;

    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFolderDialog(),
    );
    if (name == null || !mounted) return;

    final dir = Directory(p.join(parent, name));
    try {
      if (await dir.exists()) {
        _say('There is already a folder called $name here.');
      } else {
        await dir.create();
      }
    } on FileSystemException catch (e) {
      _say('Could not create it: ${e.osError?.message ?? e.message}');
      return;
    }
    if (mounted) await _open(dir.path);
  }

  Future<void> _use(String path) async {
    // Everything in the chosen folder becomes reachable from the internet the
    // moment the drive restarts, so a folder that already has contents is
    // confirmed rather than assumed.
    if (_itemCount > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Use this folder?'),
          content: Text(
            'There ${_itemCount == 1 ? 'is' : 'are'} already $_itemCount '
            '${_itemCount == 1 ? 'item' : 'items'} in this folder. Everything '
            'in it — and anything added to it later — becomes part of your '
            'drive, reachable by anyone who signs in.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Use it'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    if (mounted) Navigator.of(context).pop(path);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.problem,
    required this.itemCount,
    required this.onUse,
  });

  final String? problem;
  final int itemCount;
  final VoidCallback? onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        problem!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  itemCount == 0
                      ? 'This folder is empty.'
                      : 'Everything in this folder becomes part of your drive.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            FilledButton(
              onPressed: onUse,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Use this folder'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
      ),
    );
  }
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Nothing that could escape the folder it is created in, and nothing the
  /// filesystem will refuse halfway through.
  static String? _problem(String name) {
    if (name.isEmpty) return 'Give it a name.';
    if (name == '.' || name == '..') return 'Pick a different name.';
    if (name.startsWith('.')) return 'Names starting with a dot are hidden.';
    if (RegExp(r'[/\\:*?"<>|\x00-\x1f]').hasMatch(name)) {
      return 'A folder name cannot contain / \\ : * ? " < > |';
    }
    if (name.length > 100) return 'That name is too long.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: TextField(
        controller: _name,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Name',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    final problem = _problem(name);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(name);
  }
}
