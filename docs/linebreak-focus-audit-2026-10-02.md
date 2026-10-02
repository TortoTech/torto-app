# Inline markers, paragraph breaking and focus edges

## Confirmed and fixed

Reference placeholders (citations, footnotes and website icons) occupied
`size * 1.25`, but the optimizer measured only `size`. This underestimation
could make the explicit line plan wrap again during shaping, or fail the
width tolerance check. The entire paragraph then reverted to native wrapping,
also losing discretionary hyphens. Both measurement and rendering now share
one width function.

The regression test contains eight markers with deterministic English
hyphenation. Restoring the old measurement produces 31 shaped lines against
23 planned lines, rejecting the plan. Correct measurement accepts 23 lines,
including 18 discretionary hyphens, for citation, footnote and website markers.
The test also checks links and canonical source offsets.

Markers are atomic and their preceding anchor is protected from a line break.
That local protection is intentional; it is not a paragraph-wide disable rule.
An ordinary link suppresses hyphenation only for words intersecting that link.

Desktop `move_focus_unit` enters the adjacent section at the unit boundary.
Mobile previously only produced haptic feedback. Mobile now enters the adjacent
logical subsection after a fresh committed outward vertical gesture at the
first/last unit, after exhausting any overflow. An individual gesture still
advances at most one unit/window. Reverse entry starts at the last unit's final
window; horizontal navigation continues restoring its saved position.

## Remaining whole-paragraph fallback conditions

| Condition | Effect / rationale |
| --- | --- |
| Native line breaking selected, a single native line, center/end alignment, or unsupported block kind | Optimizer is not entered. Eligible kinds are paragraph, blockquote, caption, list item and definition description. Headings, definition terms and the independent table-cell shaping path do not use this paragraph optimizer. |
| More than 4096 UTF-16 source units | Layout skips optimization to bound work. Hidden citation/footnote source text also counts toward this limit. |
| More than 4096 measured clusters or over 100,000 candidate evaluations | Optimizer aborts to bound work. |
| A tab or Hebrew/Arabic-range character | Current LTR optimizer rejects the entire paragraph. Explicit newlines are supported; each segment is planned separately, and one failed segment rejects the full paragraph. |
| Invalid geometry/cluster ranges; a style boundary splitting a grapheme; unavailable glyph measurements | Measurement cannot safely build a contiguous plan. |
| Nonempty inline formula whose raster is not ready | The paragraph falls back until a formula raster is available. A resolved inline formula or image is otherwise supported as an atomic measured object. |
| No feasible justified line plan | Includes indivisible objects/words too wide to fit and narrow lines containing only a word fragment with no expandable space/CJK boundary. The latter can happen even when the English dictionary provides break candidates. |
| Fewer than two planned lines, extra shaped lines, or nonfinal width outside `max(1px, width * 1%)` tolerance | Rejects the optimized result after planning/shaping. Hyphenation currently exists only in the optimized path, so this also removes automatic discretionary hyphens. |

## Conditions suppressing hyphenation without disabling the optimizer

- Only English US/GB dictionaries are supported. Generic `en` inherits the
  publication variant or uses US. Other declared regional variants/languages,
  missing publication fallback and unavailable dictionaries produce no automatic
  English opportunities for affected text.
- Untagged text inherits the publication dictionary only when the full paragraph
  passes the English predominance heuristic (at least five Latin letters and a
  70% share after weighting competing scripts). Explicit English spans can still
  work in mixed-language paragraphs. Hidden marker source text participates in
  this heuristic too.
- Links, reference icons and inline objects are excluded locally. A word crossing
  multiple spans must be eligible in every span and use the same dictionary.
  Bold/italic span boundaries alone do not suppress hyphenation.
- `hyphens: none` suppresses all discretionary breaks. `manual` permits authored
  soft hyphens but suppresses dictionary-based opportunities. Auto mode supports
  both. Plain native fallback does not implement automatic dictionary hyphens.
- Automatic matching covers ASCII words of at least five letters, with at least
  two letters before and three after a dictionary split. Accented words are not
  covered as complete words by this matcher. Adjacent `/`, `@`, `_` or backslash
  suppresses identifier-like matches; numeric adjacency is not currently a guard.
- Available opportunities need not be selected: ordinary breaks are preferred
  when similarly good, and consecutive hyphenated lines incur an extra penalty.

These remaining rules were audited rather than broadened in this change. Future
work should distinguish fallback reasons in diagnostics and preserve safe
hyphenation when a justified plan is infeasible, without forcing justification
on single-word fragments or removing bidi/geometry safeguards.

## Validation and deployment

37 targeted tests passed, including inline reference retention, English
hyphenation, paragraph optimization, focus gestures, focus progress and
translation navigation. Flutter analysis reported no issues.

The release-signed arm64 APK was installed with `adb install -r` as version
0.7.1 / Android version code 9160. The signing certificate matched the existing
release certificate; first installation time remained 2026-08-30 08:47:45.
No app data was cleared. APK SHA-256:
`0779450a19f5be9a0cf6f1014c1271d4ed0a93fd3171d8bb50c63b4dd8b68c21`.

