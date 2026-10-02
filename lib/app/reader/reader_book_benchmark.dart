import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/formats/epub_book_source.dart';
import '../../core/formats/image_dimensions.dart';
import '../../core/ir/ir.dart';
import '../../core/ir/inline_content.dart';
import '../../core/ir/text_index.dart';
import '../../core/layout/layout_engine.dart';
import '../../core/layout/layout_types.dart';
import '../../core/linebreak/english_hyphenator.dart';
import 'reader_preferences_store.dart';

/// Local developer benchmark, absent from ordinary builds. It reads only the
/// requested cached publication and emits counts/timings, never book text.
const benchmarkBookTitle = String.fromEnvironment('TORTO_BENCHMARK_BOOK');
const benchmarkRun = String.fromEnvironment(
  'TORTO_BENCHMARK_RUN',
  defaultValue: 'baseline',
);
const benchmarkParagraph = String.fromEnvironment('TORTO_BENCHMARK_PARAGRAPH');
const benchmarkSection = int.fromEnvironment(
  'TORTO_BENCHMARK_SECTION',
  defaultValue: -1,
);
void _emit(String stage, Map<String, Object?> values) => debugPrint(
  'TORTO_BOOK_BENCH ${jsonEncode({'run': benchmarkRun, 'stage': stage, ...values})}',
);

