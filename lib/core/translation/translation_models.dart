enum TranslationMode { replace, bilingual }

class TranslationBlockInput {
  final int blockIndex;
  final int? segmentIndex;
  final String nodeId;
  final String text;

  const TranslationBlockInput({
    required this.blockIndex,
    this.segmentIndex,
    required this.nodeId,
    required this.text,
  });
}

class BlockTranslation {
  final int blockIndex;
  final int? segmentIndex;
  final String text;

  const BlockTranslation({
    required this.blockIndex,
    this.segmentIndex,
    required this.text,
  });
}
