import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/reader_book_tools.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'core/html_ir_parser_test.dart' show parseSection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'book tools require prior reading and confirmation; display rewrite is undoable and original file remains exact',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('torto-assistant-');
      addTearDown(() => dir.delete(recursive: true));
      final archive = Archive();
      void add(String name, String value) {
        final bytes = utf8.encode(value);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('mimetype', 'application/epub+zip');
      add(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      );
      add(
        'book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">assistant-test</dc:identifier><dc:title>Book</dc:title><dc:language>en</dc:language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
      );
      add(
        'a.xhtml',
        '<html><body><h1>Heading</h1><p>Original paragraph.</p><p>Second paragraph.</p></body></html>',
      );
      add('b.xhtml', '<html><body><p>Another section.</p></body></html>');
      final bytes = ZipEncoder().encode(archive),
          file = await File('${dir.path}/book.epub').writeAsBytes(bytes);
      final controller = ReaderController(
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
      );
      addTearDown(controller.dispose);
      await controller.open(
        file,
        const LayoutViewport(width: 411, height: 700),
        const ReaderStyle(),
      );
      final tools = ReaderBookTools(controller);
      expect((await tools.execute('getBookMetadata', {}))['title'], 'Book');
      expect(
        (await tools.execute('getContent', {'unit': 1}))['error'],
        isNotNull,
      );
      final original = await controller.assistantSource!.parseSection(0);
      final node = sectionTextNodes(
        original,
      ).firstWhere((n) => n.text == 'Original paragraph.');
      final id = '0/${node.source.start.node}',
          replacement = {id: 'Rewritten paragraph with a different length.'};
      expect(
        (await tools.execute('rewriteBlocks', {
          'blocks': replacement,
        }))['error'],
        isNotNull,
      );
      final content = await tools.execute('getContent', {});
      expect(
        (content['blocks'] as List).any(
          (b) => b['id'] == id && b['citation'].contains('torto://source'),
        ),
        true,
      );
      final proposal = await tools.execute('rewriteBlocks', {
        'blocks': replacement,
      });
      expect(proposal['pending_confirmation'], true);
      expect(controller.hasTemporaryRewrites, false);
      controller.setReaderVisible(false);
      await tools
          .execute('rewriteBlocks', {'blocks': replacement}, confirmed: true)
          .timeout(const Duration(seconds: 10));
      expect(controller.hasTemporaryRewrites, true);
      expect(
        sectionTextNodes(
          await controller.assistantSource!.parseSection(0),
        ).any((n) => n.text == 'Original paragraph.'),
        true,
      );
      expect(await file.readAsBytes(), bytes);
      await controller.clearTemporaryRewrites();
      expect(controller.hasTemporaryRewrites, false);
    },
  );
  test(
    'linked numeric bibliography is eligible but a regular book link or array is protected',
    () {
      final section = parseSection(
        '<p>Evidence <a href="#ref-1">[1]</a>; array <a href="#ref-2">[2]</a>; <a href="chapter.xhtml">[3]</a>.</p>',
      );
      final candidates = citationCandidates(section);
      expect(candidates.map((c) => c['text']), ['[1]', '[2]']);
      expect(localCitation(candidates.first), true);
      expect(localCitation(candidates.last), false);
    },
  );
}
