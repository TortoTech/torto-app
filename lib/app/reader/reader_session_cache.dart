import '../library/library_store.dart';
import 'reader_controller.dart';

/// Owns at most one inactive ordinary EPUB reader. Active routes keep their
/// own ownership; PDF/OCR resources and translated sessions are reopened fresh.
class ReaderSessionCache {
  ReaderController? _reader;
  (String, String, int, Object?)? _key;

  ReaderController? take(LibraryBook book, {Object? displayKey}) {
    if (_key != (book.id, book.file.path, book.sizeBytes, displayKey) ||
        _reader?.canReuseSession != true) {
      clear();
      return null;
    }
    final reader = _reader;
    _reader = null;
    _key = null;
    return reader;
  }

  void keep(LibraryBook book, ReaderController reader, {Object? displayKey}) {
    clear();
    if (!reader.canReuseSession) {
      reader.dispose();
      return;
    }
    reader.setReaderVisible(false);
    _reader = reader;
    _key = (book.id, book.file.path, book.sizeBytes, displayKey);
  }

  void invalidate(String bookId) {
    if (_key?.$1 == bookId) clear();
  }

  void clear() {
    _reader?.dispose();
    _reader = null;
    _key = null;
  }
}
