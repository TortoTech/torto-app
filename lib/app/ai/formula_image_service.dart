import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../../core/ir/ir.dart';
import '../../core/ir/inline_content.dart';
import '../../core/semantic_layout/image_formulas.dart';
import '../../core/semantic_layout/formula_validation.dart';
import 'ai_models.dart';
import 'openai_compatible_client.dart';
import 'formula_image_payload.dart';
import 'formula_image_contract.dart';
export 'formula_image_contract.dart' show formulaImageSchema;

Future<List<Map<String, dynamic>>> recognizeFormulaImages({
  required Section section,
  required int start,
  required int end,
  required AiProviderConfig provider,
  required String model,
  required ReasoningEffort effort,
  required OpenAiCompatibleClient client,
  required Directory cache,
  required Future<Uint8List?> Function(String) resource,
  required void Function() check,
  Future<String?> Function(MathInline)? validateRender,
}) async {
  final candidates = formulaImageCandidates(section, start, end);
  var converted = 0;
  final items =
      <
        String,
        ({Uint8List bytes, String mime, List<(int, ImageBlock)> sources})
      >{};
  for (final candidate in candidates) {
    check();
    final bytes = await resource(candidate.$2.href);
    check();
    if (bytes == null || bytes.length > 3 * 1024 * 1024 || bytes.length < 4) {
      continue;
    }
    final id = sha256.convert(bytes).toString();
    final existing = items[id];
    if (existing != null) {
      existing.sources.add(candidate);
      continue;
    }
    final payload = await prepareFormulaImagePayload(bytes);
    check();
    if (payload == null) continue;
    if (payload.converted) converted++;
    final item = items.putIfAbsent(
      id,
      () => (
        bytes: payload.bytes,
        mime: payload.mime,
        sources: <(int, ImageBlock)>[],
      ),
    );
    item.sources.add(candidate);
  }
  final accepted = <String, Map<String, dynamic>>{};
  if (candidates.isNotEmpty) {
    debugPrint(
      'TortoFormula prepared section=${section.spineIndex} range=$start:$end candidates=${candidates.length} inputs=${items.length} converted=$converted',
    );
  }
  final transient = <String>{};
  if (items.isEmpty) return [];
  final prompts = await formulaImagePrompts();
  check();
  final wireIds = {for (final (index, id) in items.keys.indexed) id: index};
  final missing = <String>[];
  String key(String id) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'formula-3',
            id,
            provider.baseUrl,
            model,
            effort.label,
            prompts.transcribe,
            prompts.verify,
            formulaImageSchema,
          ]),
        ),
      )
      .toString();
  for (final id in items.keys) {
    try {
      final value = jsonDecode(
        await File('${cache.path}/${key(id)}.json').readAsString(),
      );
      check();
      if (value is Map<String, dynamic> &&
          (value['status'] == 'not_formula' ||
              (value['status'] == 'recognized' &&
                  value['latex'] is String &&
                  formulaError(value['latex']) == null))) {
        accepted[id] = value;
        continue;
      }
    } on FileSystemException {
      /* Cache miss. */
    } on FormatException {
      /* Recompute. */
    }
    missing.add(id);
  }
  for (var offset = 0; offset < missing.length;) {
    final batch = <String>[];
    var size = 0;
    while (offset < missing.length && batch.length < 5) {
      final id = missing[offset],
          cost = (items[id]!.bytes.length * 4 / 3).ceil();
      if (batch.isNotEmpty && size + cost > 6 * 1024 * 1024) break;
      batch.add(id);
      size += cost;
      offset++;
    }
    final review = <String, Map<String, dynamic>>{};
    for (var stage = 0; stage < 2; stage++) {
      var pending = stage == 0 ? List<String>.of(batch) : review.keys.toList();
      for (var attempt = 0; attempt < 2 && pending.isNotEmpty; attempt++) {
        check();
        final response = await client.recognizeLayout(
          compact: true,
          provider: provider,
          model: model,
          reasoningEffort: effort,
          prompt: stage == 0 ? prompts.transcribe : prompts.verify,
          schema: formulaImageSchema,
          schemaName: 'formula_image_batch',
          maxTokens: 16384,
          input: {
            'requested_ids': [for (final id in pending) wireIds[id]],
            'images': [
              for (final id in pending)
                {
                  'image_id': wireIds[id],
                  'inline':
                      section.blocks[items[id]!.sources.first.$1]
                          is! ImageBlock,
                  'context': String.fromCharCodes(
                    section.blocks
                        .sublist(
                          (items[id]!.sources.first.$1 - 1).clamp(
                            0,
                            section.blocks.length,
                          ),
                          (items[id]!.sources.first.$1 + 2).clamp(
                            0,
                            section.blocks.length,
                          ),
                        )
                        .expand(blockTexts)
                        .map((t) => t.plainText)
                        .join('\n')
                        .runes
                        .take(900),
                  ),
                  if (stage == 1) ...review[id]!,
                },
            ],
          },
          images: [
            for (final id in pending) ...[
              {'type': 'text', 'text': 'image_id ${wireIds[id]}: original'},
              {
                'type': 'image_url',
                'image_url': {
                  'url':
                      'data:${items[id]!.mime};base64,${base64Encode(items[id]!.bytes)}',
                },
              },
            ],
          ],
        );
        check();
        final results = response['results'];
        if (response.keys.length != 1 || results is! List) continue;
        final next = <String>[];
        for (final id in pending) {
          final matches = results
              .whereType<Map>()
              .where((value) => value['image_id'] == wireIds[id])
              .toList();
          if (matches.isEmpty ||
              matches.any(
                (m) =>
                    jsonEncode([
                      m['status'],
                      m['latex'],
                      m['equation_number'],
                    ]) !=
                    jsonEncode([
                      matches.first['status'],
                      matches.first['latex'],
                      matches.first['equation_number'],
                    ]),
              )) {
            next.add(id);
            continue;
          }
          final value = Map<String, dynamic>.from(matches.first);
          final status = value['status'];
          if (!const {
                'recognized',
                'not_formula',
                'unreadable',
              }.contains(status) ||
              (status == 'recognized'
                  ? value['latex'] is! String
                  : value['latex'] != null) ||
              (value['equation_number'] != null &&
                  value['equation_number'] is! String)) {
            next.add(id);
            continue;
          }
          if (status == 'recognized') {
            transient.add(id);
            final latex = value['latex'] as String,
                number = value['equation_number'] as String?;
            var error = formulaError(latex);
            if (number != null &&
                (number.length > 40 ||
                    !RegExp(r'^[\s()\[\]0-9A-Za-z.\-]+$').hasMatch(number))) {
              error = 'Invalid equation number';
            }
            error ??= await validateRender?.call(
              MathInline(latex, display: true, equationNumber: number),
            );
            check();
            if (error != null) {
              if (stage == 0) {
                review[id] = {
                  'proposal': {'latex': latex, 'equation_number': number},
                  'local_validation_error': error,
                };
              }
              continue;
            }
          }
          accepted[id] = value;
        }
        pending = next;
      }
    }
  }
  final out = <Map<String, dynamic>>[];
  for (final id in transient) {
    accepted.putIfAbsent(
      id,
      () => {'status': 'unreadable', 'latex': '', 'equation_number': null},
    );
  }
  for (final entry in accepted.entries) {
    check();
    if (entry.value['status'] != 'unreadable') {
      try {
        await cache.create(recursive: true);
        check();
        final file = File('${cache.path}/${key(entry.key)}.json');
        final tmp = File('${file.path}.tmp');
        try {
          await tmp.writeAsString(jsonEncode(entry.value));
          check();
          if (file.existsSync()) file.deleteSync();
          tmp.renameSync(file.path);
        } finally {
          if (tmp.existsSync()) tmp.deleteSync();
        }
      } on FileSystemException {
        /* Cache is optional. */
      }
    }
    if (entry.value['status'] == 'not_formula') continue;
    for (final source in items[entry.key]!.sources) {
      out.add({
        'kind': 'image_formula',
        'block': source.$1,
        'href': source.$2.href,
        'latex': entry.value['status'] == 'recognized'
            ? entry.value['latex']
            : '',
        'equation_number': entry.value['equation_number'],
      });
    }
  }
  if (candidates.isNotEmpty) {
    debugPrint(
      'TortoFormula result section=${section.spineIndex} range=$start:$end recognized=${out.where((g) => g['latex'] != '').length} fallback=${out.where((g) => g['latex'] == '').length}',
    );
  }
  return out;
}