Future<void> runRequestedBookBenchmark() async {
  if (benchmarkBookTitle.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final key =
      'local_book_benchmark_done_v1_${benchmarkRun}_$benchmarkBookTitle';
  if (prefs.getBool(key) == true) return;
  await prefs.setBool(key, true);
  _emit('start', {});
  EpubBookSource? source;
  try {
    final docs = await getApplicationDocumentsDirectory(),
        cache = await getTemporaryDirectory();
    final wanted = benchmarkBookTitle.toLowerCase(), candidates = <File>[];
    File? bookFile;
    for (final root in [docs, cache]) {
      if (!await root.exists()) continue;
      var count = 0;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++count > 4000) break;
        if (entity is! File) continue;
        if (entity.path.toLowerCase().endsWith('.epub')) candidates.add(entity);
        if (!entity.path.endsWith('.metadata.json')) continue;
        try {
          if (await entity.length() > 128 * 1024) continue;
          final meta = jsonDecode(await entity.readAsString()) as Map;
          if ((meta['title'] as String? ?? '').toLowerCase().contains(wanted)) {
            final file = File(
              entity.path.substring(
                0,
                entity.path.length - '.metadata.json'.length,
              ),
            );
            if (await file.exists()) {
              bookFile = file;
              break;
            }
          }
        } catch (_) {}
      }
      if (bookFile != null) break;
    }
    // Some transient caches have no library metadata sidecar.
    if (bookFile == null) {
      for (final file in candidates.take(80)) {
        final candidate = await EpubBookSource.fromFileInBackground(file.path);
        final matches = candidate.book.metadata.title.toLowerCase().contains(
          wanted,
        );
        candidate.dispose();
        if (matches) {
          bookFile = file;
          break;
        }
      }
    }
    if (bookFile == null) {
      _emit('not_found', {'epubs': candidates.length});
      return;
    }
    if (!bookFile.path.toLowerCase().endsWith('.epub')) {
      _emit('unsupported_format', {'extension': bookFile.path.split('.').last});
      return;
    }
    final watch = Stopwatch()..start();
    source = await EpubBookSource.fromFileInBackground(bookFile.path);
    _emit('open', {
      'ms': watch.elapsedMilliseconds,
      'bytes': await bookFile.length(),
      'sections': source.book.sectionCount,
      'title_matches': source.book.metadata.title.toLowerCase().contains(
        wanted,
      ),
      'rss_mb': ProcessInfo.currentRss ~/ 1048576,
    });
    if (benchmarkParagraph.isNotEmpty && benchmarkSection >= 0) {
      final chapter = await source.parseSection(benchmarkSection);
      final target = chapter.blocks.whereType<TextBlock>().firstWhere(
        (block) => block.plainText.startsWith(benchmarkParagraph),
      );
      final section = Section(
        id: chapter.id,
        spineIndex: chapter.spineIndex,
        href: chapter.href,
        blocks: [target],
      );
      final language = source.book.metadata.language;
      await EnglishHyphenator.instance.ensureLoadedForSection(
        section,
        publicationLanguage: language,
      );
      final typography = await ReaderPreferencesStore().loadTypography();
      final view = ui.PlatformDispatcher.instance.views.first;
      final logical = view.physicalSize / view.devicePixelRatio;
      final engine = LayoutEngine(hyphenator: EnglishHyphenator.instance);
      for (final focus in [false, true]) {
        final pages = engine.paginate(
          section,
          LayoutViewport(width: logical.width, height: logical.height),
          ReaderStyle(
            baseFontSize: typography.fontSize,
            typography: typography,
            writingSystem: WritingSystem.latin,
            publicationLanguage: language,
            focusMode: focus,
          ),
        );
        final placement = pages.first.items.whereType<TextPlacement>().first;
        final lines = placement.paragraph.computeLineMetrics();
        _emit('paragraph', {
          'section': benchmarkSection,
          'chars': target.plainText.length,
          'width': logical.width,
          'font_size': typography.fontSize,
          'font': typography.otherPrimaryFont.name,
          'focus': focus,
          'lines': lines.length,
          'hard_breaks': lines.where((line) => line.hardBreak).length,
          'optimized': lines
              .take(lines.length - 1)
              .every((line) => line.hardBreak),
          'links': placement.links.length,
          'source_end': placement.displayToSource.last,
        });
        for (final page in pages) {
          page.dispose();
        }
      }
      _emit('done', {'paragraphs': 1});
      return;
    }
    final samples = <({int index, int parseMs, int chars, Section section})>[];
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    for (var i = 0; i < source.book.sectionCount && i < 160; i++) {
      if (DateTime.now().isAfter(deadline)) break;
      watch.reset();
      Section section;
      try {
        section = await source.parseSection(i);
      } catch (error) {
        _emit('parse_failed', {
          'section': i,
          'ms': watch.elapsedMilliseconds,
          'type': error.runtimeType.toString(),
        });
        break;
      }
      final ms = watch.elapsedMilliseconds;
      final chars = sectionTextNodes(
        section,
      ).fold<int>(0, (n, b) => n + b.text.length);
      samples.add((index: i, parseMs: ms, chars: chars, section: section));
      _emit('parse', {
        'section': i,
        'ms': ms,
        'blocks': section.blocks.length,
        'chars': chars,
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final byParse = [...samples]
      ..sort((a, b) => b.parseMs.compareTo(a.parseMs));
    final bySize = [...samples]..sort((a, b) => b.chars.compareTo(a.chars));
    final selected = <int>{
      if (samples.isNotEmpty) samples.first.index,
      ...byParse.take(2).map((s) => s.index),
      ...bySize.take(2).map((s) => s.index),
    };
    const engine = LayoutEngine();
    for (final i in selected) {
      if (DateTime.now().isAfter(deadline)) break;
      final section = samples.firstWhere((s) => s.index == i).section;
      final dimensions = <String, ui.Size>{};
      final hrefs = <String>{};
      for (final block in section.blocks) {
        if (block is ImageBlock) hrefs.add(block.href);
        for (final text in blockTexts(block)) {
          for (final inline in text.inlines) {
            if (inline is InlineImageRun) hrefs.add(inline.image.href);
          }
        }
      }
      watch.reset();
      for (final href in hrefs) {
        final bytes = await source.resource(href);
        final size = bytes == null ? null : readImageDimensions(bytes);
        if (size != null) {
          dimensions[href] = ui.Size(size.$1.toDouble(), size.$2.toDouble());
        }
      }
      _emit('image_headers', {
        'section': i,
        'ms': watch.elapsedMilliseconds,
        'images': hrefs.length,
      });
      await EnglishHyphenator.instance.ensureLoadedForLanguage(
        source.book.metadata.languages.firstOrNull ?? 'en',
      );
      for (final focus in [false, true]) {
        watch.reset();
        final pages = await engine.paginateAsync(
          section,
          const LayoutViewport(width: 393, height: 780),
          ReaderStyle(
            focusMode: focus,
            publicationLanguage:
                source.book.metadata.languages.firstOrNull ?? 'en',
          ),
          imageSizeResolver: (href) => dimensions[href],
          readingToc: source.book.toc,
          shouldCancel: () => DateTime.now().isAfter(deadline),
        );
        _emit('layout', {
          'section': i,
          'focus': focus,
          'ms': watch.elapsedMilliseconds,
          'pages': pages.length,
          'items': pages.fold<int>(0, (n, p) => n + p.items.length),
          'rss_mb': ProcessInfo.currentRss ~/ 1048576,
        });
        for (final page in pages) {
          page.dispose();
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    _emit('done', {'parsed': samples.length});
  } catch (error) {
    _emit('failed', {'type': error.runtimeType.toString()});
  } finally {
    source?.dispose();
  }
}
