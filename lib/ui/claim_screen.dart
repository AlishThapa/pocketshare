import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/drive_controller.dart';
import '../tunnel/provision.dart';
import 'widgets.dart';

/// Step one for a guest: redeem an invite code, then pick a name on the
/// domain that code turns out to belong to.
///
/// The two are deliberately sequential rather than two fields on one form.
/// The domain is not the app's to show — it belongs to whoever did the
/// inviting — and a name means nothing until there is a domain to append it
/// to. So nothing about the address appears until a code has been checked.
class ClaimScreen extends StatefulWidget {
  const ClaimScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends State<ClaimScreen> {
  final _invite = TextEditingController();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();

  Timer? _debounce;

  /// Set once the Worker has accepted the code. Its presence is what unlocks
  /// the second half of the screen, so it is never filled speculatively.
  InviteCheck? _accepted;
  String? _inviteError;
  bool _verifying = false;

  NameCheck? _check;
  bool _checking = false;
  bool _claiming = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _invite.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  String get _code => _invite.text.trim().toUpperCase();

  Future<void> _verifyInvite() async {
    final code = _code;
    if (code.isEmpty) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _verifying = true;
      _inviteError = null;
    });

    final result = await widget.controller.checkInvite(code);
    if (!mounted) return;

    setState(() {
      _verifying = false;
      if (result.ok) {
        _accepted = result;
        _inviteError = null;
      } else {
        _accepted = null;
        _inviteError = result.reason ?? 'That code was not accepted.';
      }
    });

    // Land the cursor where the next decision is, so the revealed field does
    // not just sit there waiting to be noticed.
    if (result.ok && mounted) _nameFocus.requestFocus();
  }

  /// Back to a bare code field. Everything downstream depended on the code,
  /// so a different code invalidates all of it — including the name check,
  /// which was answered by that code's domain.
  void _changeCode() {
    _debounce?.cancel();
    setState(() {
      _accepted = null;
      _inviteError = null;
      _check = null;
      _checking = false;
      _name.clear();
    });
  }

  void _onNameChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _check = null;
      _checking = value.trim().length >= 3;
    });
    if (value.trim().length < 3) return;

    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final result = await widget.controller.checkName(
        value.trim().toLowerCase(),
        inviteCode: _code,
      );
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
      inviteCode: _code,
    );
    if (mounted && !ok) setState(() => _claiming = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accepted = _accepted;

    return Scaffold(
      appBar: AppBar(
        title: const Text('I have an invite code'),
        // Without this, Back quits the app from the first screen a user
        // reaches, with no way back to the path choice.
        leading: BackButton(onPressed: widget.controller.backToPathChoice),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text(
              accepted == null ? 'Enter your invite code' : 'Choose your name',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              accepted == null
                  ? 'The person who shared PocketShare with you has a code. '
                      'It decides which address this phone can take.'
                  : 'This becomes the web address you open to reach the files '
                      'on this phone.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            if (accepted == null) ..._codeStep(theme) else ..._nameStep(theme, accepted),
          ],
        ),
      ),
    );
  }

  // --- step one: the code ----------------------------------------------------

  List<Widget> _codeStep(ThemeData theme) => [
        TextField(
          controller: _invite,
          // Unconditional: Continue is enabled by this field being non-empty,
          // so without a rebuild per keystroke the button stays dead.
          onChanged: (_) => setState(() => _inviteError = null),
          onSubmitted: (_) => _verifyInvite(),
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          inputFormatters: [UpperCaseFormatter()],
          decoration: InputDecoration(
            labelText: 'Invite code',
            hintText: 'ABC123',
            errorText: _inviteError,
            prefixIcon: const Icon(Icons.confirmation_number_outlined),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Codes are not case sensitive.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed:
              _verifying || _invite.text.trim().isEmpty ? null : _verifyInvite,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: _verifying
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
      ];

  // --- step two: the name ----------------------------------------------------

  List<Widget> _nameStep(ThemeData theme, InviteCheck accepted) {
    final scheme = theme.colorScheme;
    final domain = accepted.domain ?? '';
    final canClaim = !_claiming && (_check?.available ?? false);

    return [
      Panel(
        color: scheme.primaryContainer,
        child: Row(
          children: [
            Icon(Icons.check_circle, color: scheme.onPrimaryContainer, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Code $_code accepted',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (accepted.remaining != null)
                    Text(
                      accepted.remaining == 1
                          ? 'Last use of this code.'
                          : '${accepted.remaining} uses left.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onPrimaryContainer),
                    ),
                ],
              ),
            ),
            TextButton(onPressed: _changeCode, child: const Text('Change')),
          ],
        ),
      ),
      const SizedBox(height: 28),

      // The domain goes above the field it applies to, so the name is typed
      // with its ending already in view rather than discovered underneath.
      Text(
        'Your address will be on',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 4),
      Text(
        domain,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _name,
        focusNode: _nameFocus,
        onChanged: _onNameChanged,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        decoration: InputDecoration(
          labelText: 'Name',
          hintText: 'myfiles',
          suffixText: domain.isEmpty ? null : '.$domain',
          suffixStyle: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
          suffixIcon: _suffixIcon(),
        ),
      ),
      const SizedBox(height: 10),
      _statusLine(theme),
      if (widget.controller.errorMessage != null) ...[
        const SizedBox(height: 18),
        Text(
          widget.controller.errorMessage!,
          style: TextStyle(color: scheme.error),
        ),
      ],
      const SizedBox(height: 32),
      FilledButton(
        onPressed: canClaim ? _claim : null,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        child: _claiming
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Claim this address'),
      ),
    ];
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
      color: _check!.available
          ? Colors.green
          : Theme.of(context).colorScheme.error,
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
      style:
          theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
    );
  }
}

/// Uppercases as the user types, so the code on screen matches the code on
/// whatever they are reading it from. Keyboards ignore
/// [TextCapitalization.characters] often enough that it cannot be relied on.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
