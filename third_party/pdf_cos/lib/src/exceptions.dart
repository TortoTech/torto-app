/// Error while parsing PDF syntax.
class CosParseException implements Exception {
  CosParseException(this.message, [this.offset]);

  final String message;

  /// Byte offset in the source where the error was detected, if known.
  final int? offset;

  @override
  String toString() => offset == null
      ? 'CosParseException: $message'
      : 'CosParseException at byte $offset: $message';
}

/// A stream uses a /Filter this library cannot decode yet.
class UnsupportedFilterException implements Exception {
  UnsupportedFilterException(this.filterName);

  final String filterName;

  @override
  String toString() => 'UnsupportedFilterException: $filterName';
}

/// The document is encrypted and the supplied password (often the empty
/// default) opens neither the user nor the owner door.
class CosPasswordException implements Exception {
  @override
  String toString() => 'CosPasswordException: password required or incorrect';
}

/// The document uses an encryption scheme this library cannot decrypt
/// (a non-standard security handler, or an unknown crypt filter method).
class UnsupportedEncryptionException implements Exception {
  UnsupportedEncryptionException(this.detail);

  final String detail;

  @override
  String toString() => 'UnsupportedEncryptionException: $detail';
}
