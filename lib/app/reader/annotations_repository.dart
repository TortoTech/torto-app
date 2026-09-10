import 'package:uuid/uuid.dart';
import '../../core/ir/ir.dart';
import '../sync/cloud_settings_store.dart';
import '../sync/sync_store.dart';
import '../sync/sync_models.dart';

/// Same database and wire records as desktop; edits retain UUID and causal clock.
class AnnotationsRepository {
  final SyncStore store;
  AnnotationsRepository(this.store);
  static Future<AnnotationsRepository> open() async {
    final settings = await CloudSettingsStore().load();
    return AnnotationsRepository(await SyncStore.open(settings.deviceId));
  }

  Future<List<AnnotationState>> list(String book) =>
      store.annotationsForBook(book);
  Future<void> save({
    required String book,
    required List<SourceRange> ranges,
    required String quote,
    String? note,
    AnnotationState? previous,
    bool delete = false,
  }) async {
    final timestamp = await store.tick();
    final clock = {...?previous?.clock};
    clock[store.deviceId] = (clock[store.deviceId] ?? 0) + 1;
    await store.mergeAnnotations([
      AnnotationState(
        id: previous?.id ?? const Uuid().v4(),
        bookId: book,
        ranges: ranges,
        quote: quote,
        note: note == null || note.trim().isEmpty ? null : note.trim(),
        createdAt: previous?.createdAt ?? timestamp.wallTimeMs,
        updatedAt: timestamp,
        clock: clock,
        deletedAt: delete ? timestamp : null,
        originDevice: store.deviceId,
        conflictOf: previous?.conflictOf,
      ),
    ]);
  }
}
