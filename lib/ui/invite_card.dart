import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../invites/invite_store.dart';
import '../state/drive_controller.dart';

/// Invite codes, shown only on a host.
///
/// A guest device holds no Cloudflare token, so it cannot create a tunnel or
/// a DNS record for anyone. Showing it this card would offer a code nobody
/// could redeem.
class InviteCard extends StatelessWidget {
  const InviteCard({super.key, required this.controller});

  final DriveController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (!c.isHost) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hostname = c.inviteHostname;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_add_alt, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Invite someone',
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'They install PocketShare, paste the code, and get their own '
              'address on your domain. Their files stay on their phone.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (c.invites.isEmpty)
              Text('No codes yet.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant))
            else
              ...c.invites.map((invite) => _InviteRow(
                    invite: invite,
                    hostname: hostname,
                    onRevoke: () => c.revokeInvite(invite.code),
                    onRemove: () => c.removeInvite(invite.code),
                  )),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New code'),
                onPressed: () => _newCode(context, c),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newCode(BuildContext context, DriveController c) async {
    final made = await showDialog<Invite>(
      context: context,
      builder: (_) => _NewCodeDialog(controller: c),
    );
    if (made == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Created ${made.code}')),
    );
  }
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({
    required this.invite,
    required this.hostname,
    required this.onRevoke,
    required this.onRemove,
  });

  final Invite invite;
  final String? hostname;
  final VoidCallback onRevoke;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dead = !invite.usable;

    final status = invite.revoked
        ? 'cancelled'
        : invite.exhausted
            ? 'used up'
            : '${invite.remaining} of ${invite.maxUses} left';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: dead ? scheme.surfaceContainerHighest : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invite.code,
                  style: theme.textTheme.titleMedium?.copyWith(
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    decoration: dead ? TextDecoration.lineThrough : null,
                    color: dead ? scheme.onSurfaceVariant : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  invite.label.isEmpty ? status : '${invite.label} · $status',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!dead && hostname != null)
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 20),
              tooltip: 'Copy invite',
              onPressed: () async {
                // The host address goes on the clipboard with the code, so
                // the guest pastes one thing and types none of it.
                await Clipboard.setData(
                  ClipboardData(text: invite.shareString(hostname!)),
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite copied')),
                );
              },
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) =>
                value == 'revoke' ? onRevoke() : onRemove(),
            itemBuilder: (_) => [
              if (!dead)
                const PopupMenuItem(value: 'revoke', child: Text('Cancel code')),
              const PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

class _NewCodeDialog extends StatefulWidget {
  const _NewCodeDialog({required this.controller});

  final DriveController controller;

  @override
  State<_NewCodeDialog> createState() => _NewCodeDialogState();
}

class _NewCodeDialogState extends State<_NewCodeDialog> {
  final _label = TextEditingController();
  int _uses = 1;
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New invite code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _label,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Who is it for? (optional)',
              hintText: 'Kishan',
            ),
          ),
          const SizedBox(height: 20),
          Text('How many devices can use it?',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          // One per person is the safe default: a code can be forwarded, and
          // a single use limits what a forwarded one can do.
          Wrap(
            spacing: 8,
            children: [1, 2, 5, 10]
                .map((n) => ChoiceChip(
                      label: Text('$n'),
                      selected: _uses == n,
                      onSelected: (_) => setState(() => _uses = n),
                    ))
                .toList(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  final made = await widget.controller.createInvite(
                    label: _label.text.trim(),
                    maxUses: _uses,
                  );
                  if (context.mounted) Navigator.of(context).pop(made);
                },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
