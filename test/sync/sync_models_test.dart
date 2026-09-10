import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/sync/sync_models.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  test('InfiniCloud preset uses the configured account WebDAV node', () {
    const settings = CloudSettings(provider: CloudProvider.infiniCloud);

    expect(settings.effectiveBaseUrl, 'https://higa.teracloud.jp/dav');
  });

  test('CSTCloud preset and exact custom host enable compatibility', () {
    const preset = CloudSettings(provider: CloudProvider.cstCloud);
    const custom = CloudSettings(
      provider: CloudProvider.custom,
      baseUrl: 'https://data.cstcloud.cn/dav',
    );
    const lookalike = CloudSettings(
      provider: CloudProvider.custom,
      baseUrl: 'https://data.cstcloud.cn.example.test/dav',
    );

    expect(preset.effectiveBaseUrl, 'https://data.cstcloud.cn/dav');
    expect(preset.cstCloudCompatibility, isTrue);
    expect(custom.cstCloudCompatibility, isTrue);
    expect(lookalike.cstCloudCompatibility, isFalse);
  });

  test('cloud locator preserves canonical source anchors', () {
    const anchor = SourceAnchor(
      spine: SpineItemId.generated(2),
      node: 'n4',
      textOffset: 7,
    );
    const locator = LocatorV1(
      publicationId:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      href: 'chapter.xhtml',
      position: 2,
      progression: 0.25,
      totalProgression: 0.5,
      source: SourceRange(start: anchor, end: anchor),
    );

    final json = cloudLocatorJson(locator);

    expect(json['href'], {'path': 'chapter.xhtml'});
    expect(json['position'], 2);
    expect(json['source'], locator.source!.toJson());
  });

  test('hybrid timestamp uses wall time, counter, then device id', () {
    const first = HybridTimestamp(wallTimeMs: 10, counter: 2, deviceId: 'a');
    const laterCounter = HybridTimestamp(
      wallTimeMs: 10,
      counter: 3,
      deviceId: 'a',
    );
    const laterDevice = HybridTimestamp(
      wallTimeMs: 10,
      counter: 3,
      deviceId: 'b',
    );

    expect(first.compareTo(laterCounter), lessThan(0));
    expect(laterCounter.compareTo(laterDevice), lessThan(0));
  });

  test('desktop source anchors are retained while reading remote progress', () {
    final value = StoredProgress.fromJson({
      'locator': {
        'version': 1,
        'publication_id': 'book',
        'href': {'path': 'c1.xhtml', 'fragment': 'reading-point'},
        'position': 1,
        'progression': 0.2,
        'total_progression': 0.4,
        'source': {
          'start': {
            'spine': 'chapter-id',
            'node': 'desktop-node',
            'text_offset': 1,
          },
          'end': {
            'spine': 'chapter-id',
            'node': 'desktop-node',
            'text_offset': 1,
          },
        },
      },
      'updated_at': {'wall_time_ms': 100, 'counter': 0, 'device_id': 'desktop'},
    });

    expect(value.locator.href, 'c1.xhtml#reading-point');
    expect(value.locator.position, 1);
    expect(value.locator.source!.start.spine, const SpineItemId('chapter-id'));
    expect(value.locator.source!.start.textOffset, 1);
  });

  test('legacy string locator href is rejected', () {
    expect(
      () => StoredProgress.fromJson({
        'locator': {
          'version': 1,
          'publication_id': 'book',
          'href': 'legacy.xhtml',
          'position': 0,
          'progression': 0.1,
          'total_progression': 0.2,
        },
        'updated_at': {'wall_time_ms': 1, 'counter': 0, 'device_id': 'mobile'},
      }),
      throwsFormatException,
    );
  });

  test('annotation wire model preserves tombstones and vector clocks', () {
    const updated = HybridTimestamp(
      wallTimeMs: 120,
      counter: 2,
      deviceId: 'desktop',
    );
    final annotation = AnnotationState.fromJson({
      'id': 'note-1',
      'book_id': 'book',
      'ranges': [
        {
          'start': {'spine': 'chapter', 'node': 'p1', 'text_offset': 0},
          'end': {'spine': 'chapter', 'node': 'p1', 'text_offset': 4},
        },
      ],
      'quote': 'text',
      'created_at': 100,
      'updated_at': updated.toJson(),
      'clock': {'desktop': 2, 'mobile': 1},
      'deleted_at': updated.toJson(),
      'origin_device': 'desktop',
    });

    expect(annotation.deleted, isTrue);
    expect(annotation.toJson()['clock'], {'desktop': 2, 'mobile': 1});
    expect(
      compareVectorClocks({'desktop': 1}, {'desktop': 1, 'mobile': 1}),
      VectorClockOrder.before,
    );
  });

  test('conflict annotation IDs match the desktop protocol', () {
    const annotation = AnnotationState(
      id: 'note',
      bookId: 'book',
      ranges: [],
      quote: 'quote',
      createdAt: 1,
      updatedAt: HybridTimestamp(wallTimeMs: 100, counter: 3, deviceId: 'a'),
      clock: {'a': 1},
      originDevice: 'a',
    );
    expect(annotationConflictId(annotation), 'note~conflict~a~100-3');
  });
}
