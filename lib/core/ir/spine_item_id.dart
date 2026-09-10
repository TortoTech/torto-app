/// Stable publication section identity. JSON uses the string verbatim.
/// Generated identities belong to formats without authored IDs, not to reader
/// navigation; EPUB always retains the manifest ID.
class SpineItemId {
  final String? _authored;
  final int? _generatedIndex;
  const SpineItemId(String value)
    : assert(value != ''),
      _authored = value,
      _generatedIndex = null;
  const SpineItemId.generated(int index)
    : assert(index >= 0),
      _authored = null,
      _generatedIndex = index;
  String get value => _authored ?? 'section-${_generatedIndex! + 1}';
  factory SpineItemId.fromJson(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('Invalid spine ID');
    }
    return SpineItemId(value);
  }
  String toJson() => value;
  @override
  bool operator ==(Object other) =>
      other is SpineItemId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}
