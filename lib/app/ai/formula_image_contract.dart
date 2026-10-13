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
        'required': [
          'image_id',
          'status',
          'latex',
          'equation_number',
          'text',
          'literal',
        ],
        'properties': {
          'image_id': {
            'type': 'integer',
            'description':
                'An ID from requested_ids. Preserve its original value; IDs can be nonconsecutive. Never invent an ID.',
          },
          'status': {
            'type': 'string',
            'enum': [
              'recognized',
              'not_formula',
              'unreadable',
              'recognized_text',
              'unreadable_text',
            ],
            'description':
                'recognized: the entire meaningful image is faithfully representable as math, a symbol or a formal production rule. recognized_text: the entire meaningful image is plain Unicode text, including character and script examples. unreadable_text: a text image with ambiguous essential glyphs. not_formula: a diagram, plot, table, photo or decorative art, even if it contains equations. unreadable: a formula with ambiguous essential details or unsupported notation. Both latex and equation_number must be null unless status is recognized.',
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
          'text': {
            'type': ['string', 'null'],
            'description':
                'Exact faithful Unicode for recognized_text, preserving glyphs, accents, meaningful spaces and line breaks. Null for every other status.',
          },
          'literal': {
            'type': 'boolean',
            'description':
                'True only for character or script examples that must remain untranslated; false for ordinary words/prose and non-text results.',
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
    verify: '',
  );
}
