import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/ir/ir.dart';

class _FootnoteSource implements BookSource {
  final List<Section> sections;

  _FootnoteSource(this.sections);

  @override
  final Book book = const Book(
    id: 'footnote-book',
    metadata: BookMetadata(title: 'Footnote book'),
    spine: [
      SpineItem(id: SpineItemId.generated(0), index: 0, href: 'chapter.xhtml'),
      SpineItem(id: SpineItemId.generated(1), index: 1, href: 'notes.xhtml'),
    ],
  );

  @override
  Future<Section> parseSection(int index) async => sections[index];

  @override
  Future<Uint8List?> resource(String href) async => null;
}

SourceRange _range(int spine, String node, int length) => SourceRange(
  start: SourceAnchor(
    spine: SpineItemId.generated(spine),
    node: node,
    textOffset: 0,
  ),
  end: SourceAnchor(
    spine: SpineItemId.generated(spine),
    node: node,
    textOffset: length,
  ),
);

TextBlock _text(int spine, String node, String text) => TextBlock(
  nodeId: node,
  inlines: [TextRun(text)],
  source: _range(spine, node, text.length),
);

void main() {
  test('visible footnote references add every linked note text node', () async {
    final reference = TextBlock(
      nodeId: 'paragraph',
      inlines: const [
        TextRun('Body'),
        TextRun(
          '1',
          style: TextStyle(
            baseline: TextBaselineShift.superscript,
            linkRole: LinkRole.footnoteReference,
          ),
          link: 'notes.xhtml#note-1',
        ),
      ],
      source: _range(0, 'paragraph', 5),
    );
    final firstNoteText = _text(1, 'note-text', 'First note paragraph');
    final secondNoteText = _text(1, 'note-extra', 'Second note paragraph');
    final note = NoteBlock(
      kind: NoteBlockKind.definition,
      blocks: [firstNoteText, secondNoteText],
      source: SourceRange(
        start: firstNoteText.source!.start,
        end: secondNoteText.source!.end,
      ),
    );
    final source = _FootnoteSource([
      Section(
        id: SpineItemId.generated(0),
        spineIndex: 0,
        href: 'chapter.xhtml',
        blocks: [reference],
      ),
      Section(
        id: SpineItemId.generated(1),
        spineIndex: 1,
        href: 'notes.xhtml',
        blocks: [note],
        anchors: [
          SectionAnchor(
            fragment: 'note-1',
            source: firstNoteText.source!.start,
          ),
        ],
      ),
    ]);

    final candidates = await linkedFootnoteTranslationCandidates(source, 0, {
      'paragraph',
    });

    expect(candidates.map((candidate) => candidate.$1), [0, 1]);
    expect(candidates.first.$2, {'paragraph'});
    expect(candidates.last.$2, {'note-text', 'note-extra'});
  });
}
