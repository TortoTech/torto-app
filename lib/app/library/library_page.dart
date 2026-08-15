import 'package:flutter/material.dart';

import '../reader/reader_page.dart';
import 'library_store.dart';

/// Home screen: the imported EPUB library.
class LibraryPage extends StatefulWidget {
  /// Injectable for tests; defaults to the on-disk store.
  final LibraryStore? store;

  const LibraryPage({super.key, this.store});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final LibraryStore _store = widget.store ?? LibraryStore();

  /// Null while the first load is in flight.
  List<LibraryBook>? _books;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final books = await _store.list();
    if (mounted) setState(() => _books = books);
  }

  Future<void> _import() async {
    try {
      final file = await _store.import();
      if (file == null) return; // cancelled
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${LibraryStore.titleOf(file.path)}"')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not import that file.')),
      );
    }
  }

  Future<void> _confirmDelete(LibraryBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete book?'),
        content: Text('"${book.title}" will be removed from the library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.delete(book.file);
      await _refresh();
    }
  }

  Future<void> _open(LibraryBook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderPage(file: book.file)),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Import EPUB',
            onPressed: _import,
          ),
        ],
      ),
      body: switch (books) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const Center(
            child: Text('No books yet.\nTap + to import an EPUB.',
                textAlign: TextAlign.center),
          ),
        _ => ListView.builder(
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              return ListTile(
                leading: const Icon(Icons.book_outlined),
                title: Text(book.title),
                subtitle: Text(_formatSize(book.sizeBytes)),
                onTap: () => _open(book),
                onLongPress: () => _confirmDelete(book),
              );
            },
          ),
      },
    );
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}
