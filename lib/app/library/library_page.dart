import 'dart:async';
import '../statistics/statistics_page.dart';
import '../statistics/statistics_store.dart';

import 'package:flutter/material.dart';

import '../progress_store.dart';
import '../reader/reader_page.dart';
import '../reader/reader_controller.dart';
import '../sync/cloud_sync_controller.dart';
import '../../l10n/app_localizations.dart';
import 'library_store.dart';

/// Home screen: the imported EPUB library.
class LibraryPage extends StatefulWidget {
  /// Injectable for tests; defaults to the on-disk store.
  final LibraryStore? store;
  final ProgressStore? progressStore;
  final CloudSyncController? cloudSyncController;
  final bool initializeCloudSync;

  const LibraryPage({
    super.key,
    this.store,
    this.progressStore,
    this.cloudSyncController,
    this.initializeCloudSync = true,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  late final LibraryStore _store = widget.store ?? LibraryStore();
  late final ProgressStore _progressStore =
      widget.progressStore ?? ProgressStore();
  CloudSyncController? _cloudSync;
  bool _ownsCloudSync = false;
  CloudSyncStatus? _lastCloudStatus;
  ReaderController? _activeReader;

  /// Null while the first load is in flight.
  List<LibraryBook>? _books;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _cloudSync = widget.cloudSyncController;
    _cloudSync?.addListener(_onCloudSyncChanged);
    if (_cloudSync?.settings.enabled == true) {
      unawaited(_sync(silent: true));
    }
    // Injected stores are used by widget tests and deliberately stay isolated
    // from device plugins and the real cloud account.
    if (_cloudSync == null &&
        widget.store == null &&
        widget.initializeCloudSync) {
      unawaited(_initializeCloudSync());
    }
  }

  Future<void> _initializeCloudSync() async {
    try {
      final controller = await CloudSyncController.create(
        libraryStore: _store,
        progressStore: _progressStore,
      );
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.addListener(_onCloudSyncChanged);
      _ownsCloudSync = true;
      setState(() => _cloudSync = controller);
      if (controller.settings.enabled) unawaited(_sync(silent: true));
    } catch (_) {
      // Settings remain accessible after the next launch; initialization
      // failures must not prevent the local shelf from opening.
    }
  }

  void _onCloudSyncChanged() {
    final status = _cloudSync?.status;
    final completed =
        status == CloudSyncStatus.success &&
        _lastCloudStatus != CloudSyncStatus.success;
    _lastCloudStatus = status;
    if (completed) unawaited(_refresh());
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final reader = _activeReader;
      if (reader != null) unawaited(reader.flushProgress());
    } else if (state == AppLifecycleState.resumed &&
        _cloudSync?.settings.enabled == true) {
      unawaited(_sync(silent: true));
    }
  }

  Future<void> _refresh() async {
    final books = [...await _store.list()];
    final activityTimes = await _progressStore.activityTimes();
    sortShelfBooks(books, activityTimes);
    if (mounted) setState(() => _books = books);
  }

  Future<void> _import() async {
    try {
      final file = await _store.import();
      if (file == null) return; // cancelled
      await _refresh();
      if (_cloudSync?.settings.enabled == true) unawaited(_sync(silent: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.text(
              '已导入“${LibraryStore.titleOf(file.path)}”',
              'Imported "${LibraryStore.titleOf(file.path)}"',
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.text('无法导入该文件。', 'Could not import that file.'),
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(LibraryBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.text('删除书籍？', 'Delete book?')),
        content: Text(
          context.l10n.text(
            '“${book.title}”将从书架中移除。',
            '"${book.title}" will be removed from the library.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.text('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.text('删除', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _cloudSync?.markBookRemoved(book.id);
      await _store.delete(book.file);
      await _refresh();
      if (_cloudSync?.settings.enabled == true) unawaited(_sync(silent: true));
    }
  }

  Future<void> _open(LibraryBook book) async {
    await _progressStore.markActivity(book.id);
    if (!mounted) return;
    final controller = ReaderController(
      progressStore: _progressStore,
      titleHint: book.title,
      publicationIdHint: book.id,
    );
    _activeReader = controller;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(file: book.file, controller: controller),
        ),
      );
      await controller.flushProgress();
    } finally {
      _activeReader = null;
      controller.dispose();
    }
    await _refresh();
    if (_cloudSync?.settings.enabled == true) unawaited(_sync(silent: true));
  }

  Future<void> _bookActions(LibraryBook book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bar_chart),
              title: Text(context.l10n.text('阅读详情', 'Reading details')),
              onTap: () => Navigator.pop(context, 'statistics'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(context.l10n.text('删除书籍', 'Delete book')),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      // Preserve the title and added date even for a book never opened.
      try {
        await (await ReadingStatisticsStore.instance()).registerBooks([book]);
      } catch (error) {
        debugPrint('Could not preserve book statistics: $error');
      }
      if (mounted) await _confirmDelete(book);
    } else if (action == 'statistics') {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ReadingStatisticsPage(bookId: book.id),
        ),
      );
    }
  }

