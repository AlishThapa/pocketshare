import 'package:flutter/material.dart';

import '../state/drive_controller.dart';

/// Screen one. The two audiences want completely different things, and asking
/// this first means someone who was handed a code never reads a word about
/// API tokens or domains.
class StartScreen extends StatelessWidget {
  const StartScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
