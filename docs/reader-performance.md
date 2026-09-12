# Reader performance

## Retained session

The shelf owns at most one inactive ordinary EPUB reader. Returning to the same
book reuses its parsed source, retained paragraphs, images, and page layouts.
The reader still reloads saved progress and presentation preferences before
continuing. Applying received progress does not write a new local reading event.

The cache is discarded when the book/content identity, path, size, or display
geometry changes; when that book is deleted; on memory pressure; or when the
shelf is disposed. PDF/OCR readers, sessions that used translation, incomplete
opens, busy readers, and unsaved progress are not retained. An inactive retained
reader pauses lookahead and starts no translation work.

The route's exit animation completes before the shelf takes ownership. Closing
during an asynchronous open cannot resurrect a disposed controller.

## Paragraph shaping

Each styled run measures the discretionary hyphen once per paragraph, rather
than once per candidate break. The advance cache is local to that paragraph,
so changes to fonts and formatting cannot reuse stale metrics. Candidate breaks
and the line-breaking algorithm are unchanged.

## Measurements (2026-09-12)

- A deterministic 40-paragraph test reduced hyphen shaping from 2,560 calls to
  40 per layout, with identical page geometry. An alternating local benchmark
  measured medians of approximately 109 ms before and 48 ms after.
- On the connected Android phone, opening the same 65-page chapter without a
  retained session measured 1,021 ms twice before optimization, and 912 ms with
  the hyphen cache in a warmed process. A fresh process still took about 1,178 ms.
- Build 7014 reused the session on subsequent opens. Content was ready in the
  first Flutter frame at 13 ms and 9 ms after the shelf action; saved-position
  and preference restoration took less than 1 ms. These are content readiness
  measurements, not completion times for the platform route animation.

First-time opening still waits for the initial chapter's full pagination.
Incremental, anchor-aware pagination remains a separate opportunity; its
navigation, progress-restoration, and paragraph ownership rules need to remain
consistent before that path can replace full pagination.
