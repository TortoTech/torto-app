import 'package:flutter/services.dart';

const formulaImageSchema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['results'],
  'properties': {
    'results': {
      'type': 'array',
      'description':
          'Exactly one result per requested image ID, including negative results. Use this array even for a single image. No missing, duplicate or additional IDs; array order is irrelevant.',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['image_id', 'status', 'latex', 'equation_number'],
        'properties': {
          'image_id': {
            'type': 'integer',
            'description':
                'An ID from requested_ids. Preserve its original value; IDs can be nonconsecutive. Never invent an ID.',
          },
          'status': {
            'type': 'string',
            'enum': ['recognized', 'not_formula', 'unreadable'],
            'description':
                'recognized: the entire meaningful image is faithfully representable as math, a symbol or a formal production rule. not_formula: a diagram, plot, table, photo, decorative art or prose, even if it contains equations. unreadable: a formula with ambiguous essential details or unsupported notation. Both latex and equation_number must be null for either negative status.',
          },
          'latex': {
            'type': ['string', 'null'],
            'description':
                r'Faithful LaTeX source without dollar delimiters or Markdown; null for a negative status. Use supported standard math commands, text operators and matrix/aligned environments; no custom macros, packages, images, URLs or executable commands. JSON-escape every literal backslash: two in the JSON source for one LaTeX backslash, four for a two-backslash row separator. Decoding must preserve command backslashes and row separators, never produce backspace, form feed, newline, carriage return or tab from a command prefix. Do not remove backslashes to make JSON valid.',
          },
          'equation_number': {
            'type': ['string', 'null'],
            'description':
                'Separate equation number visibly printed inside this image; exclude it from latex. Never copy or infer a number from adjacent HTML or context. Null when absent or for a negative status.',
          },
        },
      },
    },
  },
};

Future<({String transcribe, String verify})> formulaImagePrompts() async {
  final base = await rootBundle.loadString('assets/ai/formula_images.md');
  return (
    transcribe:
        '$base\n${await rootBundle.loadString('assets/ai/formula_transcribe.md')}',
    verify:
        '$base\n${await rootBundle.loadString('assets/ai/formula_verify.md')}',
  );
}
