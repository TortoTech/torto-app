# Mobile focus mode

Enable **Focus mode** in the reader's typography sheet. The preference is
independent of unified/book typography and is shared across books. Fixed-layout
publications and original PDF pages keep ordinary reading.

**Split by sentence** is a separate, persistent switch in the same sheet. It is
off initially and can be changed only in focus mode. Enabling it applies to all
supported paragraphs, list items, figure captions and quote bodies, including
translated companions. Sentences start new lines inside their original semantic
unit; they do not become separate activation units. Headings, code, tables and
quote attribution retain their layout. Quotes retain internal semicolons, and
paired punctuation, formulas and footnotes are protected. Ordinary reading
ignores the remembered switch. No per-paragraph controls are provided.
Sentence subparagraphs retain optimized line breaking and discretionary
hyphenation. Each sentence restarts the first-line indent; inserted breaks,
indent placeholders and hyphens do not advance canonical source offsets.
Rasterized inline formulas participate as indivisible measured objects instead
of disabling paragraph optimization; their formula links and source ranges are
retained. Device verification in *Why You Hear What You Hear*, at Figure 3.2,
confirmed discretionary hyphens and working formula taps with both focus
switches enabled.

- Semantic units remain complete: paragraphs, figures with captions, tables
  with annotations, quotes with attribution, and list roots with descendants.
- Headings travel with the following body unit. Translation companions remain
  attached to their source unit. Trailing headings are retained.
- Consecutive short units fill one page without exceeding its body area. An
  oversized unit owns one logical page and scrolls vertically.
- Vertical swipes select one adjacent unit on short pages; they scroll long
  pages with inertia. Neither action crosses page boundaries.
- Horizontal swipes turn pages. Tapping a unit activates it; tapping the active
  unit or empty space opens controls. Links and annotations take precedence.
- The controls include previous/next page buttons. There is no unit counter,
  scrollbar, or extra scroll hint.
- Active-unit changes affect emphasis only, never page geometry. Recent page
  visits retain activation and scroll state (bounded to 32 layouts).
- Source anchors preserve progress across reflow, mode changes and reopening.
  Long pages derive the anchor from visible text. Translation progress retains
  the existing canonical paragraph-level contract.

`FocusUnitBuilder` computes semantic boundaries before the layout engine places
content. The paginator lays out each unit without vertical splitting, then
packs it as a whole. Display-list translation preserves text, link and selection
metadata; offscreen items are excluded from scrolling display lists. Existing
pagination pause/cancellation rules also cover focus drags and inertia.

Regression coverage:

```sh
flutter test test/core/focus_layout_test.dart test/core/sentence_structure_test.dart test/reader_focus_gesture_test.dart test/reader_focus_progress_test.dart
```
