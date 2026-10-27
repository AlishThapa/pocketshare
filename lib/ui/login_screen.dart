import 'package:flutter/material.dart';

import '../state/drive_controller.dart';

/// Step two: the credentials that guard the drive.
///
/// This password is the only thing between the public internet and every file
/// on the card, so the rules here are deliberately stricter than a typical
/// app's.
class LoginSetupScreen extends StatefulWidget {
  const LoginSetupScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  State<LoginSetupScreen> createState() => _LoginSetupScreenState();
}

class _LoginSetupScreenState extends State<LoginSetupScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _problem {
    if (_password.text != _confirm.text) return 'Passwords do not match.';
    return DriveController.validateCredentials(_username.text, _password.text);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.controller.createLogin(
      username: _username.text.trim(),
      password: _password.text,
    );
    if (mounted && !ok) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _username.text.isNotEmpty &&
        _password.text.isNotEmpty &&
        _confirm.text.isNotEmpty &&
        _problem == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Set up PocketShare')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text('Create your login', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'You will use this to sign in at '
              '${widget.controller.hostname}.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _username,
              onChanged: (_) => setState(() {}),
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
                helperText: '3-32 characters: letters, digits, _ . -',
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _password,
              onChanged: (_) => setState(() {}),
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                helperText: 'At least 10 characters.',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _confirm,
              onChanged: (_) => setState(() {}),
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: 'Password again',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_username.text.isNotEmpty && _problem != null)
              Text(
                _problem!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: ready && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Start the drive'),
            ),
          ],
        ),
      ),
    );
  }
}
