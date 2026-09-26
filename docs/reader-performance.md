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

## Pure-Dart PDF performance (2026-09-22, build 7020)

PDF rendering remains pure Dart. The native Android experiment was withdrawn
after the user confirmed this architectural requirement and was never installed.

- The local `pdf_cos` 3.7.0 override only changes JPEG 2000 inverse-wavelet hot
  loops. It preserves Float32 operation order and sample output; see
  `third_party/pdf_cos/PATCHES.md` for provenance and equivalence checks.
- PDF lookahead prepares the next page first and announces it before preparing
  the previous page. EPUB lookahead order is unchanged.
- Rendered pages use a lossless PNG disk cache, keyed by the actual PDF content
  SHA-256, page index and output dimension. It lives in the app's temporary
  directory, with a 128-page / 256 MiB budget across books. Writes use temporary
  files; completed entries are evicted by last access. Bump the raster cache
  directory version if future renderer changes alter output semantics.
- Cache hits do not start a PDF worker. Fresh renders publish immediately and
  encode/write a cloned image asynchronously. Closing a reader does not discard
  completed cached pages, and cache/disk failures do not block book opening.

### Device results

Same phone (23013RK75C), same book (*My mother was a computer*), 2048-pixel
maximum page dimension. These are application-internal content-ready timings,
not ADB command or route animation durations.

| Measurement | Build 7018 | Build 7020 |
| --- | --- | --- |
| Initial uncached open | 4000 ms | 2786 ms |
| Five repeated opens | 3701–3790 ms; median 3754 ms | 416–430 ms; median 419 ms |
| Background decode sample median | 3423 ms | 2168 ms (4 uncached pages) |

The repeats used nearby saved pages of the same PDF, not a large cross-book
corpus. Build 7020 recorded 18 disk-cache hits during the run. The sampled
background decoding still takes about two seconds for an uncached scanned
page; no claim of instant first-time rendering is made.

Text/image layers were visually checked. No new ANR/crash event was observed
during this run. The test screenshots, raw phase logs and timing summary are
local under `output/torto-pdf-performance-20260922/` in the workspace, outside
this repository. Build 7020 was installed with `adb install -r`, preserving
private data; wireless ADB was left running.
