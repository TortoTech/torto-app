/// The desktop v0.6.2 semantic request contract, with role-specific guidance
/// selected per source window instead of sending unused instructions/examples.
Map<String, dynamic> semanticSchema(Set<String> kinds) {
  const integer = {'type': 'integer'};
  const ids = {'type': 'array', 'items': integer};
  const alignment = {
    'type': ['string', 'null'],
    'enum': ['start', 'center', 'end', 'justify', null],
    'description':
        'Recommended quote-body alignment for unified typesetting; null retains normal reader behavior.',
  };
  Map<String, dynamic> item(String kind, Map<String, dynamic> fields) {
    final properties = {
      'kind': {
        'type': 'string',
        'enum': [kind],
      },
      ...fields,
    };
    return {
      'type': 'object',
      'additionalProperties': false,
      'properties': properties,
      'required': properties.keys.toList(),
    };
  }

  final groups = [
    for (final kind in ['quote', 'quote_before'])
      if (kinds.contains(kind))
        item(kind, {
          'body': ids,
          'attribution': {
            'type': 'integer',
            'description': kind == 'quote'
                ? 'Immediately following paragraph containing an explicit author or work credit. Required for every new quote.'
                : "Immediately preceding paragraph naming the source and explicitly introducing the excerpt with a colon or terminal reporting cue such as 'writes' or 'as follows'.",
          },
          'alignment': alignment,
        }),
    if (kinds.contains('quote_inline'))
      item('quote_inline', {
        'body': ids,
        'credit': {
          'type': 'string',
          'description':
              'Exact nonempty suffix of the last body paragraph, including its credit delimiter (dash, opening parenthesis or line break). Copy the explicitly written author/work credit; never invent it.',
        },
        'alignment': alignment,
      }),
    if (kinds.contains('quote_attribution'))
      item('quote_attribution', {
        'quote': integer,
        'attribution': {
          'type': ['integer', 'null'],
        },
        'body_index': {
          'type': ['integer', 'null'],
        },
      }),
    if (kinds.contains('figure'))
      item('figure', {'images': ids, 'captions': ids}),
    if (kinds.contains('section_heading'))
      item('section_heading', {'block': integer}),
  ];
  return {
    'type': 'object',
    'additionalProperties': false,
    'required': ['groups', 'citations', 'formulas'],
    'properties': {
      'groups': {
        'type': 'array',
        'items': groups.length == 1 ? groups.single : {'anyOf': groups},
      },
      'citations': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'formulas': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'block',
            'paragraph',
            'original',
            'latex',
            'before',
            'after',
          ],
          'properties': {
            'block': integer,
            'paragraph': integer,
            'original': {
              'type': 'string',
              'minLength': 1,
              'description':
                  'Nonempty exact contiguous substring of the designated math_texts paragraph, including markup and escaped entities. Select the complete expression or chained relation across style tags, including operands and attached superscripts/subscripts; never select an isolated exponent or subscript. Never rewrite it or supply offsets.',
            },
            'latex': {
              'type': 'string',
              'description':
                  'Faithful supported LaTeX, without dollar signs or Markdown. JSON-escape each literal command backslash as two backslashes, and a two-backslash row separator as four. Never simplify, solve, correct, or invent symbols.',
            },
            'before': {
              'type': 'string',
              'description':
                  'Exact immediately preceding text from math_texts to disambiguate repeated occurrences, or empty when unnecessary.',
            },
            'after': {
              'type': 'string',
              'description':
                  'Exact immediately following text from math_texts to disambiguate repeated occurrences, or empty when unnecessary.',
            },
          },
        },
      },
    },
  };
}

String semanticWindowPrompt(String full, Map<String, dynamic> input) {
  final targets = input['targets'] as Map;
  final sections = full.split('\n## ');
  return sections
      .where((part) {
        if (part.startsWith('Headings')) {
          return (targets['classify_headings'] as List).isNotEmpty;
        }
        if (part.startsWith('Quotations')) {
          return (targets['classify_blocks'] as List).isNotEmpty ||
              (targets['complete_quote_sources'] as List).isNotEmpty;
        }
        if (part.startsWith('Captions')) {
          return (input['blocks'] as List).any(
            (b) => b['type'] == 'image_needs_caption',
          );
        }
        if (part.startsWith('Inline citations')) {
          return (targets['classify_citations'] as List).isNotEmpty;
        }
        return true;
      })
      .join('\n## ');
}
