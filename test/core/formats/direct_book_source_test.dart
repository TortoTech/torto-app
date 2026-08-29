import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/direct_book_source.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  test('promotes a single fallback TOC root', () async {
    // One section only → its entry has no children → no promotion, but a
    // single wrapped TOC (like a PDF outline root) unwraps.
    final wrapped = DirectBookSource.open(
      SourceBook(
        id: 'wrapped-toc-test',
        metadata: const BookMetadata(title: 'Sample Book'),
        sections: const [
          SourceSection(
            title: 'Page 1',
            content: HtmlSectionContent('<p>Page 1</p>'),
          ),
        ],
        tableOfContents: [
          SourceTocEntry(
            label: '目 录',
            href: 'Text/section-1.xhtml',
            children: [
              const SourceTocEntry(
                label: 'Preface',
                href: 'Text/section-1.xhtml#preface',
              ),
              const SourceTocEntry(
                label: 'Chapter One',
                href: 'Text/section-1.xhtml#chapter-one',
              ),
            ],
          ),
        ],
      ),
    );

    expect(wrapped.book.toc, hasLength(2));
    expect(wrapped.book.toc[0].label, 'Preface');
    expect(wrapped.book.toc[1].label, 'Chapter One');
    expect(wrapped.book.toc[0].spineIndex, 0);
  });

  test('parses HTML sections and serves fragment hrefs + resources', () async {
    final source = DirectBookSource.open(
      SourceBook(
        id: 'direct-source-test',
        metadata: const BookMetadata(title: 'Direct'),
        sections: const [
          SourceSection(
            title: 'Chapter',
            content: HtmlSectionContent(
              '<h1 id="chapter">Chapter</h1>'
              '<img src="../Images/cover.png"/>',
            ),
          ),
          SourceSection(
            title: 'Plate',
            linear: false,
            content: ImageSectionContent(
              resourcePath: 'Images/page-00001.png',
              alt: 'plate 1',
            ),
          ),
        ],
        resources: [
          SourceResource(
            path: 'Images/cover.png',
            mediaType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ],
        coverPath: 'Images/cover.png',
      ),
    );

    final book = source.book;
    expect(book.spine.map((item) => item.href), [
      'Text/section-1.xhtml',
      'Text/section-2.xhtml',
    ]);

    // Fallback TOC only covers linear sections.
    expect(book.toc, hasLength(1));
    expect(book.toc.first.label, 'Chapter');
    expect(book.toc.first.spineIndex, 0);

    final section = await source.parseSection(0);
    final heading = section.blocks.whereType<TextBlock>().first;
    expect(heading.kind, TextBlockKind.heading);
    expect(
      section.blocks.whereType<ImageBlock>().single.href,
      'Images/cover.png',
    );

    final plate = await source.parseSection(1);
    expect(plate.blocks.single, isA<ImageBlock>());
    expect((plate.blocks.single as ImageBlock).href, 'Images/page-00001.png');

    expect(await source.resource('Images/cover.png'), [1, 2, 3]);
    expect(await source.resource(book.coverHref!), [1, 2, 3]);
    expect(await source.resource('Images/missing.png'), isNull);
  });

  test(
    'promotes plain TOC targets for direct MOBI/FB2-style sources',
    () async {
      final source = DirectBookSource.open(
        const SourceBook(
          id: 'direct-heading-test',
          metadata: BookMetadata(title: 'Direct headings'),
          sections: [
            SourceSection(
              title: 'Chapter One',
              content: HtmlSectionContent(
                '<p id="chapter-one" style="text-align:center">Chapter One</p>'
                '<p>Body text.</p>',
              ),
            ),
          ],
          tableOfContents: [
            SourceTocEntry(
              label: 'Contents',
              href: 'Text/section-1.xhtml',
              children: [
                SourceTocEntry(
                  label: 'Chapter One',
                  href: 'Text/section-1.xhtml#chapter-one',
                ),
              ],
            ),
          ],
        ),
      );

      final heading = (await source.parseSection(0)).blocks.first as TextBlock;
      expect(heading.kind, TextBlockKind.heading);
      expect(heading.headingLevel, 1);
      expect(heading.style.align, BlockAlign.center);
    },
  );

  test('rejects a book with no readable sections', () {
    expect(
      () => DirectBookSource.open(
        SourceBook(
          id: 'empty',
          metadata: const BookMetadata(),
          sections: const [],
        ),
      ),
      throwsFormatException,
    );
  });
}
