import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final local = Platform.environment['LOCALAPPDATA'];
  final file = File(
    Platform.environment['TORTO_ENGINEERING_EPUB'] ??
        '$local/Rebook/Rebook/data/library/books/c4eff31a24da77076336d1805b255d0fc50c02bac59024b56619b9c743936c73.epub',
  );
  test('engineering book retains formula and table baseline shifts', () async {
    final loader = FontLoader('Literata')
      ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'));
    await loader.load();
    final source = await EpubBookSource.fromBytes(await file.readAsBytes());
    var bodyShifts = 0;
    var tableShifts = 0;
    var captured = false;
    for (final chapter in [
      'Chapter2.xhtml',
      'Chapter3.xhtml',
      'Chapter12.xhtml',
    ]) {
      final index = source.book.spine.indexWhere(
        (item) => item.href.endsWith(chapter),
      );
      expect(index, greaterThanOrEqualTo(0));
      final section = await source.parseSection(index);
      final pages = const LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 411, height: 850),
        const ReaderStyle(writingSystem: WritingSystem.latin),
      );
      for (final page in pages) {
        for (final item in page.items) {
          if (item is TextPlacement) bodyShifts += item.baselineRegions.length;
          if (item is TableCellPlacement) {
            tableShifts += item.baselineRegions.length;
          }
        }
        if (!captured &&
            page.items.whereType<TextPlacement>().any(
              (item) => item.baselineRegions.isNotEmpty,
            )) {
          captured = true;
          final recorder = ui.PictureRecorder();
          PagePainter(
            page: page,
            imageResolver: (_) => null,
            background: const ui.Color(0xffffffff),
          ).paint(ui.Canvas(recorder), const ui.Size(411, 850));
          final picture = recorder.endRecording();
          final image = await picture.toImage(411, 850);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/test-artifacts/engineering-baselines.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }
      }
      for (final page in pages) {
        page.dispose();
      }
    }
    expect(bodyShifts, greaterThan(0));
    expect(tableShifts, greaterThan(0));
  }, skip: !file.existsSync());
}