## Actual book: “Finally, Table 7.8 shows…”

The original cached EPUB paragraph is in spine index 14,
`OEBPS/html/14_chapter7.xhtml`. Parsed text length is 1477 UTF-16 units;
alignment is justified and all five text runs allow automatic hyphenation.
The publication declares generic English (`en`, resolved to the US dictionary).
There are two links: Table 7.8 and LaBerge & Samuels. These exclude only their
own text. No formula, tab, RTL text or length-limit rejection was found.

The investigation compiled the same hyphen package's native libhyphen source
for Windows and loaded the application's real English dictionary. This avoids
the Windows test runner's missing-DLL fallback. Literata was also loaded from
the application's actual font asset. The original paragraph produced 118
discretionary break candidates. With 32px side margins and Latin indentation:

| Viewport width / font size | Planned / shaped lines | Selected hyphens | Result |
| --- | --- | --- | --- |
| 393 / 18 | 40 / 41 | 17 | Entire plan rejected |
| 411 / 18 | 37 / 38 | 8 | Entire plan rejected |
| 411 / 20 | 42 / 42 | 10 | Accepted |
| 432 / 20 | 40 / 41 | 17 | Entire plan rejected |

At 411/18 the first extra wrap occurred in the planned line ending in
`…likely syntactic category and/`. At 393/18 and 432/20 it occurred in a line
ending with a discretionary split of “sufficient”. The shaping line-count
safeguard then discarded the entire optimized paragraph, including all selected
hyphens. It is a reproducible measurement-versus-final-shaping discrepancy,
distinct from reference-icon width underestimation. A font/width change can
therefore make the same paragraph switch between optimized and native wrapping.

These are host reproductions with original EPUB runs, not an instrumented capture
of the phone's current saved font settings or AI-derived inline annotations.
Temporary diagnostic code was removed; the installed APK remains 9160. Logs and
the standalone diagnostic source are archived under `output/reading-performance/`.
The exact cause within shaping (for example word-fragment shaping, spacing or
contextual glyph measurement) requires line-level measurement comparison before
choosing a correction. The safe direction is to validate/replan offending lines
with their final styles, while retaining the guard against accidental extra wraps.

## Contextual shaping correction

Further comparison rebuilt the selected lines without spacing adjustments at
unbounded width, using the final styled word fragments and discretionary hyphens.
The problematic 411/18 line measured 340.117px in the original paragraph context
but occupied 341.379px when shaped as its selected line: a 1.262px difference.
The “sufficient” fragment differed by 0.957px at 393/18 and 1.054px at 432/20.
Those differences exceed the existing subpixel/1px allowance and cause another
automatic wrap. This establishes a contextual shaping discrepancy rather than
missing dictionary opportunities.

The renderer now attempts a bounded correction only when its final paragraph
has extra lines. It measures the explicitly planned lines at unbounded width
with their final styles and spacing. For small overflows, it reduces interior
ordinary space spacing toward the planned target, then rebuilds and validates
at the real width. Corrections must stay within the original 1%/1px tolerance
and 33% space-shrink limit; NBSP, markers and objects are excluded. There are
at most two corrections. Uncorrectable geometry still falls back. Paragraphs
that already pass retain the original fast path and spacing.

All 12 original-book width/font combinations now pass with their existing
break choices, links and source offsets retained. Previously failing cases:

| Viewport / size | Corrected lines | Retained hyphens |
| --- | --- | --- |
| 393 / 18 | 40 | 17 |
| 411 / 18 | 37 | 8 |
| 432 / 20 | 40 | 17 |

The permanent regression uses independent synthetic prose with Literata and
deterministic English breaks. It fails at 360/20 with corrections disabled and
passes all 12 combinations when enabled, checking hard line endings, fit and
monotonic canonical source mapping. It does not depend on the private EPUB or
a locally compiled dictionary library. Full validation: 549 tests passed,
4 skipped; Flutter analysis and whitespace checks passed.

Further original-book validation covered focus sentence splitting on/off and
semantic citation folding on/off (48 width/size/sentence/annotation combinations);
all retained explicit optimized line endings. The phone cache benchmark used
the same 9,587,324-byte book and the saved Literata 20px setting at an actual
411.4286px logical viewport. Ordinary and focus modes both produced 42 planned
and shaped lines with 10 selected hyphens, two preserved links and source end
1477. This phone capture uses original EPUB runs; the semantic citation variants
were verified separately on the host rather than by reading private AI caches.

Final deployment is 0.7.1 / version code 9180, using a verified release-signed
arm64 APK and `adb install -r`. First install time remains 2026-08-30 08:47:45;
data and reading progress were not cleared. Cold launch succeeded. The final
AOT library contains neither the book benchmark nor hyphen diagnostic strings;
the intermediate 9170 diagnostic build is no longer installed. Wireless ADB
remains running. Final APK SHA-256:
`4a9c099b04c428fa404374c31b2e4bcbe905cafc03b537181a085923e6dc27f2`.
