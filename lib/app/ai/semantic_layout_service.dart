import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/ir/ir.dart';
import '../../core/ir/inline_content.dart';
import '../../core/semantic_layout/inline_semantics.dart';
import 'formula_image_service.dart';
import '../../core/semantic_layout/batching.dart';
import '../../core/semantic_layout/semantic_layout.dart';
import 'ai_models.dart';
import 'semantic_layout_contract.dart';
export 'semantic_layout_contract.dart'
    show semanticSchema, semanticWindowPrompt;
import 'openai_compatible_client.dart';

List<Map<String, dynamic>> _wireCitations(Section section) {
  final ordinals = <(int, int), int>{};
  return [
    for (final candidate in citationCandidates(section))
      (() {
        final block = candidate['block'] as int,
            paragraph = candidate['paragraph'] as int;
        final ordinal = ordinals.update(
          (block, paragraph),
          (value) => value + 1,
          ifAbsent: () => 0,
        );
        return {...candidate, 'wire_id': 'c${block}_${paragraph}_$ordinal'};
      })(),
  ];
}

Future<Map<String, dynamic>> _inputInWorker(Section section) => Isolate.run(
  () => {
    'blocks': semanticInput(section),
    'citations': _wireCitations(section),
    'math_texts': [
      for (final (b, block) in section.blocks.indexed)
        for (final (p, text) in blockTexts(block).indexed)
          if (text.source != null &&
              text.kind != TextBlockKind.heading &&
              text.kind != TextBlockKind.quoteAttribution)
            {'block': b, 'paragraph': p, 'text': mathText(text).text},
    ],
  },
);
Future<String> _fingerprintInWorker(List<Object?> identity) => Isolate.run(
  () => sha256.convert(utf8.encode(jsonEncode(identity))).toString(),
);

Map<String, dynamic> _targetBlock(
  Map<String, dynamic> block, {
  bool canonical = true,
}) => !canonical
    ? block
    : {
        for (final entry in block.entries)
          if (entry.key != 'text' &&
              entry.key != 'body' &&
              entry.key != 'heading_eligible')
            entry.key: entry.value,
        if (block.containsKey('text')) 'paragraph': 0,
        if (block['body'] is List)
          'body': [
            for (final part in block['body'])
              {
                'index': part['index'],
                'paragraph': part['index'],
                'attribution_eligible': part['attribution_eligible'],
              },
          ],
      };

/// A bounded source batch per request; cache entries survive viewport changes.
class SemanticLayoutService {
  final AiProviderConfig provider;
  final String model;
  final ReasoningEffort reasoningEffort;
  final OpenAiCompatibleClient client;
  final Directory? cacheDirectory;
  Future<Uint8List?> Function(String)? resource;
  Future<String?> Function(MathInline)? validateFormulaRender;
  bool _cancelled = false;
  bool imageInputUnavailable = false;
  SemanticLayoutService(
    this.provider,
    this.model, {
    OpenAiCompatibleClient? client,
    this.cacheDirectory,
    this.reasoningEffort = ReasoningEffort.defaultLevel,
  }) : client = client ?? OpenAiCompatibleClient();
  void cancel() {
    _cancelled = true;
    client.close();
  }

  void _check() {
    if (_cancelled) throw StateError('AI layout cancelled');
  }

