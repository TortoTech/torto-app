# Reader selection, annotations and search

The reader footer selects Free, Word, Sentence or Paragraph selection granularity.
Long press starts selection, handles extend it, and tapping outside or Back clears
it. Page-turn gestures yield to active selection. A compact icon toolbar provides
Copy, Highlight, Note and Close with 48px touch targets. Translation locks selection
to paragraphs; disabling translation restores the normal selection preference.
Translated and bilingual paragraphs retain distinct display IDs with shared original
source ranges. Highlights and notes save the complete original paragraph and quote,
never translated character offsets. In translation mode saved marks cover the
corresponding paragraph pair. The Contents drawer has a Marks tab.
Search lives in the header. Footer order is Contents, Marks, Translation, Selection
mode, Typography, Theme. Advancing beyond the last readable page opens an end
screen with an explicit Mark as finished action and a return-to-last-page button.
Completion is never inferred automatically and the final text page is not obscured.

The paragraph retained by the renderer supplies hit-test and selection rectangles.
Selection and saved highlights use maximum-height text boxes so mixed-font runs
do not create stepped upper/lower edges.
Display-to-source maps remove indentation placeholders, inline images, inserted
line breaks and discretionary hyphens. Mobile-only visual list/definition breaks
have zero source length. Selection boundaries preserve grapheme clusters.
Raster-only pages and TeX fallback nodes without reliable text mappings are not
selectable. Cross-page handle dragging is not enabled.

Annotations use the existing sync-v1 database and AnnotationState protocol:
UUID identity, source ranges, quote, optional note, created_at, HLC updated_at,
vector clock, deleted_at, origin_device and conflict_of. Local edits retain the
UUID and increase the local vector-clock entry; deletions retain tombstones.
There is no new color field: persisted highlights use a fixed theme-safe color.

Core SourceAnchor, SourceRange, search results, annotations, resume positions and
sync records all use SpineItemId plus Unicode-scalar offsets. SpineItem and Section
require explicit IDs. EPUB retains the manifest ID; non-EPUB loaders supply their
format-defined IDs. Array indices are navigation details, not persistent identity.
Flutter paragraphs retain mandatory UTF-16-to-scalar display maps; only the
selection/shaping boundary uses UTF-16. The Dart RegExp adapter likewise returns
only scalar match ranges. Incoming ranges are checked against the excerpt before painting. A
single excerpt can recover a moved node only when unique in the same section.
Unresolved annotations remain available in the list and remain editable.

Parser changes reserve node IDs for empty text blocks, allocate table nodes before
cells, preserve non-collapsible HTML whitespace, recognize marked zero-margin
epigraphs, infer split ordinal/title headings conservatively, and retain symbolic
separators as source-backed text in follow-book mode. Old local resume anchors are
versioned: revisions before 3 use the retained chapter/progression rather than a
stale node number/UTF-16 offset. New cloud progress includes the canonical source
anchor instead of discarding it. Translated resume positions use the original
paragraph start because no character-level original alignment exists.

Search scans original source text in a cancellable isolate. Results arrive by
section, use literal Unicode-aware case-insensitive matching, and retain source
ranges. The result limit is 200. Activating a result switches translated display
back to the original and offers previous/next result navigation.

## Desktop parity validation

The optional tool under tool/desktop_parity reads the desktop source crates only
for testing; it is not linked into the mobile application. It emits TSV records
with spine index, desktop spine ID, node ID, hex UTF-8 normalized text and kind.
The synthetic semantic-parity fixture is checked against a desktop snapshot.

Real EPUB checks use PARITY_BOOK and PARITY_DESKTOP Dart defines with
test/reader_interactions_test.dart. Verified samples:

- Thinking in Systems A Primer: 1,590 selectable text nodes.
- The Princeton Companion to Mathematics: 15,093 selectable text nodes.
- Local Chinese 1.epub sample: 2,249 selectable text nodes.

These checks establish node/text agreement on the samples, not equivalence for
every possible publication or text-less PDF/OCR format.
