import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  group('ReaderController peek', () {
    test('peekPage/canPeek resolve pages across section boundaries',
        () async {
      final file = File(
          '../torto/test-data/Structured Writing Rhetoric and Process.epub');
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('SKIP: ${file.path} not found');
        return;
      }
      SharedPreferences.setMockInitialValues({});
      final controller = ReaderController(
          progressStore:
              ProgressStore(await SharedPreferences.getInstance()));
      addTearDown(controller.dispose);

      const viewport = LayoutViewport(width: 411, height: 914);
      await controller.open(file, viewport, const ReaderStyle());
      expect(controller.opened, isTrue);

      // Book bounds: nothing before the first page.
      expect(controller.canPeek(-1), isFalse);
      expect(controller.peekPage(-1), isNull);

      // Next page exists (same section or a later one).
      expect(controller.canPeek(1), isTrue);

      // Same-section peek works without any preparation.
      if (controller.pageIndex + 1 < controller.currentPages.length) {
        expect(controller.peekPage(1), isNotNull);
      }

      // After ensurePeek, the adjacent sections are paginated and the
      // cross-section neighbour is available.
      await controller.ensurePeek();
      expect(controller.peekPage(1), isNotNull);

      // Jump deep into the book and verify backward peeking.
      await controller.goToSection(controller.sectionCount > 3 ? 3 : 1);
      await controller.ensurePeek();
      expect(controller.canPeek(-1), isTrue);
      expect(controller.peekPage(-1), isNotNull);

      // Jumping to the last section: forward peek eventually runs out.
      await controller.goToSection(controller.sectionCount - 1);
      await controller.ensurePeek();
      // Depending on page count, forward peek may or may not exist, but it
      // must never throw and must stay consistent with peekPage.
      expect(controller.canPeek(1), controller.peekPage(1) != null);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
