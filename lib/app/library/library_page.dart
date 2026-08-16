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
        SnackBar(
          content: Text('Imported "${LibraryStore.titleOf(file.path)}"'),
        ),
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
          child: Text(
            'No books yet.\nTap + to import an EPUB.',
            textAlign: TextAlign.center,
          ),
        ),
        _ => ListView.separated(
          itemCount: books.length,
          separatorBuilder: (context, index) =>
              const Divider(height: 1, indent: 88),
          itemBuilder: (context, index) {
            final book = books[index];
            return InkWell(
              onTap: () => _open(book),
              onLongPress: () => _confirmDelete(book),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BookCover(book: book),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (book.authors.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                book.authors.join(' / '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      },
    );
  }
}

class _BookCover extends StatelessWidget {
  final LibraryBook book;

  const _BookCover({required this.book});

  @override
  Widget build(BuildContext context) {
    final bytes = book.coverBytes;
    return Container(
      width: 56,
      height: 80,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: bytes == null
          ? _fallback(context)
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => _fallback(context),
            ),
    );
  }

  Widget _fallback(BuildContext context) => Icon(
    Icons.book_outlined,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}
