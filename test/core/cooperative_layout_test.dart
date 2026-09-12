import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  test(
    'cooperative layout preserves pagination while servicing queued work',
    () async {
      final section = Section(
        id: const SpineItemId.generated(0),
        spineIndex: 0,
        href: 'chapter.xhtml',
        blocks: [
          for (var i = 0; i < 100; i++)
            TextBlock(
              nodeId: 'p$i',
              inlines: [
                TextRun(
                  'Paragraph $i. A readable paragraph repeated to fill several pages. ' *
                      4,
                ),
              ],
            ),
        ],
      );
      const engine = LayoutEngine();
      const viewport = LayoutViewport(width: 360, height: 720);
      const style = ReaderStyle();
      final sync = engine.paginate(section, viewport, style);
      final serviced = Completer<void>();
      Timer.run(serviced.complete);
      var completed = false;
      final pending = engine
          .paginateAsync(section, viewport, style, timeSlice: Duration.zero)
          .then((pages) {
            completed = true;
            return pages;
          });
      await serviced.future;
      expect(completed, isFalse);
      final asyncPages = await pending;
      List<Object> signature(List<PageLayout> pages) => [
        for (final page in pages)
          [
            page.progression,
            for (final item in page.items.whereType<TextPlacement>())
              [
                item.nodeId,
                item.startLine,
                item.endLine,
                item.x,
                item.y,
                item.textOffsetAtStart,
              ],
          ],
      ];
      expect(signature(asyncPages), signature(sync));
      for (final page in [...sync, ...asyncPages]) {
        page.dispose();
      }
    },
  );
}
