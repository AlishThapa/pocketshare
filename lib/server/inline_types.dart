/// Which content types this drive is willing to name, and therefore to let a
/// browser render.
///
/// The threat is a file someone uploaded being served back inside the drive's
/// own origin. Today only the owner uploads, so it is theoretical; a share
/// link makes it real, and the fix belongs in place before the feature that
/// needs it.
///
/// Content-Disposition is not that fix. It decides what a *navigation* does
/// and is ignored entirely for subresource loads, so
/// `<script src="/api/download?path=evil.js">` runs on the strength of the
/// MIME type alone, attachment or not. The type is the thing browsers
/// actually enforce on — with `X-Content-Type-Options: nosniff`, a response
/// typed `application/octet-stream` is neither executed as script nor applied
/// as a stylesheet nor rendered as a document.
///
/// So the allowlist is what a file is allowed to *be*. Anything outside it is
/// served as `application/octet-stream` whatever its extension claims, which
/// is exactly what a download wants anyway.
class InlineTypes {
  InlineTypes._();

  static const fallback = 'application/octet-stream';

  /// Whole types that are safe to render: they carry no executable content
  /// that reaches the page around them.
  static const _exact = {'application/pdf', 'text/plain'};

  /// Families where every member is inert.
  static const _families = ['image/', 'video/', 'audio/'];

  /// SVG is an image by MIME type and a document by behaviour: it can carry
  /// `<script>`, and served from this origin that script runs as the signed-in
  /// owner. It is the single exception the family rule above would otherwise
  /// swallow, which is why it is named rather than left to be noticed later.
  static const _denied = {'image/svg+xml', 'image/svg'};

  /// Whether [type] may be rendered by the browser rather than downloaded.
  static bool allows(String? type) {
    final t = _normalize(type);
    if (t.isEmpty || _denied.contains(t)) return false;
    if (_exact.contains(t)) return true;
    return _families.any(t.startsWith);
  }

  /// The type to actually send for a file whose extension suggests [type].
  ///
  /// Deliberately applied to every response, not only inline ones: a
  /// subresource load ignores the disposition, so a file that may not be
  /// rendered must not be named something a browser knows how to run.
  static String served(String? type) =>
      allows(type) ? _normalize(type) : fallback;

  static String _normalize(String? type) =>
      (type ?? '').split(';').first.trim().toLowerCase();
}
