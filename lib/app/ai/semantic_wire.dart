/// Transport-only mapping; book text, IDs and persisted domain values stay exact.
class SemanticWire {
  static dynamic encode(dynamic value) => convert(value);
  static dynamic decode(dynamic value) => convert(value, decode: true);
  static const version = 'desktop-wire-1';
  static const fields = <String, String>{
    "groups": "g",
    "citations": "c",
    "formulas": "f",
    "kind": "k",
    "block": "b",
    "paragraph": "p",
    "original": "o",
    "latex": "l",
    "before": "s",
    "after": "e",
    "blocks": "bs",
    "id": "i",
    "text": "t",
    "type": "ty",
    "body": "d",
    "attribution": "a",
    "alignment": "al",
    "images": "im",
    "captions": "ca",
    "quote": "q",
    "body_index": "bi",
    "credit": "cr",
    "heading": "h",
    "alt": "at",
    "index": "ix",
    "style": "st",
    "math_texts": "mt",
    "citation_candidates": "cc",
    "citation_paragraphs": "cp",
    "attribution_eligible": "ae",
    "target_start": "ts",
    "target_end_exclusive": "te",
    "quotes_enabled": "qe",
    "captions_enabled": "ce",
    "headings_enabled": "he",
    "targets": "tg",
    "classify_headings": "ch",
    "classify_blocks": "cb",
    "complete_quote_sources": "cq",
    "classify_citations": "ci",
    "numbered_candidates": "nc",
    "results": "r",
    "image_id": "ii",
    "status": "ss",
    "equation_number": "n",
    "requested_ids": "ri",
    "metadata": "md",
    "next_image": "ni",
    "mode": "m",
    "retry": "rt",
    "inline": "in",
    "context": "cx",
    "proposal": "pr",
    "local_validation_error": "ve",
    "bold_ratio": "br",
    "italic_ratio": "ir",
    "relative_font_size": "fs",
    "align": "ag",
    "margin_before": "mb",
    "margin_after": "ma",
    "total": "tt",
    "items": "it",
    "number": "nu",
  };
  static const enums = <String, String>{
    "quote": "q",
    "quote_before": "qb",
    "quote_inline": "qi",
    "quote_attribution": "qa",
    "figure": "fg",
    "section_heading": "sh",
    "paragraph": "p",
    "image": "im",
    "boundary": "bd",
    "protected_boundary": "pb",
    "quote_missing_attribution": "qm",
    "attribution_candidate": "ac",
    "recognized": "ok",
    "not_formula": "no",
    "unreadable": "u",
    "original": "o",
    "transcribe": "tr",
    "verify": "v",
  };
  static const enumFields = {'kind', 'type', 'status', 'next_image', 'mode'};
  static String key(String value, bool decode) => decode
      ? fields.entries.where((e) => e.value == value).firstOrNull?.key ?? value
      : fields[value] ?? value;
  static String enumValue(String value, bool decode) => decode
      ? enums.entries.where((e) => e.value == value).firstOrNull?.key ?? value
      : enums[value] ?? value;
  static dynamic convert(dynamic value, {bool decode = false}) {
    if (value is List) {
      return value.map((v) => convert(v, decode: decode)).toList();
    }
    if (value is! Map) return value;
    final output = <String, dynamic>{};
    for (final entry in value.entries) {
      final name = entry.key as String,
          long = decode ? key(entry.key as String, true) : entry.key;
      final mapped = key(name, decode);
      if (output.containsKey(mapped)) {
        throw const FormatException('Duplicate compact JSON field');
      }
      output[mapped] = enumFields.contains(long) && entry.value is String
          ? enumValue(entry.value, decode)
          : convert(entry.value, decode: decode);
    }
    return output;
  }

  static Map<String, dynamic> schema(Map<String, dynamic> value) {
    dynamic visit(dynamic node) {
      if (node is List) return node.map(visit).toList();
      if (node is! Map) return node;
      return <String, dynamic>{
        for (final entry in node.entries)
          entry.key as String: switch (entry.key) {
            'properties' => <String, dynamic>{
              for (final p in (entry.value as Map).entries)
                key(p.key, false): property(p.key, p.value),
            },
            'required' => [
              for (final name in entry.value as List) key(name, false),
            ],
            'description' => prompt(entry.value as String),
            _ => visit(entry.value),
          },
      };
    }

    return visit(value) as Map<String, dynamic>;
  }

  static Map<String, dynamic> property(String name, dynamic value) {
    final result = schema(Map<String, dynamic>.from(value));
    if (enumFields.contains(name) && result['enum'] is List) {
      result['enum'] = [
        for (final v in result['enum']) v is String ? enumValue(v, false) : v,
      ];
    }
    result['description'] = '$name. ${result['description'] ?? ''}';
    return result;
  }

  static String prompt(String text) {
    var code = false;
    final out = StringBuffer();
    for (final part in text.split(RegExp(r'(?<=`)|(?=`)'))) {
      if (part == '`') {
        code = !code;
        out.write(part);
      } else {
        out.write(
          code
              ? part.replaceAllMapped(
                  RegExp(r'[A-Za-z0-9_]+'),
                  (m) => fields[m[0]] ?? enums[m[0]] ?? m[0]!,
                )
              : part,
        );
      }
    }
    return out.toString();
  }

  static String instructions(String text) =>
      '${prompt(text)}\nCompact JSON transport: use supplied schema and compact keys exclusively. Field meanings: ${fields.entries.map((e) => '${e.value}=${e.key}').join(', ')}. Enum meanings (only in k/ty/ss/ni/m): ${enums.entries.map((e) => '${e.value}=${e.key}').join(', ')}. Source strings, IDs and LaTeX remain exact.';
}
