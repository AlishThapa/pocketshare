import 'package:flutter/material.dart';

/// Small caps label that separates one group of settings from the next.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The app's one surface shape.
///
/// A flat tinted panel rather than an elevated card: shadows at this density
/// turn a settings list into stripes, and the tint already separates the
/// panel from the page.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(20);

    return Material(
      color: color ?? scheme.surfaceContainerLow,
      borderRadius: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A row of settings, grouped into one panel with hairlines between them.
class PanelList extends StatelessWidget {
  const PanelList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];

    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          indent: 60,
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ));
      }
      rows.add(children[i]);
    }

    return Panel(
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// One row inside a [PanelList].
class PanelTile extends StatelessWidget {
  const PanelTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = danger ? scheme.error : scheme.primary;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 18, color: tint),
      ),
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
      trailing: trailing ??
          (onTap == null
              ? null
              : Icon(Icons.chevron_right,
                  size: 20, color: scheme.onSurfaceVariant)),
    );
  }
}
