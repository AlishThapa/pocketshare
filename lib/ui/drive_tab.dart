import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native.dart';
import '../state/drive_controller.dart';
import '../tunnel/cloudflared.dart';
import 'invite_card.dart';
import 'widgets.dart';

/// Everything about the drive itself: whether it is up, what its address is,
/// who can be invited, and the login that guards it.
class DriveTab extends StatefulWidget {
  const DriveTab({super.key, required this.controller});

  final DriveController controller;

  @override
  State<DriveTab> createState() => _DriveTabState();
}

class _DriveTabState extends State<DriveTab> with WidgetsBindingObserver {
  bool _batteryExempt = true;
  bool _filesAccess = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
    widget.controller.refreshInvites();
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

  bool get _needsAttention =>
      !_batteryExempt ||
      !_filesAccess ||
      (widget.controller.hasAutostartScreen &&
          !widget.controller.autostartAcknowledged);

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _AddressPanel(
          hostname: c.hostname,
          state: c.tunnelState,
          error: c.tunnelError,
        ),

        if (_needsAttention) ...[
          const SectionLabel('Needs attention'),
          ..._attentionTiles(),
        ],

        if (c.isHost) ...[
          const SectionLabel('Invite'),
          InviteCard(controller: c),
        ],

        const SectionLabel('Drive'),
        PanelList(
          children: [
            PanelTile(
              icon: Icons.key_rounded,
              title: 'The login',
              subtitle: c.username == null
                  ? 'Set a username and password for the browser.'
                  : 'Signed in as ${c.username}',
              onTap: () => _changeLogin(context),
            ),
            if (c.recoveryAvailable)
              PanelTile(
                icon: Icons.settings_backup_restore_rounded,
                title: 'Survive a reinstall',
                subtitle: c.recoveryEnabled
                    ? 'On. This phone can restore its address, login and '
                        'invite codes after a reinstall.'
                    : 'Off. Reinstalling means setting the drive up again.',
                trailing: Switch(
                  value: c.recoveryEnabled,
                  onChanged: (on) => _setRecovery(context, on),
                ),
                onTap: () => _setRecovery(context, !c.recoveryEnabled),
              ),
            PanelTile(
              icon: Icons.receipt_long_rounded,
              title: 'Connection log',
              subtitle: 'What the tunnel reported, line by line.',
              onTap: () => _showLogs(context),
            ),
            PanelTile(
              icon: c.isLive ? Icons.stop_rounded : Icons.play_arrow_rounded,
              title: c.isLive ? 'Stop the drive' : 'Start the drive',
              subtitle: c.isLive
                  ? 'Your address stops answering until you start it again.'
                  : 'Bring the address back up.',
              danger: c.isLive,
              trailing: c.isBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const SizedBox.shrink(),
              onTap: c.isBusy
                  ? null
                  : () => c.isLive ? c.stopDrive() : c.startDrive(),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _attentionTiles() {
    final c = widget.controller;
    return [
      if (!_filesAccess)
        _TaskTile(
          icon: Icons.folder_open,
          title: 'Allow access to all files',
          body: 'Without this the drive can only see its own folder, not the '
              'rest of the card.',
          action: 'Open settings',
          onPressed: () async {
            await Native.requestAllFilesAccess();
          },
        ),
      if (!_batteryExempt)
        _TaskTile(
          icon: Icons.battery_alert,
          title: 'Stop Android from sleeping the drive',
          body: 'Battery optimisation will kill the connection after a while, '
              'and the address stops working.',
          action: 'Allow',
          onPressed: () async {
            await Native.requestIgnoreBatteryOptimizations();
          },
        ),
      // Gated on the phone actually having the screen: on a Samsung or Pixel
      // this named four other vendors and the button could only report that
      // no such screen exists.
      if (c.hasAutostartScreen && !c.autostartAcknowledged)
        _TaskTile(
          icon: Icons.restart_alt,
          title: 'Allow autostart',
          body: 'This phone blocks apps from restarting themselves. Android '
              'gives no way to check the setting, so tell me once you have '
              'turned it on.',
          action: 'Open autostart',
          onPressed: () async {
            final opened = await Native.openAutostartSettings();
            if (!mounted) return;
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
    ];
  }

  Future<void> _changeLogin(BuildContext context) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangeLoginDialog(controller: widget.controller),
    );

    if (changed == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Login updated. Everyone signed in has been signed out.'),
        ),
      );
    }
  }

  /// Turning this on is the only moment in the app where a credential leaves
  /// the phone, so it asks first and says exactly what goes and what does not.
  Future<void> _setRecovery(BuildContext context, bool on) async {
    final c = widget.controller;
    final messenger = ScaffoldMessenger.of(context);

    if (!on) {
      await c.setRecoveryBackup(false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Backup deleted. Reinstalling will mean setting the '
              'drive up again.'),
        ),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Survive a reinstall'),
        content: const Text(
          'Keeps an encrypted copy of your address, your login and your '
          'invite codes, so this phone can pick them up again after a '
          'reinstall.\n\n'
          'It is locked with a key derived from this phone, which is never '
          'sent — so the service holding it cannot read it, and neither can '
          'anyone else. Your Cloudflare token is not included at all.\n\n'
          'It only works on this phone. After a factory reset or on a new '
          'handset, the backup is gone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn it on'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await c.setRecoveryBackup(true);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Backed up. This phone can restore itself after a '
            'reinstall.'),
      ),
    );
  }

  void _showLogs(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollController) {
          final lines = widget.controller.tunnelLogs;
          return ListView.builder(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemCount: lines.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text('Connection log',
                      style: Theme.of(context).textTheme.titleMedium),
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

/// Status and address in one piece.
///
/// They were two cards, which asked the user to read a green dot in one and
/// a hostname in the other and join them up. The address is the thing people
/// come to this screen for, so it is the thing the screen leads with, and the
/// status is what colours it.
class _AddressPanel extends StatelessWidget {
  const _AddressPanel({
    required this.hostname,
    required this.state,
    required this.error,
  });

  final String hostname;
  final TunnelState state;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (label, detail, color, busy) = switch (state) {
      // An error reported while stopped is still an error: showing the
      // generic line here would hide the only clue the user has.
      TunnelState.stopped => (
          error == null ? 'Stopped' : 'Could not start',
          error ?? 'The drive is not answering.',
          error == null ? scheme.onSurfaceVariant : scheme.error,
          false,
        ),
      TunnelState.starting =>
        ('Starting', 'Launching the connection…', scheme.primary, true),
      TunnelState.registered =>
        ('Connecting', 'Connected to Cloudflare.', scheme.primary, true),
      // Named honestly: the tunnel is up and we are waiting on the edge,
      // which is exactly the state the old app misreported as a failure.
      TunnelState.verifying => (
          'Checking the address',
          'Waiting for the address to start answering. This takes a few '
              'seconds the first time.',
          scheme.primary,
          true,
        ),
      TunnelState.live => (
          'Live',
          'Anyone with the address and the login can reach your files.',
          const Color(0xFF2E7D32),
          false,
        ),
      TunnelState.failed =>
        ('Not reachable', error ?? 'Something went wrong.', scheme.error, false),
    };

    final live = state == TunnelState.live;

    return Panel(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: busy
                    ? CircularProgressIndicator(strokeWidth: 2, color: color)
                    : Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                          boxShadow: live
                              ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.35),
                                    blurRadius: 10,
                                    spreadRadius: 3,
                                  ),
                                ]
                              : null,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SelectableText(
            hostname.isEmpty ? 'No address yet' : hostname,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: live ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (hostname.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _share(context),
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: 'https://$hostname'));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address copied')),
    );
  }

  Future<void> _share(BuildContext context) async {
    // Only the address: the login is deliberately not in the shared text, so
    // forwarding the message does not forward the way in. Whoever gets this
    // still needs the password, handed over separately.
    final shared = await Native.shareText(
      'https://$hostname',
      subject: 'My PocketShare drive',
    );
    if (!context.mounted || shared) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nothing on this phone can share text.')),
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
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        color: scheme.tertiaryContainer.withValues(alpha: 0.45),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.onTertiaryContainer),
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
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
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
                  icon:
                      Icon(_obscure ? Icons.visibility : Icons.visibility_off),
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
