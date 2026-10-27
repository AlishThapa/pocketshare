import 'dart:async';

import 'package:flutter/material.dart';

import '../state/drive_controller.dart';
import '../tunnel/provision.dart';

/// Step one: pick a name. This is the whole of what used to be "go to the
/// Cloudflare dashboard and create a tunnel".
class ClaimScreen extends StatefulWidget {
  const ClaimScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends State<ClaimScreen> {
  final _name = TextEditingController();
  final _invite = TextEditingController();

  Timer? _debounce;
  NameCheck? _check;
  bool _checking = false;
  bool _claiming = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _invite.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _check = null;
      _checking = value.trim().length >= 3;
    });
    if (value.trim().length < 3) return;

    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final result = await widget.controller.checkName(value.trim().toLowerCase());
      if (!mounted) return;
      setState(() {
        _check = result;
        _checking = false;
      });
    });
  }

  Future<void> _claim() async {
    setState(() => _claiming = true);
    final ok = await widget.controller.claimName(
      name: _name.text.trim().toLowerCase(),
      inviteCode: _invite.text.trim(),
    );
    if (mounted && !ok) setState(() => _claiming = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canClaim = !_claiming &&
        (_check?.available ?? false) &&
        _invite.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Set up PocketShare')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text('Choose your address', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'This is the web address you will open to reach the files on '
              'this phone.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _name,
              onChanged: _onNameChanged,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'kishanfiles',
                border: const OutlineInputBorder(),
                suffixIcon: _suffixIcon(),
              ),
            ),
            const SizedBox(height: 10),
            _statusLine(theme),
            const SizedBox(height: 24),
            TextField(
              controller: _invite,
              onChanged: (_) => setState(() {}),
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Invite code',
                border: OutlineInputBorder(),
                helperText: 'From whoever shared PocketShare with you.',
              ),
            ),
            if (widget.controller.errorMessage != null) ...[
              const SizedBox(height: 18),
              Text(
                widget.controller.errorMessage!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton(
              onPressed: canClaim ? _claim : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: _claiming
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Claim this address'),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _suffixIcon() {
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_check == null) return null;
    return Icon(
      _check!.available ? Icons.check_circle : Icons.cancel,
      color: _check!.available ? Colors.green : Theme.of(context).colorScheme.error,
    );
  }

  Widget _statusLine(ThemeData theme) {
    final check = _check;
    if (check == null) {
      return Text(
        'Letters, digits and hyphens. At least 3 characters.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    if (check.available) {
      return Text(
        '${check.hostname} is available',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.green.shade700,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Text(
      check.reason ?? 'That name is not available.',
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
    );
  }
}