  Future<void> _sync({bool silent = false}) async {
    final controller = _cloudSync;
    if (controller == null) return;
    try {
      final report = await controller.sync();
      await _refresh();
      if (!mounted || silent) return;
      final message = report.changed
          ? context.l10n.text(
              '同步完成：上传 ${report.uploadedBooks} 本，下载 ${report.downloadedBooks} 本，合并 ${report.mergedProgress + report.mergedAnnotations} 项阅读数据。',
              'Sync complete: ${report.uploadedBooks} uploaded, '
                  '${report.downloadedBooks} downloaded, '
                  '${report.mergedProgress + report.mergedAnnotations} reading updates.',
            )
          : context.l10n.text('已是最新状态。', 'Everything is up to date.');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      try {
        await _refresh();
      } catch (_) {
        // Keep the original sync error when a partially updated shelf cannot
        // be refreshed.
      }
      if (!mounted || silent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.text('云同步失败：$error', 'Cloud sync failed: $error'),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final cloud = _cloudSync;
    cloud?.removeListener(_onCloudSyncChanged);
    if (_ownsCloudSync) cloud?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final books = _books;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.text('书架', 'Library')),
        actions: [
          if (_cloudSync?.settings.enabled == true)
            _cloudSync?.status == CloudSyncStatus.syncing
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.sync),
                    tooltip: l10n.text('立即同步', 'Sync now'),
                    onPressed: _sync,
                  ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.text('导入书籍', 'Import book'),
            onPressed: _import,
          ),
        ],
      ),
      body: switch (books) {
        null => const Center(child: CircularProgressIndicator()),
        [] => Center(
          child: Text(
            l10n.text(
              '书架还是空的。\n点击 + 导入 EPUB、FB2、CBZ、\nMOBI、CHM 或 PDF。',
              'No books yet.\nTap + to import an EPUB, FB2, CBZ,\nMOBI, CHM or PDF.',
            ),
            textAlign: TextAlign.center,
          ),
        ),
        _ => GridView.builder(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 14,
            mainAxisSpacing: 22,
            childAspectRatio: 0.55,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            return _BookTile(
              book: book,
              onTap: () => _open(book),
              onLongPress: () => _bookActions(book),
            );
          },
        ),
      },
    );
  }
}

void sortShelfBooks(List<LibraryBook> books, Map<String, int> readActivity) {
  books.sort((left, right) {
    final leftReadAt = readActivity[left.id] ?? 0;
    final rightReadAt = readActivity[right.id] ?? 0;
    final leftActivity = leftReadAt > left.addedAt ? leftReadAt : left.addedAt;
    final rightActivity = rightReadAt > right.addedAt
        ? rightReadAt
        : right.addedAt;
    final byActivity = rightActivity.compareTo(leftActivity);
    if (byActivity != 0) return byActivity;
    final byAddedAt = right.addedAt.compareTo(left.addedAt);
    return byAddedAt != 0 ? byAddedAt : left.id.compareTo(right.id);
  });
}

class _BookTile extends StatelessWidget {
  final LibraryBook book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _BookTile({
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    onLongPress: onLongPress,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(aspectRatio: 0.7, child: _BookCover(book: book)),
        const SizedBox(height: 8),
        Text(
          book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ],
    ),
  );
}

class _BookCover extends StatelessWidget {
  final LibraryBook book;

  const _BookCover({required this.book});

  @override
  Widget build(BuildContext context) {
    final bytes = book.coverBytes;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: bytes == null
            ? _fallback(context)
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) =>
                    _fallback(context),
              ),
      ),
    );
  }

  Widget _fallback(BuildContext context) => Icon(
    Icons.book_outlined,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}
