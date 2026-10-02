# Reader header and footnote marker parity

The reading header no longer contains previous/next subsection buttons. Swipe
navigation, the library button and the other reader controls remain available.

Unified typesetting now follows desktop footnote display numbering. Numbers
restart for each paragraph or composite semantic block. Quotes, figures and
tables share a sequence across their component paragraphs; a list and its
introduction share a sequence. Bilingual list companions reuse their original
numbers without advancing the sequence. Numbering is assigned before sentence
splitting and pagination, and never replaces authored markers or book offsets.

Consecutive styled fragments of one note coalesce into one marker. Independent
repeated linked markers retain distinct numbers, and bibliography citations
remain separate `[n]` labels. Backlinks and ordinary superscript text are not
numbered. Website markers retain their website appearance.

The body uses superscript-style plain numbers for numbered footnotes. Popup
rows use the corresponding display number and retain the original marker for
resolving linked note text. A popup collects references across all page slices
of the owning scope, in footnote-number order, then citation order. Shared page
slices and bilingual companions do not duplicate footnote entries. The tapped
footnote is scrolled into view independently from the citation selection.

Focus painting shows reference markers only in the active unit's paint bounds.
Tapping a reference position in an inactive unit activates the unit first.
Classic pages show all reference markers.

Popup markers now flow inline at the beginning of their content instead of
occupying a separate column. A 40px marker slot reduces only the first line's
available width; subsequent lines use the entire content width. Plain notes
keep the paragraph optimizer and publication-language hyphenation; math notes
keep their formula widgets. Marker color and centering are retained.

Validation covers multipart/repeated markers, separate citation numbering,
composite/list scopes, unchanged canonical text, 12 notes across page slices,
bilingual numbering, native book typesetting and header controls. A renderer
pixel test verifies inactive reference markers disappear. A widget layout test
verifies the first line begins after the marker and the second begins at the
full-width left edge. Full suite: 556 passed, 4 skipped; analysis passed.

The release-signed arm64 build 0.7.1 / 9190 was installed with `adb install -r`.
The certificate matches the existing release certificate, and first installation
time remains 2026-08-30 08:47:45. Library/cache/progress were not cleared. Cold
launch succeeded and wireless ADB remains running. APK SHA-256:
`03a3754d17113b6e2456f1b5475bc272ab16638ed1474f72f38eb62cc07cd716`.

## Superscript text correction and inline citations

The first numbering implementation still fitted text into a compact icon slot,
including a 12px font cap and a second height-based scale. It therefore did not
match desktop text sizing or baseline placement. Numbered markers now carry
their font family, weight, actual font size and baseline rise from layout into
painting. The painter aligns glyph baselines to the owning text line rather
than centering and shrinking a paragraph inside the icon box. Width reservation
counts digits without enlarging the marker's height for two-digit numbers.
Optimizer measurement and final placeholder width use the same rule.

Desktop source contracts are `prepare_inline_content` in
`torto/crates/layout/src/lib.rs` and text compilation in
`torto/crates/renderer/src/lib.rs`:

- Numbered notes set the size scale to 0.78. Their baseline rises by 0.35 times
  the larger of the body/marker font sizes. At normal 20px body size this is
  15.6px text, raised 7px.
- Inline citation labels retain `[n]`. Their resolved source size is multiplied
  by 0.78 and their baseline rises by 0.35 of the citation font size. Normal
  20px source text yields 15.6px labels raised 5.46px. Authored keyword sizing
  and a source superscript's unified 0.70 scale are retained before applying
  0.78, matching desktop instead of accidentally applying icon-fit scaling.

Real Literata pixel tests cover 18/20/28px body sizes and both line-break
strategies. They check glyph ink height, superscript placement, and the exact
size/rise contract. Citation tests cover plain, keyword-sized and originally
superscript sources while retaining original note text and canonical offsets.

The correction is deployed as release-signed 0.7.1 / Android version code 9200.
Full final suite: 558 passed, 4 skipped; analysis passed. In-place installation
and cold launch succeeded, with the original first-install time retained and
no book data cleared. APK SHA-256:
`f43eab7e2ececf148e3efa3938bcdf4beca78efaa921f7f46890420038180e2f`.


