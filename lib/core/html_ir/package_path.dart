/// Package-internal path handling for publication containers.
///
/// All publication content is addressed by root-relative paths (relative to
/// the OPF package root's container root). These helpers resolve relative
/// hrefs, normalize `.` / `..` segments, and percent-decode for zip lookup.
library;

final RegExp _schemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// Whether [href] has a URI scheme (e.g. `http:`, `mailto:`) and is
/// therefore external to the package.
bool isExternalHref(String href) =>
    _schemePattern.hasMatch(href) && !href.startsWith('/');

/// Percent-decodes [path], returning the input unchanged when it contains
/// invalid percent escapes.
String safePercentDecode(String path) {
  try {
    return Uri.decodeComponent(path);
  } on ArgumentError {
    return path;
  }
}

/// Normalizes a root-relative path: resolves `.` and `..` segments, drops
/// empty segments and any leading `/`.
String normalizePackagePath(String path) {
  final out = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(segment);
  }
  return out.join('/');
}

/// Directory portion of a root-relative path (`OPS/text/ch1.xhtml` →
/// `OPS/text`); empty string for root-level paths.
String packageDirname(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// Resolves [href] against [baseDir] (the root-relative directory of the
/// referencing document) and returns the canonical package href: a
/// percent-decoded, normalized root-relative path, with any `#fragment`
/// preserved.
///
/// External hrefs (with a URI scheme) are returned unchanged.
String resolvePackageHref(String baseDir, String href) {
  var rest = href.trim();
  if (rest.isEmpty) return rest;
  if (isExternalHref(rest)) return rest;

  String? fragment;
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    fragment = rest.substring(hash + 1);
    rest = rest.substring(0, hash);
  }

  final joined = rest.startsWith('/')
      ? rest.substring(1)
      : (baseDir.isEmpty ? rest : '$baseDir/$rest');
  final path = normalizePackagePath(safePercentDecode(joined));
  if (fragment == null || fragment.isEmpty) return path;
  return '$path#${safePercentDecode(fragment)}';
}

/// Splits a package href into its path part and (optional) fragment.
(String, String?) splitPackageFragment(String href) {
  final hash = href.indexOf('#');
  if (hash < 0) return (href, null);
  return (href.substring(0, hash), href.substring(hash + 1));
}
