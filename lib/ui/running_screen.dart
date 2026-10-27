import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import '../native.dart';
import '../storage/drive_location.dart';
import '../state/drive_controller.dart';
import '../tunnel/cloudflared.dart';

/// The drive's home screen once setup is done.
class RunningScreen extends StatefulWidget {
  const RunningScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  State<RunningScreen> createState() => _RunningScreenState();
}

class _RunningScreenState extends State<RunningScreen> with WidgetsBindingObserver {
  bool _batteryExempt = true;
  bool _filesAccess = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Both settings are changed in system screens outside the app, so re-check
    // whenever the user comes back.
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    try {
      final battery = await Native.isIgnoringBatteryOptimizations();
      final files = await Native.hasAllFilesAccess();
      if (!mounted) return;
      setState(() {
        _batteryExempt = battery;
        _filesAccess = files;
      });
    } on MissingPluginException {
      // Not on Android; leave the checklist hidden.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('PocketShare'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: 'Tunnel log',
            onPressed: () => _showLogs(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            _StatusCard(state: c.tunnelState, error: c.tunnelError),
            const SizedBox(height: 20),
            _AddressCard(hostname: c.hostname, live: c.isLive),
            const SizedBox(height: 12),
            _StorageCard(
              path: c.driveRootPath,
              survivesUninstall: c.storageSurvivesUninstall,
              onChange: () => _chooseStorage(context),
            ),
            const SizedBox(height: 20),

            if (!_batteryExempt || !_filesAccess) ...[
              Text('Needs attention', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
            ],

            if (!_filesAccess)
              _TaskTile(
                icon: Icons.folder_open,
                title: 'Allow access to all files',
                body: 'Without this the drive can only see its own folder, '
                    'not the rest of the card.',
                action: 'Open settings',
                onPressed: () async {
                  await Native.requestAllFilesAccess();
                },
              ),

            if (!_batteryExempt)
              _TaskTile(
                icon: Icons.battery_alert,
                title: 'Stop Android from sleeping the drive',
                body: 'Battery optimisation will kill the connection after a '
                    'while, and the address stops working.',
                action: 'Allow',
                onPressed: () async {
                  await Native.requestIgnoreBatteryOptimizations();
                },
              ),

            if (!c.autostartAcknowledged)
              _TaskTile(
                icon: Icons.restart_alt,
                title: 'Allow autostart',
                body: 'Xiaomi, Oppo, Vivo and Huawei phones block apps from '
                    'restarting themselves. Android gives no way to check this '
                    'setting, so tell me once you have turned it on.',
                action: 'Open autostart',
                onPressed: () async {
                  final opened = await Native.openAutostartSettings();
                  if (!context.mounted) return;
                  if (!opened) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('This phone has no autostart screen.'),
                      ),
                    );
                  }
                },
                secondaryAction: 'Already done',
                onSecondaryPressed: c.markAutostartDone,
              ),

            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Change the login'),
                subtitle: Text(
                  c.username == null
                      ? 'Set the username and password for the browser.'
                      : 'Signed in as ${c.username}. Forgot the password? '
                          'Set a new one here.',
                ),
                onTap: () => _changeLogin(context),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: c.isLive ? c.stopDrive : c.startDrive,
              icon: Icon(c.isLive ? Icons.stop : Icons.play_arrow),
              label: Text(c.isLive ? 'Stop the drive' : 'Start the drive'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseStorage(BuildContext context) async {
    final c = widget.controller;

    // Anywhere outside the app's own folder needs all-files access, and the
    // grant happens in a system screen we cannot complete on the user's
    // behalf.
    if (!await Native.hasAllFilesAccess()) {
      if (!context.mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Allow access to all files'),
          content: const Text(
            'To keep your files in a normal folder — one that survives '
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

      if (proceed != true) return;
      await Native.requestAllFilesAccess();
      return; // The user returns via the lifecycle callback and taps again.
    }

    final volumes = await c.storageVolumes();
    if (!context.mounted) return;

    final chosen = await showDialog<StorageVolume>(
      context: context,
      builder: (_) => _StoragePickerDialog(
        volumes: volumes,
        currentPath: c.driveRootPath,
      ),
    );
    if (chosen == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Moving your files…')),
    );

    try {
      final moved = await c.changeStorage(chosen);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            moved == 0
                ? 'Storage moved to ${chosen.drivePath}'
                : 'Moved $moved file(s) to ${chosen.drivePath}',
          ),
        ),
      );
    } on FileSystemException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not move the files: ${e.message}')),
      );
    }
  }

  Future<void> _changeLogin(BuildContext context) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangeLoginDialog(controller: widget.controller),
    );

    if (changed == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Login updated. Everyone signed in has been signed out.'),
        ),
      );
    }
  }

  void _showLogs(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollController) {
          final lines = widget.controller.tunnelLogs;
          return ListView.builder(
            controller: scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: lines.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Tunnel log',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText(
                  lines[i - 1],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, this.error});

  final TunnelState state;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, detail, color, busy) = switch (state) {
      // An error reported while stopped is still an error: showing the
      // generic line here would hide the only clue the user has.
      TunnelState.stopped => (
          error == null ? 'Stopped' : 'Could not start',
          error ?? 'The drive is not reachable.',
          error == null ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.error,
          false
        ),
      TunnelState.starting => ('Starting', 'Launching the connection…',
          theme.colorScheme.primary, true),
      TunnelState.registered => ('Connecting', 'Connected to Cloudflare.',
          theme.colorScheme.primary, true),
      // Named honestly: the tunnel is up and we are waiting on the edge, which
      // is exactly the state the old app misreported as a hard failure.
      TunnelState.verifying => (
          'Checking the address',
          'Waiting for the address to start answering. This takes a few '
              'seconds the first time.',
          theme.colorScheme.primary,
          true
        ),
      TunnelState.live => ('Live', 'Your drive is reachable.',
          Colors.green.shade600, false),
      TunnelState.failed => ('Not reachable',
          error ?? 'Something went wrong.', theme.colorScheme.error, false),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: busy
                  ? CircularProgressIndicator(strokeWidth: 2.5, color: color)
                  : Icon(Icons.circle, size: 14, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(detail, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.hostname, required this.live});

  final String hostname;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your address', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SelectableText(
              hostname,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: live ? null : theme.disabledColor,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: 'https://$hostname'),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onPressed,
    this.secondaryAction,
    this.onSecondaryPressed,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onPressed;

  /// For steps the app cannot verify, so the user can mark them handled.
  final String? secondaryAction;
  final VoidCallback? onSecondaryPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton(onPressed: onPressed, child: Text(action)),
                      if (secondaryAction != null)
                        TextButton(
                          onPressed: onSecondaryPressed,
                          child: Text(secondaryAction!),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sets a new username and password for the browser login.
///
/// This is the only password reset there is. The drive has no email address
/// and no second factor, so any web-reachable recovery flow would just be a
/// way around the password; holding the phone is the credential.
class _ChangeLoginDialog extends StatefulWidget {
  const _ChangeLoginDialog({required this.controller});

  final DriveController controller;

  @override
  State<_ChangeLoginDialog> createState() => _ChangeLoginDialogState();
}

class _ChangeLoginDialogState extends State<_ChangeLoginDialog> {
  late final TextEditingController _username =
      TextEditingController(text: widget.controller.username ?? '');
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final ok = await widget.controller.resetLogin(
      username: _username.text.trim(),
      password: _password.text,
    );

    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = widget.controller.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change the login'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Anyone currently signed in on a browser will be signed out.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _username,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'New password',
                helperText: 'At least 10 characters.',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: 'New password again',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// Shows where the drive keeps its files, and warns when that location would
/// not survive uninstalling the app.
class _StorageCard extends StatelessWidget {
  const _StorageCard({
    required this.path,
    required this.survivesUninstall,
    required this.onChange,
  });

  final String? path;
  final bool survivesUninstall;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Files are kept in', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SelectableText(
              path ?? 'Working it out…',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
            if (path != null && !survivesUninstall) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This folder belongs to the app. Uninstalling '
                      'PocketShare deletes everything in it, and the phone\'s '
                      'Files app cannot open it. Move it somewhere permanent.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            TextButton(
              onPressed: onChange,
              child: Text(survivesUninstall ? 'Change folder' : 'Move files'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lets the user pick which storage volume holds the drive.
class _StoragePickerDialog extends StatelessWidget {
  const _StoragePickerDialog({required this.volumes, required this.currentPath});

  final List<StorageVolume> volumes;
  final String? currentPath;

  static String _humanSize(int bytes) {
    if (bytes <= 0) return 'unknown size';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Where should files go?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A "${DriveLocation.folderName}" folder is created on whichever '
            'you pick. Anything already stored moves across.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final volume in volumes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(volume.removable ? Icons.sd_card : Icons.smartphone),
              title: Text(volume.label),
              subtitle: Text(
                '${_humanSize(volume.freeBytes)} free of '
                '${_humanSize(volume.totalBytes)}\n${volume.drivePath}',
                style: const TextStyle(fontSize: 11),
              ),
              isThreeLine: true,
              selected: currentPath == volume.drivePath,
              trailing: currentPath == volume.drivePath
                  ? const Icon(Icons.check)
                  : null,
              onTap: currentPath == volume.drivePath
                  ? null
                  : () => Navigator.of(context).pop(volume),
            ),
          if (volumes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No storage volumes found.'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