  Future<List<SemanticGroup>> recognize(
    Section section,
    String bookId, {
    List<SemanticBatch>? batches,
  }) async {
    final prompt = await rootBundle.loadString('assets/ai/semantic_layout.md');
    final prepared = await _inputInWorker(section);
    final input = (prepared['blocks'] as List).cast<Map<String, dynamic>>();
    final root =
        cacheDirectory ??
        Directory(
          '${(await getApplicationCacheDirectory()).path}/semantic-layout-v4',
        );
    final prefix = await _fingerprintInWorker([
      'mobile-4',
      bookId,
      section.href,
      input,
      provider.id,
      provider.baseUrl,
      model,
      reasoningEffort.label,
      prompt,
      semanticSchema(const {
        'figure',
        'section_heading',
        'quote',
        'quote_before',
        'quote_inline',
        'quote_attribution',
      }),
    ]);
    _check();
    const kinds = {
      'figure',
      'section_heading',
      'quote',
      'quote_before',
      'quote_inline',
      'quote_attribution',
    };
    final groups = <SemanticGroup>[];
    for (final batch in batches ?? semanticBatches(section)) {
      _check();
      final imageGroups = <SemanticGroup>[];
      if (resource != null) {
        try {
          imageGroups.addAll(
            await recognizeFormulaImages(
              section: section,
              start: batch.start,
              end: batch.end,
              provider: provider,
              model: model,
              effort: reasoningEffort,
              client: client,
              cache: root,
              resource: resource!,
              check: _check,
              validateRender: validateFormulaRender,
            ),
          );
        } on Object catch (error) {
          _check(); /* Image-input failures do not suppress text semantics. */
          imageInputUnavailable = true;
          final http =
              RegExp(r'HTTP \d{3}').firstMatch(error.toString())?.group(0) ??
              '';
          debugPrint(
            'TortoFormula unavailable section=${section.spineIndex} type=${error.runtimeType} $http',
          );
        }
      }
      final protectedImages = imageGroups
          .map((g) => g['block'])
          .whereType<int>()
          .where((i) => section.blocks[i] is ImageBlock)
          .toSet();
      final citations = (prepared['citations'] as List)
          .cast<Map<String, dynamic>>()
          .where((c) => c['block'] >= batch.start && c['block'] < batch.end)
          .toList();
      final payload = {
        'blocks': [
          for (var i = batch.contextStart; i < batch.contextEnd; i++)
            {
              ...protectedImages.contains(i)
                  ? {'id': i, 'type': 'protected_boundary'}
                  : i >= batch.start && i < batch.end
                  ? _targetBlock(
                      input[i],
                      canonical: (prepared['math_texts'] as List).any(
                        (text) => text['block'] == i,
                      ),
                    )
                  : input[i],
              if (i >= batch.start && i < batch.end)
                'math_texts': [
                  for (final text in prepared['math_texts'])
                    if (text['block'] == i)
                      {'paragraph': text['paragraph'], 'text': text['text']},
                ],
              'citation_candidates': [
                for (final c in citations)
                  if (c['block'] == i)
                    {
                      'id': c['wire_id'],
                      'paragraph': c['paragraph'],
                      'text': c['text'],
                    },
              ],
            },
        ],
        'targets': {
          'classify_headings': [
            for (var i = batch.start; i < batch.end; i++)
              if (headingCandidate(section.blocks[i])) i,
          ],
          'classify_blocks': [
            for (var i = batch.start; i < batch.end; i++)
              if (paragraph(section.blocks[i])) i,
          ],
          'complete_quote_sources': [
            for (var i = batch.start; i < batch.end; i++)
              if (input[i]['type'] == 'quote_missing_attribution') i,
          ],
          'classify_citations': [for (final c in citations) c['wire_id']],
        },
        'target_start': batch.start,
        'target_end_exclusive': batch.end,
        'quotes_enabled': true,
        'captions_enabled': true,
        'headings_enabled': true,
      };
      if (section.blocks.sublist(batch.start, batch.end).any(numbered)) {
        final numbers = [
          for (var i = 0; i < section.blocks.length; i++)
            if (numbered(section.blocks[i])) i,
        ];
        final nearby = List<int>.of(numbers)
          ..sort(
            (a, b) =>
                (a - batch.start).abs().compareTo((b - batch.start).abs()),
          );
        final selected = nearby.take(8).toList()..sort();
        String excerpt(int i, bool tail) {
          final block = i >= 0 && i < section.blocks.length
              ? section.blocks[i]
              : null;
          final chars = block is TextBlock
              ? block.plainText.runes.toList()
              : <int>[];
          return String.fromCharCodes(
            tail
                ? chars.skip((chars.length - 100).clamp(0, chars.length))
                : chars.take(100),
          );
        }

        payload['numbered_candidates'] = {
          'total': numbers.length,
          'items': [
            for (final i in selected)
              {
                'id': i,
                'number': int.parse(
                  (section.blocks[i] as TextBlock).plainText.trim().replaceAll(
                    RegExp(r'[.)．）]$'),
                    '',
                  ),
                ),
                'before': excerpt(i - 1, true),
                'after': excerpt(i + 1, false),
              },
          ],
        };
      }
      final requestPrompt = semanticWindowPrompt(prompt, payload);
      final key = await _fingerprintInWorker([prefix, payload]);
      _check();
      final file = File('${root.path}/$key.json');
      List<SemanticGroup>? accepted;
      try {
        final raw = jsonDecode(await file.readAsString());
        _check();
        if (raw is List) {
          final checked = validateGroups(
            section,
            raw,
            start: batch.start,
            end: batch.end,
            kinds: kinds,
          );
          if (checked.length == raw.length) accepted = checked;
        }
      } on FileSystemException {
        /* Missing cache is harmless. */
      } on FormatException {
        /* Corrupt cache is recomputed. */
      }
      if (accepted == null) {
        for (var attempt = 0; attempt < 2; attempt++) {
          final response = await client.recognizeLayout(
            provider: provider,
            model: model,
            prompt: requestPrompt,
            maxTokens: 4096,
            reasoningEffort: reasoningEffort,
            schema: semanticSchema(kinds),
            input: {
              ...payload,
              if (attempt > 0)
                'validation_feedback':
                    'Use only eligible IDs entirely inside the target range, explicit quote sources and non-overlapping groups. Do not change source text.',
            },
          );
          _check();
          final raw = response['groups'];
          if (response.keys.any(
                (key) =>
                    !const {'groups', 'citations', 'formulas'}.contains(key),
              ) ||
              raw is! List ||
              (response['citations'] != null &&
                  response['citations'] is! List) ||
              (response['formulas'] != null && response['formulas'] is! List)) {
            if (attempt == 0) continue;
            throw const FormatException(
              'AI layout response does not match schema',
            );
          }
          final unique = <Map<String, dynamic>>[];
          final seen = <String>{};
          var malformed = false;
          for (final value in raw) {
            if (value is! Map<String, dynamic>) {
              malformed = true;
              continue;
            }
            final keys = value.keys.toList()..sort();
            final identity = jsonEncode({
              for (final key in keys) key: value[key],
            });
            if (!seen.add(identity)) continue;
            if (_redundant(section, value, batch)) continue;
            unique.add(value);
          }
          final valid = validateGroups(
            section,
            unique,
            start: batch.start,
            end: batch.end,
            kinds: kinds,
          );
          final invalid = malformed || valid.length != unique.length;
          if (invalid && attempt == 0) continue;
          if (invalid && valid.isEmpty) {
            throw const FormatException('Invalid AI layout groups');
          }
          accepted = valid;
          final inline = resolveInlineProposals(
            section,
            [
              for (final id in response['citations'] as List? ?? [])
                ...citations
                    .where((c) => c['wire_id'] == id || c['id'] == id)
                    .map((c) => c['id'] as int),
            ],
            response['formulas'] as List? ?? [],
            batch.start,
            batch.end,
          );
          for (final annotation in inline) {
            if (annotation['kind'] == 'text_formula' &&
                validateFormulaRender != null &&
                await validateFormulaRender!(
                      MathInline(annotation['latex'] as String),
                    ) !=
                    null) {
              continue;
            }
            _check();
            valid.add(annotation);
          }
          _check();
          try {
            await root.create(recursive: true);
            _check();
            final temp = File('${file.path}.tmp');
            try {
              await temp.writeAsString(jsonEncode(valid), flush: true);
              _check();
              // No async gap between cancellation check and cache promotion.
              if (file.existsSync()) file.deleteSync();
              temp.renameSync(file.path);
            } finally {
              if (temp.existsSync()) temp.deleteSync();
            }
          } on FileSystemException {
            /* Reading works without disk caching. */
          }
          break;
        }
      }
      _check();
      groups.addAll(accepted ?? const []);
      groups.addAll(imageGroups);
    }
    try {
      final files = await root
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      if (files.length > 512) {
        final dated = [for (final f in files) (f, (await f.stat()).modified)];
        dated.sort((a, b) => a.$2.compareTo(b.$2));
        for (final entry in dated.take(files.length - 512)) {
          _check();
          await entry.$1.delete();
        }
      }
    } on FileSystemException {
      /* Best-effort eviction. */
    }
    _check();
    return validateGroups(section, groups);
  }

  bool _redundant(
    Section section,
    Map<String, dynamic> value,
    SemanticBatch batch,
  ) {
    final quote = value['quote'];
    if (value['kind'] == 'quote_attribution' &&
        quote is int &&
        batch.contains(quote) &&
        quote < section.blocks.length &&
        section.blocks[quote] is QuoteBlock &&
        (section.blocks[quote] as QuoteBlock).attribution != null) {
      return true;
    }
    final id = value['block'];
    return value.length == 2 &&
        value['kind'] == 'section_heading' &&
        id is int &&
        batch.contains(id) &&
        id < section.blocks.length &&
        section.blocks[id] is TextBlock &&
        (section.blocks[id] as TextBlock).kind == TextBlockKind.heading;
  }
}
