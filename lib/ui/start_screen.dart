import 'package:flutter/material.dart';

import '../state/drive_controller.dart';

/// Screen one. The two audiences want completely different things, and asking
/// this first means someone who was handed a code never reads a word about
/// API tokens or domains.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  bool _looking = false;

  /// Asks the Worker whether this phone has a backup.
  ///
  /// Deliberately a button rather than something that happens on launch. A
  /// phone that never used this feature should not quietly contact a server
  /// the first time the app opens, even to be told no.
  Future<void> _restore() async {
    setState(() => _looking = true);
    final found = await widget.controller.findBackup();
    if (!mounted) return;
    setState(() => _looking = false);

    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No backup for this phone. A backup only works on the same phone '
            'it was made on, and only if it was switched on.',
          ),
        ),
      );
      return;
    }

    final when = DateTime.fromMillisecondsSinceEpoch(found.savedAt);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Backup found'),
        content: Text(
          'Restores ${found.hostname}, its login, and any invite codes, as '
          'saved on ${when.day}/${when.month}/${when.year}.\n\n'
          'Your Cloudflare token is not in the backup — you will be asked for '
          'it only if you make another address later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.controller.restoreFromBackup(found);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    return Scaffold(
      appBar: AppBar(title: const Text('Set up PocketShare')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Do you have an invite code?',
                  style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'This phone will serve its files at a web address. How it gets '
                'that address depends on whether someone shared PocketShare '
                'with you.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              _Choice(
                icon: Icons.confirmation_number_outlined,
                title: 'Yes, I have an invite code',
                body: 'Someone with a domain invited you. Enter their code and '
                    'pick a name — you will not need a Cloudflare account.',
                primary: true,
                onPressed: controller.choosePathInvite,
              ),
              const SizedBox(height: 12),
              _Choice(
                icon: Icons.cloud_outlined,
                title: 'No, use my own domain',
                body: 'You have a domain on Cloudflare. Connect it once, then '
                    'this phone can make addresses on it — for itself and for '
                    'anyone you invite.',
                primary: false,
                onPressed: controller.choosePathCloudflare,
              ),
              if (controller.recoveryAvailable) ...[
                const SizedBox(height: 24),
                Center(
                  child: _looking
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : TextButton.icon(
                          onPressed: _restore,
                          icon: const Icon(Icons.restore, size: 18),
                          label: const Text('I had PocketShare on this phone'),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.body,
    required this.primary,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool primary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: primary ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  color: primary
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: primary
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface,
                        )),
                    const SizedBox(height: 6),
                    Text(body,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: primary
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
