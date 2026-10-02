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
- A logical page represents one authored subsection, regardless of its height.
  TOC fragments define boundaries; duplicate/broken anchors do not discard
  content. Heading-only chapter preludes fold into the following subsection;
  illustrated preludes remain independent. Without a usable TOC, a spine
  section is one logical page. Authored page breaks do not split a subsection.
- Headings retain ordinary rendering. They do not become activation candidates,
  inherit body dimming, or activate the next body when tapped. Leading headings
  participate in entry geometry so restoring a body start keeps them visible.
  Translation companions remain attached to the source unit.
- Vertical swipes advance one activation unit and settle smoothly into the
  reading window. Long units advance one overlapping window before leaving the
  unit. Once the first/last unit's overflow is exhausted, a fresh committed
  outward swipe enters the previous/next subsection. Forward entry selects
  its first unit; reverse entry selects its last unit's final reading window.
  Short drags and the beginning/end of the book stay in place. Image/caption
  stops are reversible. There is no free subsection-wide fling inertia.
- Horizontal swipes switch subsections. Tapping a unit activates and positions it; tapping the active
  unit or empty space opens controls. Links and annotations take precedence.
- The controls include previous/next subsection buttons. There is no unit counter,
  scrollbar, or extra scroll hint.
- Active-unit changes affect emphasis only, never page geometry. Recent page
  visits retain canonical activation/scroll anchors (bounded to eight visits).
- A prose introduction and its authored list travel together. Tall lists have
  separate activation parts while nested items remain with their root. Adjacent
  independent lists retain their ownership.
- Source anchors preserve progress across reflow, mode changes and reopening.
  Long pages derive the anchor from visible text. Translation progress retains
  the existing canonical paragraph-level contract.
- Source image dimensions drive layout; visible and adjacent textures load at
  the physical display resolution within bounded caches. Double-tap a block image
  to open an independent high-resolution, pinch-to-zoom preview.

`ReadingUnitIndex` computes authored subsection starts independently of AI
batching. `FocusUnitBuilder` computes activation groups. The existing paginator
produces continuous subsection display lists with separate geometry and paint
regions. Display-list translation preserves text, link and selection
metadata; offscreen items are excluded from scrolling display lists. Existing
pagination pause/cancellation rules also cover focus drags and inertia.
AI layout and translation demand uses the visible display list, not all content
in the subsection. Physical page indices remain an implementation detail of
ordinary reading; persisted progress continues to use original source anchors.

Regression coverage:

```sh
flutter test test/core/focus_layout_test.dart test/core/sentence_structure_test.dart test/reader_focus_gesture_test.dart test/reader_focus_progress_test.dart
```
