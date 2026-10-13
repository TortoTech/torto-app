import '../ir/ir.dart';

class _Marker {
  final Map<String, int> families;
  final int prefix;
  final String? image;
  const _Marker(this.families, this.prefix, [this.image]);
}

bool _referenceHeading(TextBlock block) =>
    !block.inlines.whereType<TextRun>().any((r) => r.link != null) &&
    RegExp(
      r'^(?:notes|endnotes|footnotes|references|bibliography|further reading|recommended reading|注释|注釋|尾注|脚注|参考文献|參考文獻)$',
      caseSensitive: false,
    ).hasMatch(block.plainText.trim());

_Marker? _marker(TextBlock block, bool Function(ImageBlock)? smallImage) {
  final leading = block.inlines.takeWhile(
    (i) => i is InlineImageRun || i is TextRun && i.text.trim().isEmpty,
  );
  final image = leading.whereType<InlineImageRun>().firstOrNull?.image;
  if (image != null && (smallImage?.call(image) ?? false)) {
    final spaces = RegExp(r'^\s*').firstMatch(block.plainText)![0]!;
    if (block.plainText.trim().isNotEmpty) {
      return _Marker(
        {'image:${image.href}': 1},
        spaces.runes.length,
        image.href,
      );
    }
  }
  final text = block.plainText;
  final match = RegExp(
    r'^\s*(?:([•●◦▪▫‣⁃·◇◆♦◊○■□※»])|([①-⑳])|(?:\(([0-9]+)\)|（([0-9]+)）|([0-9]+)[.)、．]|([一二三四五六七八九十百]+)[、.)．]|([a-zA-Z]+)[.)]))\s*',
  ).firstMatch(text);
  if (match == null ||
      match.end == text.length ||
      RegExp(r'^[0-9]').hasMatch(text.substring(match.end))) {
    return null;
  }
  final values = <String, int>{};
  if (match[1] != null) values['bullet:${match[1]}'] = 1;
  if (match[2] != null) values['circled'] = match[2]!.runes.first - 0x2460 + 1;
  final digits = match[3] ?? match[4] ?? match[5];
  if (digits != null) {
    final value = int.tryParse(digits) ?? 0;
    if (value > 0 && value < 1900) values['arabic'] = value;
  }
  if (match[6] case final chinese?) {
    const numbers = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    var total = 0, digit = 0;
    for (final c in chinese.split('')) {
      if (c == '十' || c == '百') {
        total += (digit == 0 ? 1 : digit) * (c == '十' ? 10 : 100);
        digit = 0;
      } else {
        digit = numbers[c] ?? 0;
      }
    }
    values['chinese'] = total + digit;
  }
  if (match[7] case final letters?) {
    if (letters.length == 1) {
      values['alpha'] = letters.toLowerCase().codeUnitAt(0) - 96;
    }
    if (RegExp(r'^[ivxlcdm]+$', caseSensitive: false).hasMatch(letters)) {
      const roman = {
        'i': 1,
        'v': 5,
        'x': 10,
        'l': 50,
        'c': 100,
        'd': 500,
        'm': 1000,
      };
      var total = 0, previous = 0;
      for (final c in letters.toLowerCase().split('').reversed) {
        final value = roman[c]!;
        total += value < previous ? -value : value;
        previous = value;
      }
      values['roman'] = total;
    }
  }
  return values.isEmpty
      ? null
      : _Marker(values, text.substring(0, match.end).runes.length);
}

List<Block> recoverStructuralParagraphLists(
  List<Block> blocks, {
  Set<Block> excluded = const {},
  bool Function(ImageBlock)? smallImage,
}) {
  final output = List<Block>.of(blocks);
  final markers = <int, _Marker>{};
  var referenceRegion = false;
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    if (block is! TextBlock) continue;
    if (_referenceHeading(block)) {
      referenceRegion = true;
    } else if (block.kind == TextBlockKind.heading) {
      referenceRegion = false;
    }
    if (referenceRegion ||
        excluded.contains(block) ||
        block.kind != TextBlockKind.paragraph ||
        block.inlines.whereType<TextRun>().every((r) => r.link != null)) {
      continue;
    }
    final marker = _marker(block, smallImage);
    if (marker != null) markers[i] = marker;
  }
  double inset(int i) {
    final s = (blocks[i] as TextBlock).style;
    return s.marginStart + s.marginStartFraction * 1000;
  }

  bool unordered(String family) =>
      family.startsWith('bullet:') || family.startsWith('image:');
  for (var start = 0; start < blocks.length;) {
    if (!markers.containsKey(start)) {
      start++;
      continue;
    }
    var end = start + 1;
    while (markers.containsKey(end)) {
      end++;
    }
    final choices = <int, String>{}, owners = <int, int>{};
    final sorted = [for (var i = start; i < end; i++) i]
      ..sort((a, b) => inset(a).compareTo(inset(b)));
    final bins = <double>[], binFor = <int, int>{};
    for (final at in sorted) {
      final value = inset(at);
      if (bins.isEmpty || value - bins.last > 4) bins.add(value);
      binFor[at] = bins.length - 1;
    }
    final peers = <(String, int), List<int>>{};
    for (var at = start; at < end; at++) {
      for (final family in markers[at]!.families.keys) {
        (peers[(family, binFor[at]!)] ??= []).add(at);
      }
    }
    for (final entry in peers.entries) {
      final family = entry.key.$1, items = entry.value;
      var first = 0;
      while (first < items.length) {
        var last = first + 1;
        while (last < items.length &&
            (unordered(family) ||
                markers[items[last]]!.families[family] ==
                    markers[items[last - 1]]!.families[family]! + 1)) {
          last++;
        }
        if (last - first >= 2) {
          for (var i = first; i < last; i++) {
            choices.putIfAbsent(items[i], () => family);
            owners.putIfAbsent(items[i], () => items[first]);
          }
        }
        first = last;
      }
    }
    if (choices.isNotEmpty) {
      final first = choices.keys.reduce((a, b) => a < b ? a : b);
      final base = choices.keys.map(inset).reduce((a, b) => a < b ? a : b);
      for (var at = start; at < end; at++) {
        if (!choices.containsKey(at) && inset(at) > base + 4) {
          final bullet = markers[at]!.families.keys
              .where(unordered)
              .firstOrNull;
          if (bullet != null) choices[at] = bullet;
        }
      }
      final rootFor = <int, int>{};
      var root = first;
      for (var at = start; at < end; at++) {
        if (choices.containsKey(at) && (inset(at) - base).abs() <= 4) {
          root = owners[at] ?? root;
        }
        rootFor[at] = root;
      }
      final levels = choices.keys.map(inset).toList()..sort();
      final indents = <double>[];
      for (final value in levels) {
        if (indents.isEmpty || value - indents.last > 4) indents.add(value);
      }
      for (final entry in choices.entries) {
        final block = blocks[entry.key] as TextBlock,
            marker = markers[entry.key]!;
        output[entry.key] = TextBlock(
          kind: TextBlockKind.listItem,
          inlines: block.inlines,
          style: block.style,
          nodeId: block.nodeId,
          source: block.source,
          listOrdered: !unordered(entry.value),
          listOrdinal: marker.families[entry.value]!,
          listDepth: indents
              .indexWhere((v) => (v - inset(entry.key)).abs() <= 4)
              .clamp(0, 8),
          listGroupId:
              'paragraph-list-${(blocks[rootFor[entry.key]!] as TextBlock).nodeId}',
          authoredListMarkerChars: marker.prefix,
          authoredListMarkerImage: marker.image,
        );
      }
    }
    start = end;
  }
  return output;
}
