import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../cloudflare/names.dart';
import '../state/drive_controller.dart';
import '../storage/token_format.dart';

/// Host path: paste an API token, pick a domain, pick a name.
///
/// The domain is a list rather than a field. Once the token is in, the app
/// knows exactly which domains it can reach, so a wrong-scope token fails
/// here instead of after a name has been chosen.
class ConnectCloudflareScreen extends StatefulWidget {
  const ConnectCloudflareScreen({super.key, required this.controller});

  final DriveController controller;

  @override
  State<ConnectCloudflareScreen> createState() =>
      _ConnectCloudflareScreenState();
}

class _ConnectCloudflareScreenState extends State<ConnectCloudflareScreen> {
  final _token = TextEditingController();
  final _name = TextEditingController();

  bool _obscured = true;
  bool _connecting = false;
  bool _creating = false;

  @override
  void dispose() {
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _connected => widget.controller.cfZones.isNotEmpty;

  Future<void> _connect() async {
    setState(() => _connecting = true);
    await widget.controller.connectCloudflare(_token.text);
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    final ok = await widget.controller.provisionAsHost(
      DriveName.normalize(_name.text),
    );
    if (mounted && !ok) setState(() => _creating = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    final nameProblem =
        _name.text.trim().isEmpty ? null : DriveName.problem(_name.text);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Use my own domain'),
        leading: BackButton(onPressed: c.backToPathChoice),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Connect Cloudflare', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'PocketShare needs an API token so it can create the address '
                'on your domain. The token is stored encrypted on this phone '
                'and never leaves it.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              const _TokenRecipe(),
              const SizedBox(height: 16),
              TextField(
                controller: _token,
                enabled: !_connected,
                obscureText: _obscured,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API token',
                  border: const OutlineInputBorder(),
                  helperText: _connected
                      ? 'Connected as ${TokenFormat.mask(_token.text)}'
                      : 'Hidden as you type. Stored encrypted, never shown again.',
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscured ? Icons.visibility : Icons.visibility_off),
                    tooltip: _obscured ? 'Show token' : 'Hide token',
                    onPressed: () => setState(() => _obscured = !_obscured),
                  ),
                ),
              ),
              if (!_connected) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _connecting || _token.text.trim().isEmpty
                      ? null
                      : _connect,
                  child: _connecting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Connect'),
                ),
              ],
              if (c.errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(c.errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (_connected) ...[
                const SizedBox(height: 28),
                Text('Choose your domain', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                ...c.cfZones.map(
                  (z) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: c.cfZone?.id == z.id
                        ? theme.colorScheme.primaryContainer
                        : null,
                    child: ListTile(
                      onTap: () => setState(() => c.chooseZone(z)),
                      leading: Icon(
                        c.cfZone?.id == z.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(z.name),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Choose your address', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Name',
                    border: const OutlineInputBorder(),
                    errorText: nameProblem,
                    helperText: 'Letters, digits and hyphens. '
                        'At least 3 characters.',
                  ),
                ),
                if (_name.text.trim().isNotEmpty &&
                    nameProblem == null &&
                    c.cfZone != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${DriveName.normalize(_name.text)}.${c.cfZone!.name}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _creating ||
                          c.cfZone == null ||
                          nameProblem != null ||
                          _name.text.trim().isEmpty
                      ? null
                      : _create,
                  child: _creating
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Create my address'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// How to create the token.
///
/// This is the step people get wrong, so it is laid out as numbered actions
/// with the two permissions drawn the way Cloudflare's own form shows them —
/// scope, resource, level — rather than as a line of breadcrumbs to decode.
class _TokenRecipe extends StatefulWidget {
  const _TokenRecipe();

  @override
  State<_TokenRecipe> createState() => _TokenRecipeState();
}

class _TokenRecipeState extends State<_TokenRecipe> {
  static const _tokenPageUrl = 'dash.cloudflare.com/profile/api-tokens';

  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.key_outlined, size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('How to create the token',
                        style: theme.textTheme.titleSmall),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Step(
                    number: 1,
                    title: 'Open your Cloudflare token page',
                    child: _CopyRow(text: _tokenPageUrl),
                  ),
                  _Step(
                    number: 2,
                    title: 'Create Token',
                    body: 'Scroll past the templates and choose '
                        '"Create Custom Token".',
                  ),
                  _Step(
                    number: 3,
                    title: 'Add exactly these two permissions',
                    child: const Column(
                      children: [
                        _Permission(
                          scope: 'Account',
                          resource: 'Cloudflare Tunnel',
                          level: 'Edit',
                        ),
                        SizedBox(height: 8),
                        _Permission(
                          scope: 'Zone',
                          resource: 'DNS',
                          level: 'Edit',
                          note: 'Zone Resources: your domain only',
                        ),
                      ],
                    ),
                  ),
                  _Step(
                    number: 4,
                    title: 'Continue, create, then copy the token',
                    body: 'Cloudflare shows it once. Type it below.',
                    last: true,
                  ),
                  const SizedBox(height: 4),
                  _Warning(
                    text: 'Not the long eyJ… string from "install a '
                        'connector". That one only runs a tunnel that already '
                        'exists — it cannot create an address.',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A numbered step with a connecting rail, so the sequence reads as a
/// sequence instead of four similar paragraphs.
class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    this.body,
    this.child,
    this.last = false,
  });

  final int number;
  final String title;
  final String? body;
  final Widget? child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text('$number',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
                    )),
              ),
              if (!last)
                Expanded(
                  child: Container(width: 2, color: scheme.outlineVariant),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  if (body != null) ...[
                    const SizedBox(height: 4),
                    Text(body!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                  if (child != null) ...[
                    const SizedBox(height: 10),
                    child!,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One permission row, drawn as Cloudflare's own three dropdowns read:
/// scope, resource, level.
class _Permission extends StatelessWidget {
  const _Permission({
    required this.scope,
    required this.resource,
    required this.level,
    this.note,
  });

  final String scope;
  final String resource;
  final String level;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(scope.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.8,
                  )),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(level,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    )),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(resource,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurface)),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: 'Copy link',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: 'https://$text'));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}
