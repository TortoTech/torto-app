# Desktop 0.6.2 parity

The September 26 review compared desktop tag `v0.6.2` (`d174a93`) with the mobile working tree, including its existing uncommitted September 22 ports. This implementation adds the selected P0/P1 changes; it does not replace those earlier changes.

## Content and typography

- Tables retain `before` / `after` text. Native captions honor inherited `caption-side`; nearby numbered labels and explicitly scoped titles, notes and sources attach to their table. Transparent wrappers do not break association. Separate table containers establish ownership; ambiguous labels between unscoped tables and prose references remain in place.
- Images carrying tables can acquire preceding and following captions without OCR. The P2 audit added a separate trailing-caption list so two-sided labels and source notes stay with their image in authored order.
- Table captions and notes participate in reading order, search, selection/copy, footnotes, inline-image loading, hyphenation and translation. Existing cell translation segment indices remain unchanged; added annotation segments follow the cells in the translation protocol. Replacement and bilingual translations retain their source ranges.
- Pagination keeps a leading title with the first safe row group and a trailing note with the last group when the combination fits a page. Captions are not repeated on continuation pages. Oversized content retains normal overflow behavior.
- Nested block markup inside paragraph/link wrappers preserves separate figures, captions, surrounding prose, inherited links and source anchors. Ordinary inline symbol images remain inline.
- Unified typography converts inherited Chinese italic text to bold while retaining Latin italics and authored book typography. Existing citation semantics retain their distinct treatment.

## AI layout

See [AI semantic layout](ai-semantic-layout.md) for the scheduling and cache contract. The changes include stable 5,000-character source batches, visible-subsection demand, one combined text recognition request, ordinary unnumbered headings, duplicate/no-op handling, reasoning-effort settings, cancellation and coordinated translation refresh.

Known semantic groups are indivisible; the character budget is not a hard maximum for an oversized paragraph/group and excludes context/prompt overhead. Context cannot itself be annotated. New AI headings do not rewrite the source plan or TOC.

## Scope and verification

Regression tests are in `test/core/desktop_062_parity_test.dart`, `test/semantic_layout_test.dart`, `test/semantic_layout_cache_test.dart` and `test/reader_semantic_scheduling_test.dart`. They cover parser ownership/anchors, pagination at several heights, translation, cache invalidation, cancellation and reader refresh sequencing. Model requests use controlled providers; no live AI requests were made.

The second implementation batch adds inline literature-reference folding, HTTP(S) website icons and image/text formula recognition. No commit, push, release, or phone installation is included in this change. Existing private phone data and the pure-Dart PDF architecture are untouched.

Validation logs are in workspace `output/torto-app-parity-20260926/`.

- Final complete Flutter suite: **432 passed, 3 skipped**.
- `dart analyze lib test`: **No issues found**.
- No live provider calls or device deployment were performed. The Windows test runtime uses its existing fallback when `hyphen_ffi.dll` is unavailable; device hyphenation performance was not measured in this run.

## P2 audit and corrections

- Two-sided image-table annotations now compose, translate and paginate together. Table/figure source notes use annotation sizing and start alignment without inheriting body paragraph indentation; their group-height reservation includes both caption gaps.
- Re-entering the reader with identical AI settings preserves successful recognition and translation. Failed batches remain retryable. Existing-quote attribution no-ops no longer trigger correction requests.
- Inline annotation preparation precedes translation, with strict formula/reference/link placeholders and affected-block invalidation. In-flight translation results are guarded against semantic revision changes.
- Formula-image originals are loaded and retained for preview even when the page displays a generated formula. External equation numbers are not duplicated; disagreements fall back to source images.
- Text formula spans preserve source offsets and script boundaries. Conflicting overlaps are rejected together; duplicate proposals are harmless. Failed image review does not become a permanently cached success.
- Temporary math render trees are cleaned up without an asynchronous gap that could strand a system-font callback. Real-font light/dark narrow-page rendering and mathematical baseline geometry are covered by tests.
- Canonical inline recognition input is prepared off the UI isolate, and target paragraphs are not sent twice in the same request.

P2 regression suites: `test/core/p2_inline_test.dart`, `test/formula_image_service_test.dart`, `test/p2_pipeline_test.dart`, `test/p2_visual_test.dart`, and `test/p2_reference_sheet_test.dart`. The existing reader scheduling suite also checks unchanged-configuration reloads. Test providers are HTTP mocks; no paid/live recognition was used. Verification logs and inspected PNGs are under workspace `output/torto-app-p2-20260926/`.

P2 final verification: **450 tests passed, 3 skipped**; `dart analyze lib test` reports **No issues found**; `git diff --check` passes. Both light and dark real-font previews were rendered, and the generated images were inspected for inline fractions, display integrals/scripts, numbered reference markers and website icons.

Android arm64 release compilation passed with `flutter build apk --release --split-per-abi --target-platform android-arm64 --no-pub --build-number 5022`; output: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. This build was not installed. The existing Kotlin Gradle Plugin migration warning remains; it did not fail this build.

Formula layout uses [flutter_math_fork](https://github.com/vurilo/flutter_math_fork), integrated into the existing Flutter Canvas reader. Fixed PDFs remain excluded. Image recognition accepts PNG/JPEG/WebP resources and normalizes GIF first frames to PNG; unsupported image encodings keep the existing representation. Automated tests establish software behavior, not general model transcription accuracy or long-session phone performance.
