# Torto local PDF codec patch

Based on published `pdf_cos` 3.7.0 from https://github.com/ben-milanko/dart-pdf,
licensed under Apache-2.0 (original LICENSE retained).

Changes:

- `lib/src/filters/jpx.dart`: JPEG 2000 inverse lifting uses parity-strided loops
  and explicit symmetric edge samples instead of per-sample closures, clamps
  and parity branches. Float32 stores and arithmetic order are preserved.
- `pubspec.yaml`: remove workspace resolution so the package is usable as a
  standalone path override. No other library files are changed.

Validation:

- `node tool/check_jpx_transform.mjs <dart-executable>` compares 2,056 signal
  cases against the original 3.7.0 transform, bit-for-bit, including odd/even
  origins, short lengths, reversible 5/3 and irreversible 9/7 wavelets.
- `test/core/pdf_jpx_upstream_test.dart` retains the upstream OpenJPEG fixture
  regressions, adapted only from package:test to flutter_test.
- Six actual decoded image buffers from the affected PDF's pages 16/17/repeated
  16 have identical SHA-256 hashes before and after the change. The book itself
  is not included in the repository.

Local JIT profiling (not an Android latency claim) reduced the large foreground
image's base decode from about 2.1–2.2 seconds to 0.9–1.0 seconds. Run the device
benchmark for application-level results. No native decoder or reduced output
resolution is introduced by this patch.
