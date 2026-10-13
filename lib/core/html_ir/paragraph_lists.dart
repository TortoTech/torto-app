import '../ir/ir.dart';
import 'paragraph_list_recovery.dart';

List<Block> recoverParagraphLists(
  List<Block> blocks, {
  Set<Block> excluded = const {},
  bool Function(ImageBlock)? smallImage,
}) => recoverStructuralParagraphLists(
  blocks,
  excluded: excluded,
  smallImage: smallImage,
);

List<Inline> stripListMarker(List<Inline> inlines, int scalars) {
  final output = <Inline>[];
  var remaining = scalars;
  for (final inline in inlines) {
    if (inline is TextRun && remaining > 0) {
      final runes = inline.text.runes.toList(),
          count = remaining.clamp(0, runes.length);
      remaining -= count;
      if (count < runes.length) {
        output.add(
          TextRun(
            String.fromCharCodes(runes.skip(count)),
            style: inline.style,
            link: inline.link,
            language: inline.language,
            displayWritingSystem: inline.displayWritingSystem,
          ),
        );
      }
    } else {
      output.add(inline);
    }
  }
  return output;
}

int authoredListPrefixLength(List<Inline> inlines) {
  final text = inlines.whereType<TextRun>().map((r) => r.text).join();
  final marker = RegExp(
    r'^\s*(?:[•●◦▪▫‣⁃·◇◆♦◊○■□※»]|[①-⑳]|\([0-9]+\)|（[0-9]+）|[0-9一二三四五六七八九十百a-zA-Z]+[.)、．])\s*',
  ).firstMatch(text);
  return marker == null ? 0 : marker[0]!.runes.length;
}
