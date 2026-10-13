import '../../ir/ir.dart';

enum PdfOcrViewMode { original, reflow }

/// Prepared text retains its own source identity and explicit local view choice.
abstract interface class PdfReflowSource
    implements BookSource, RasterResourceSource, DisposableBookSource {
  BookSource get original;
  Book get reflowBook;
  List<TocEntry> get originalToc;
  String get label;
  PdfOcrViewMode get mode;
  set mode(PdfOcrViewMode value);
  int sectionForPage(int page);
  String reflowTarget(int page);
  int physicalPage(int section, SourceAnchor? anchor, Section? content);
  Future<String?> targetForLocator(LocatorV1 locator);
  Future<void> saveMode();
}
