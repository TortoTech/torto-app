import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

TableCell cell(String id, String text, {bool header = false, int span = 1}) =>
    TableCell(
      nodeId: id,
      inlines: [TextRun(text)],
      header: header,
      columnSpan: span,
    );

List<PageLayout> layout(
  List<TableRow> rows, {
  double width = 360,
  double size = 20,
  TypesettingMode mode = TypesettingMode.unified,
}) => const LayoutEngine().paginate(
  Section(
    id: const SpineItemId.generated(0),
    spineIndex: 0,
    href: 'table.xhtml',
    blocks: [TableBlock(rows: rows)],
  ),
  LayoutViewport(width: width, height: 1500),
  ReaderStyle(
    baseFontSize: size,
    marginLeft: 20,
    marginRight: 20,
    typesettingMode: mode,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
  });

  test(
    'short labels and bold headers retain their word width beside long prose',
    () {
      for (final size in [16.0, 20.0, 28.0]) {
        for (final width in [size * 18, size * 26]) {
          final pages = layout(
            [
              TableRow([
                cell('label-header', 'Variable', header: true),
                cell('prose-header', 'Description', header: true),
              ]),
              TableRow([
                cell('label', 'Control'),
                cell(
                  'prose',
                  'Improves internal validity since differences in measured behaviors '
                      'are more likely due to the test conditions and the explanation continues.',
                ),
              ]),
            ],
            size: size,
            width: width,
          );
          addTearDown(() {
            for (final page in pages) {
              page.dispose();
            }
          });
          final cells = pages
              .expand((p) => p.items)
              .whereType<TableCellPlacement>()
              .toList();
          for (final c in cells.where((c) => c.nodeId.startsWith('label'))) {
            expect(
              c.paragraph.computeLineMetrics(),
              hasLength(1),
              reason: '${c.nodeId} size=$size width=$width',
            );
            expect(
              c.rect.width,
              greaterThanOrEqualTo(
                c.paragraph.minIntrinsicWidth.ceilToDouble() +
                    c.padding * 2 +
                    size * .9 * .5 -
                    .1,
              ),
            );
          }
          expect(
            cells
                .singleWhere((c) => c.nodeId == 'prose')
                .paragraph
                .computeLineMetrics()
                .length,
            greaterThan(1),
          );
          for (final c in cells) {
            expect(c.rect.left, greaterThanOrEqualTo(19.9));
            expect(c.rect.right, lessThanOrEqualTo(width - 19.9));
          }
        }
      }
    },
  );

  test('a merged header reserves its word width across the covered columns', () {
    final pages = layout([
      TableRow([
        cell('merged', 'Disadvantage', header: true, span: 2),
        cell('heading', 'Description', header: true),
      ]),
      TableRow([
        cell('a', 'A'),
        cell('b', 'B'),
        cell(
          'prose',
          'Long descriptive content occupies the remaining column and wraps across several lines.',
        ),
      ]),
    ], width: 440);
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    final cells = pages
        .expand((p) => p.items)
        .whereType<TableCellPlacement>()
        .toList();
    final merged = cells.singleWhere((c) => c.nodeId == 'merged');
    final a = cells.singleWhere((c) => c.nodeId == 'a');
    final b = cells.singleWhere((c) => c.nodeId == 'b');
    expect(merged.rect.width, closeTo(a.rect.width + b.rect.width, .01));
    expect(merged.paragraph.computeLineMetrics(), hasLength(1));
    expect(
      merged.rect.width,
      greaterThanOrEqualTo(
        merged.paragraph.minIntrinsicWidth.ceilToDouble() +
            merged.padding * 2 +
            9 -
            .1,
      ),
    );
  });

  test('insufficient room falls back to equal columns within the viewport', () {
    final pages = layout([
      TableRow([
        cell('a', 'ExtraordinarilyLongUnbreakableHeader', header: true),
        cell('b', 'AnotherExtraordinarilyLongUnbreakableHeader', header: true),
      ]),
    ], width: 180);
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    final cells = pages
        .expand((p) => p.items)
        .whereType<TableCellPlacement>()
        .toList();
    expect(cells, hasLength(2));
    for (final c in cells) {
      expect(c.rect.width, closeTo(70, .01));
      expect(c.rect.left, greaterThanOrEqualTo(20));
      expect(c.rect.right, lessThanOrEqualTo(160));
    }
  });

  test('book mode retains equal columns for asymmetric content', () {
    final pages = layout([
      TableRow([
        cell('a', 'A'),
        cell('b', 'A much longer descriptive paragraph'),
      ]),
    ], mode: TypesettingMode.book);
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    final cells = pages
        .expand((p) => p.items)
        .whereType<TableCellPlacement>()
        .toList();
    expect(cells.map((c) => c.rect.width), everyElement(closeTo(160, .01)));
  });
}