## Optical spacing, compact popup markers and settings follow-up

Body markers now reserve their actual glyph advance in the selected runtime font,
with the same Literata optical-size variation used by the painter. For numbered
notes, desktop optical rules reduce the gap after closing CJK punctuation to
0.10 em and add separation before following CJK text toward 0.16 em, bounded
by desktop's 0.65 em compression and 0.20 em separation limits. Raster ink metrics
are cached with a 512-entry bound and native resources are disposed. A raster
measurement failure falls back to ordinary advance without preventing reading.

Greedy, optimized and table text apply the same leading adjustment. Since native
placeholder selection boxes do not reflect negative joiner letter spacing,
painting and hit testing explicitly carry the optical offset. Canonical source
mapping does not count synthetic joiners; optimizer measurement includes the
same width correction. Regression coverage uses actual Literata and WenKai fonts,
both line-break strategies, canonical offsets and the moved marker's tap target.

Popup footnote and citation markers share a slot measured from the widest visible
label, rather than the earlier fixed 40px slot. Labels are horizontally centered
and vertically centered on the first line; the gap is 0.30 times the popup body
font size. Subsequent lines use the full content width and marker colors retain
the body marker color.

Media overlays fit their content to the actual safe viewport, including asymmetric
left/right insets. The interactive viewer uses the full viewport and does not clip
zoomed content at an inner padded boundary. Initial image aspect ratio and both
edges are checked at narrow width. Formula previews retain their white background.

Translation model is now a section heading with a full-width selector. Empty model
lists no longer throw. Expert translation is last and the enable-translation notice
is removed. Reading assistant web search follows History turns, directly before
its search configuration. Full regression: 562 passed, 4 skipped; analysis passed.

Deployed with the existing release certificate as 0.7.1 / Android code 9210
(Flutter build number 7210). In-place installation succeeded; first-install time
is unchanged at 2026-08-30 08:47:45. Cold launch succeeded in 803 ms and the
process remained running. APK SHA-256: `acc3bc1fa4886f5a47ff03a435e5e62a3676f37b12c993b5aba958fb8ce2f00e`.


## CJK gap correction after 9210

Rendered Chinese samples exposed two shortcomings of the first optical-spacing
implementation. It only compressed closing punctuation on the left, leaving
ordinary CJK text with its natural narrow side bearing (about 2 pixels in the
20px WenKai/Literata sample). Negative letter spacing on a synthetic word joiner
did not move the following text in the actual styled CJK paragraph, although
the marker's explicit paint offset moved the numeral. That produced inconsistent
paint versus layout advances, which the earlier selection-box test did not catch.

Ordinary CJK text now receives a minimum optical-gap target of 0.16 em on the
left as well as the existing right-side target. Empty styled runs are skipped
when locating the neighbouring glyphs. Both leading and trailing adjustments
are included in the marker placeholder's real advance; synthetic joiners only
prevent separation, without negative letter spacing. Optimizer measurements
use that same advance instead of altering the preceding measured cluster.

Closing-punctuation compression retains desktop's target and bounds, with an
additional native-placeholder constraint: its glyph advance after compression
must remain at least 1px. This preserves a positive placeholder on Flutter and
keeps the next glyph aligned with the painted marker. The 20px rendered sample
has about 4px left and 3px right gaps after ordinary CJK text, and about 8px left
and 3px right gaps after a full stop. The latter is a platform constraint rather
than the earlier unsupported negative-advance assumption.

A real-font pixel regression now covers 18/20/28px body sizes, closing punctuation
and ordinary CJK text, empty styled neighbours, and paragraphs long enough to
exercise both greedy and optimized line breaking. It checks actual blue numeral
ink against black neighbour ink, as well as canonical source length. Existing
superscript, marker tap and inline-reference/hyphenation checks remain covered.

The bottom enablement notice in AI typesetting settings was removed.

Final validation: 563 passed, 4 skipped; analysis passed. Release-signed 0.7.1 /
9220 was installed with adb install -r and cold launched in 1010 ms. First-install
time remains 2026-08-30 08:47:45; library, cache and progress were not cleared.
APK SHA-256: `4a9a34ad92dd53c19d64c876b68ab9398e473cd900a08b2e0aeb803f32b3ffaf`.
