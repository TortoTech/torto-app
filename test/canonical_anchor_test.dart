import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/sync/sync_models.dart';
import 'package:torto/core/html_ir/html_ir_parser.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = SpineItemId('authored-chapter');
  const anchor = SourceAnchor(spine: id, node: 'n0', textOffset: 2);
  const range = SourceRange(start: anchor, end: anchor);
  const locator = LocatorV1(
    publicationId: 'book',
    href: 'chapter.xhtml',
    position: 0,
    progression: .4,
    source: range,
  );
  test('section reordering does not change persistent identity', () {
    const book = Book(
      id: 'book',
      metadata: BookMetadata(),
      spine: [
        SpineItem(id: SpineItemId('other'), index: 0, href: 'other.xhtml'),
        SpineItem(id: id, index: 1, href: 'chapter.xhtml'),
      ],
    );
    expect(book.indexOfSpine(anchor.spine), 1);
    expect(anchor.toJson(), {
      'spine': 'authored-chapter',
      'node': 'n0',
      'text_offset': 2,
    });
    expect(SourceAnchor.fromJson(anchor.toJson()), anchor);
    expect(
      StoredProgress.fromJson(
        StoredProgress(
          locator: locator,
          updatedAt: const HybridTimestamp(
            wallTimeMs: 1,
            counter: 0,
            deviceId: 'phone',
          ),
        ).toJson().cast<String, dynamic>(),
      ).locator.source!.start,
      anchor,
    );
  });
  test('parser and table use scalar lengths while Flutter maps UTF-16', () {
    final section = const HtmlIrParser().parse(
      spineIndex: 7,
      spineId: id,
      href: 'chapter.xhtml',
      basePath: '',
      xhtml:
          '<html><body><p>A😀中</p><table><tr><td>A😀中</td></tr></table></body></html>',
    );
    expect(section.id, id);
    for (final node in sectionTextNodes(section)) {
      expect(node.source.start.spine, id);
      expect(node.source.end.textOffset, 3);
    }
    final pages = const LayoutEngine().paginate(
      section,
      const LayoutViewport(width: 360, height: 640),
      const ReaderStyle(),
    );
    final text = pages.first.items.whereType<TextPlacement>().first;
    final cell = pages.first.items.whereType<TableCellPlacement>().first;
    expect(text.displayToSource.last, 3);
    expect(cell.displayToSource, [0, 1, 1, 2, 3]);
    expect(pages.first.firstAnchor!.spine, id);
    for (final page in pages) {
      page.dispose();
    }
  });
  test('search and excerpts use scalar positions after astral characters', () {
    const text = '😀 Hello HELLO';
    final matches = sourceMatches(text, 'hello', caseSensitive: false).toList();
    expect(matches, [(2, 7), (8, 13)]);
    expect(sourceSlice(text, 2, 7), 'Hello');
  });
  test(
    'legacy local anchors retain progress without leaking numeric IDs',
    () async {
      SharedPreferences.setMockInitialValues({
        'progress:book': jsonEncode({
          ...locator.toJson(),
          'source_revision': 2,
          'source': {
            'start': {'spine': 0, 'node': 'n0', 'text_offset': 3},
            'end': {'spine': 0, 'node': 'n0', 'text_offset': 3},
          },
        }),
      });
      final store = ProgressStore(await SharedPreferences.getInstance());
      final migrated = (await store.load('book'))!;
      expect(migrated.source, isNull);
      expect(migrated.progression, .4);
      expect((await store.all())['book']!.progression, .4);
      await store.save(locator);
      expect((await store.load('book'))!.source!.start, anchor);
      expect(
        cloudLocatorJson((await store.load('book'))!)['source'],
        range.toJson(),
      );
    },
  );
}
