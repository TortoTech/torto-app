import 'dart:convert';

import '../../core/ir/ir.dart';

const int syncProtocolVersion = 1;
const String syncProtocolName = 'rebook-webdav';

enum CloudProvider {
  jianguoyun('Jianguoyun', 'https://dav.jianguoyun.com/dav'),
  infiniCloud('InfiniCloud', 'https://webdav.infini-cloud.net'),
  koofr('Koofr', 'https://app.koofr.net/dav/Koofr'),
  hiDrive('HiDrive', 'https://webdav.hidrive.strato.com'),
  yandexDisk('Yandex Disk', 'https://webdav.yandex.com'),
  custom('Custom WebDAV', '');

  final String label;
  final String defaultUrl;

  const CloudProvider(this.label, this.defaultUrl);
}

class CloudSettings {
  final bool enabled;
  final CloudProvider provider;
  final String baseUrl;
  final String username;
  final String deviceId;
  final String deviceName;

  const CloudSettings({
    this.enabled = false,
    this.provider = CloudProvider.custom,
    this.baseUrl = '',
    this.username = '',
    this.deviceId = '',
    this.deviceName = '',
  });

  String get effectiveBaseUrl =>
      provider == CloudProvider.custom ? baseUrl.trim() : provider.defaultUrl;

  CloudSettings copyWith({
    bool? enabled,
    CloudProvider? provider,
    String? baseUrl,
    String? username,
    String? deviceId,
    String? deviceName,
  }) => CloudSettings(
    enabled: enabled ?? this.enabled,
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    username: username ?? this.username,
    deviceId: deviceId ?? this.deviceId,
    deviceName: deviceName ?? this.deviceName,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'provider': provider.name,
    'base_url': baseUrl,
    'username': username,
    'device_id': deviceId,
    'device_name': deviceName,
  };

  factory CloudSettings.fromJson(Map<String, dynamic> json) {
    final providerName = json['provider'] as String?;
    final provider = CloudProvider.values.firstWhere(
      (value) => value.name == providerName,
      orElse: () => CloudProvider.custom,
    );
    return CloudSettings(
      enabled: json['enabled'] == true,
      provider: provider,
      baseUrl: json['base_url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
    );
  }
}

class HybridTimestamp implements Comparable<HybridTimestamp> {
  final int wallTimeMs;
  final int counter;
  final String deviceId;

  const HybridTimestamp({
    required this.wallTimeMs,
    required this.counter,
    required this.deviceId,
  });

  Map<String, Object?> toJson() => {
    'wall_time_ms': wallTimeMs,
    'counter': counter,
    'device_id': deviceId,
  };

  factory HybridTimestamp.fromJson(Map<String, dynamic> json) =>
      HybridTimestamp(
        wallTimeMs: (json['wall_time_ms'] as num).toInt(),
        counter: (json['counter'] as num).toInt(),
        deviceId: json['device_id'] as String,
      );

  @override
  int compareTo(HybridTimestamp other) {
    var result = wallTimeMs.compareTo(other.wallTimeMs);
    if (result != 0) return result;
    result = counter.compareTo(other.counter);
    return result != 0 ? result : deviceId.compareTo(other.deviceId);
  }
}

class StoredProgress {
  final LocatorV1 locator;
  final HybridTimestamp updatedAt;

  const StoredProgress({required this.locator, required this.updatedAt});

  Map<String, Object?> toJson() => {
    'locator': cloudLocatorJson(locator),
    'updated_at': updatedAt.toJson(),
  };

  factory StoredProgress.fromJson(Map<String, dynamic> json) {
    final locator = Map<String, dynamic>.from(
      json['locator'] as Map<String, dynamic>,
    )..remove('source');
    return StoredProgress(
      locator: LocatorV1.fromJson(locator),
      updatedAt: HybridTimestamp.fromJson(
        json['updated_at'] as Map<String, dynamic>,
      ),
    );
  }
}

enum VectorClockOrder { equal, before, after, concurrent }

class AnnotationState {
  final String id;
  final String bookId;
  final List<Map<String, dynamic>> ranges;
  final String quote;
  final String? note;
  final int createdAt;
  final HybridTimestamp updatedAt;
  final Map<String, int> clock;
  final HybridTimestamp? deletedAt;
  final String originDevice;
  final String? conflictOf;

  const AnnotationState({
    required this.id,
    required this.bookId,
    required this.ranges,
    required this.quote,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    required this.clock,
    this.deletedAt,
    required this.originDevice,
    this.conflictOf,
  });

  bool get deleted => deletedAt != null;

