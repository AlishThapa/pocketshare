/// Rules for a subdomain label, shared by the host and guest paths so both
/// refuse the same names. Pure, so it can be tested without a network.
class DriveName {
  DriveName._();

  /// Names that would shadow real infrastructure on the apex domain, or take
  /// down something the owner depends on.
  static const reserved = <String>{
    'www', 'api', 'mail', 'smtp', 'imap', 'pop', 'ns', 'ns1', 'ns2', 'mx',
    'admin', 'root', 'cpanel', 'webmail', 'ftp', 'cdn', 'static', 'assets',
    'blog', 'shop', 'store', 'app', 'dev', 'test', 'staging', 'status',
    'dashboard', 'login', 'auth', 'account', 'billing', 'support', 'help',
    'docs', 'git', 'vpn', 'proxy', 'tunnel', 'pocketshare', 'files',
    'provision',
  };

  /// One DNS label: 3-32 characters, lowercase alphanumerics and inner
  /// hyphens. One label deep keeps it inside Universal SSL's wildcard, which
  /// covers `*.example.com` but not `*.*.example.com`.
  static final _pattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$');

  /// Null when the name is usable, otherwise a reason fit to show the user.
  static String? problem(String raw) {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) return 'pick a name';
    if (name.length < 3) return 'at least 3 characters';
    if (name.length > 32) return 'at most 32 characters';
    if (name.startsWith('-') || name.endsWith('-')) {
      return 'cannot start or end with a hyphen';
    }
    if (!_pattern.hasMatch(name)) {
      return 'letters, digits and hyphens only';
    }
    if (reserved.contains(name)) return 'that name is reserved';
    return null;
  }

  static bool isValid(String raw) => problem(raw) == null;

  static String normalize(String raw) => raw.trim().toLowerCase();

  /// The tunnel is named after the drive so the Cloudflare dashboard stays
  /// readable, and prefixed so it is obvious which app made it.
  static String tunnelName(String name) => 'ps-${normalize(name)}';
}