  AnnotationState copyWith({String? id, String? conflictOf}) => AnnotationState(
    id: id ?? this.id,
    bookId: bookId,
    ranges: ranges,
    quote: quote,
    note: note,
    createdAt: createdAt,
    updatedAt: updatedAt,
    clock: clock,
    deletedAt: deletedAt,
    originDevice: originDevice,
    conflictOf: conflictOf ?? this.conflictOf,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'book_id': bookId,
    'ranges': ranges,
    'quote': quote,
    if (note != null) 'note': note,
    'created_at': createdAt,
    'updated_at': updatedAt.toJson(),
    'clock': Map<String, int>.fromEntries(
      clock.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'deleted_at': deletedAt?.toJson(),
    'origin_device': originDevice,
    if (conflictOf != null) 'conflict_of': conflictOf,
  };

  factory AnnotationState.fromJson(Map<String, dynamic> json) {
    final rangesValue = json['ranges'];
    final clockValue = json['clock'];
    if (rangesValue is! List || clockValue is! Map) {
      throw const FormatException('Invalid annotation payload.');
    }
    final value = AnnotationState(
      id: json['id'] as String,
      bookId: json['book_id'] as String,
      ranges: [
        for (final range in rangesValue)
          Map<String, dynamic>.from(range as Map),
      ],
      quote: json['quote'] as String? ?? '',
      note: json['note'] as String?,
      createdAt: (json['created_at'] as num).toInt(),
      updatedAt: HybridTimestamp.fromJson(
        Map<String, dynamic>.from(json['updated_at'] as Map),
      ),
      clock: {
        for (final entry in clockValue.entries)
          entry.key as String: (entry.value as num).toInt(),
      },
      deletedAt: json['deleted_at'] == null
          ? null
          : HybridTimestamp.fromJson(
              Map<String, dynamic>.from(json['deleted_at'] as Map),
            ),
      originDevice: json['origin_device'] as String,
      conflictOf: json['conflict_of'] as String?,
    );
    value.validate();
    return value;
  }

  void validate() {
    if (id.trim().isEmpty ||
        bookId.trim().isEmpty ||
        originDevice.trim().isEmpty ||
        clock.keys.any((key) => key.trim().isEmpty)) {
      throw const FormatException('Invalid annotation identity.');
    }
    for (final range in ranges) {
      final start = range['start'];
      final end = range['end'];
      if (start is! Map || end is! Map) {
        throw const FormatException('Invalid annotation source range.');
      }
    }
  }
}

VectorClockOrder compareVectorClocks(
  Map<String, int> left,
  Map<String, int> right,
) {
  var leftGreater = false;
  var rightGreater = false;
  for (final key in {...left.keys, ...right.keys}) {
    final comparison = (left[key] ?? 0).compareTo(right[key] ?? 0);
    leftGreater |= comparison > 0;
    rightGreater |= comparison < 0;
  }
  return switch ((leftGreater, rightGreater)) {
    (false, false) => VectorClockOrder.equal,
    (false, true) => VectorClockOrder.before,
    (true, false) => VectorClockOrder.after,
    (true, true) => VectorClockOrder.concurrent,
  };
}

String annotationConflictId(AnnotationState annotation) =>
    '${annotation.id}~conflict~${annotation.originDevice}~'
    '${annotation.updatedAt.wallTimeMs}-${annotation.updatedAt.counter}';

/// Source anchors are deliberately local-only until the mobile Reading IR and
/// desktop Unicode-scalar anchor formats are identical.
Map<String, Object?> cloudLocatorJson(LocatorV1 locator) => {
  'version': LocatorV1.currentVersion,
  'publication_id': locator.publicationId,
  'href': _cloudHrefJson(locator.href),
  'position': locator.position,
  'progression': locator.progression,
  'total_progression': locator.totalProgression,
};

Map<String, Object?> _cloudHrefJson(String href) {
  final separator = href.indexOf('#');
  if (separator < 0) return {'path': href};
  final fragment = href.substring(separator + 1);
  return {
    'path': href.substring(0, separator),
    if (fragment.isNotEmpty) 'fragment': fragment,
  };
}

String canonicalCloudLocator(LocatorV1 locator) =>
    jsonEncode(cloudLocatorJson(locator));

class SyncReport {
  final int uploadedBooks;
  final int downloadedBooks;
  final int mergedProgress;
  final int mergedAnnotations;
  final int downloadedDerivedData;

  const SyncReport({
    this.uploadedBooks = 0,
    this.downloadedBooks = 0,
    this.mergedProgress = 0,
    this.mergedAnnotations = 0,
    this.downloadedDerivedData = 0,
  });

  bool get changed =>
      uploadedBooks > 0 ||
      downloadedBooks > 0 ||
      mergedProgress > 0 ||
      mergedAnnotations > 0 ||
      downloadedDerivedData > 0;
}
