# GIF formulas and desktop request-contract review

The phone running build 7022 displayed equation (2.5) in *Why You Hear What You Hear* as its original raster, even with AI layout enabled and unified typography selected. The configured model was `RethinkOS · gemini/lite`.

## Reproduced cause

The EPUB uses `ops/images/f0044-01.gif` for that equation. The mobile vision input filter only accepted PNG/JPEG/WebP and silently skipped GIF. This was a mobile compatibility omission, not a missing AI-layout switch.

The same local EPUB reproduces the issue in spine section 12 (`ops/xhtml/ch02.html`), block 150. Its source batch is 147–160 inclusive in the source-heading plan. The original GIF is 2,981 bytes; its lossless first-frame PNG payload is 3,259 bytes. The original resource remains intact for book typography and preview.

GIF normalization now runs outside the UI isolate, with source-size, dimensions, pixel-count and encoded-output limits. Requests and caches deduplicate by original image bytes. Logs record only section/range, candidate/input/conversion counts and sanitized failure categories, never excerpts, credentials or raw provider responses.

## Prompt and JSON Schema alignment

- Replaced the 13,300-byte legacy semantic prompt (including verbose examples) with the desktop v0.6.2 prompt of approximately 6.7 KB. The one intentional scope difference requires groups to remain entirely within a stable mobile target batch, matching local validation.
- Like desktop `window_prompt`, omit heading, quotation, caption or citation guidance when that role has no relevant candidates. Examples unused by the desktop request builder are not sent.
- Put canonical `math_texts` and compact citation candidates inside their owning blocks; add explicit `targets` lists. Citation IDs use desktop-style `c<block>_<paragraph>_<index>` strings. Character offsets and redundant candidate excerpts remain local.
- Preserve direct source text when a block has no canonical math container, particularly standalone quote credits. Numeric-heading context is bounded to eight candidates, with short adjacent excerpts.
- Align math escaping and `<protected/>` markers, style ratios, exact-span descriptions, citation string IDs, and the combined `groups` / `citations` / `formulas` schema. Text requests use the desktop 4,096-token output limit.
- Image requests use short integer IDs and `requested_ids`, nullable negative-result fields, and the desktop field descriptions. Common guidance is combined with only transcription/self-check or only conditional review, using a 16,384-token output limit. Review metadata uses `proposal` and `local_validation_error`.
- Bump semantic cache identity to v4 and image-contract identity to v3; the full prompt/schema contracts participate in cache keys.

The local current-batch request contains 6,648 system-prompt characters, 8,122 user-input characters and 3,916 schema characters. All roles happen to have candidates in that local batch; other batches omit irrelevant guidance.

## Verification and artifact

`test/formula_gif_contract_test.dart` covers GIF pixels/transparency, malformed input, scoped prompts, desktop schema types, escaped source spans, standalone credits and an opt-in regression using the local EPUB. The real book is not added to the repository. Deterministic request tests use HTTP mocks.

Final complete suite with the local EPUB enabled: **456 passed, 3 skipped**. `dart analyze lib test`: **No issues found**. Android arm64 release compilation and certificate/manifest checks passed.

Build 7023 is `0.5.0`, arm64, release-signed with the existing Torto certificate. APK: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`; SHA-256: `D8A48F3E4E3FB66C829F00B5121AC609C76F5A090D34F81D002FED01F4B20888`.

Evidence is under workspace `output/torto-formula-debug-20260926/`.

## Live phone verification — 2026-09-26

- Reconnected to the phone at `192.168.31.160:40551`. Upgraded from 7022 to **0.5.0 / 7023** with `adb install -r`; installation returned `Success`. Verified `lastUpdateTime=2026-09-26 10:23:45`, unchanged first-install time, arm64 compatibility and the existing Torto release certificate.
- Opened the existing book with the user's enabled `RethinkOS · gemini/lite` configuration. This verification used the real configured provider.
- At 10:24:09, section 12 / batch `147:161` reported two candidates, two inputs and two GIF conversions. At 10:24:11 it reported **two recognized formulas, zero fallback items**. The following demanded batch `161:191` reported nine conversions and nine recognized formulas. These counts are request results, not an accuracy claim for every expression.
- Visually confirmed equation **(2.5)** is displayed as rendered mathematics rather than the old white GIF strip. Opened its formula dialog and confirmed that the original GIF remains available, alongside the Copy LaTeX action. Closed the dialog and returned to the equation's reading page. Clipboard contents were not changed during this check.
- Captures: `live-equation-page.png`, `live-preview.png`; sanitized device events: `live-device.log`. Normal reading/navigation updates can affect reading statistics and recent-book order. App data was preserved, and wireless ADB was left running.

## Requested compact preview — build 7024

The follow-up UI request replaces original-image preview with recognized mathematics, removes the dialog title and changes the action label to “复制” / “Copy”. Content height is intrinsic, bounded to 60% of the screen for oversized expressions; the fixed 260-logical-pixel height is removed. Pinch/pan interaction remains available.

Static analysis of the reader page and 11 existing reader/popup tests passed. Build 7024 was installed with `adb install -r` at `2026-09-26 10:33:26`, with the existing release certificate and unchanged first-install time. Device inspection confirmed a compact rendered-formula dialog containing only Copy/Close actions and no title or source image (`dialog-7024-preview.png` / `.xml`).

Artifact: `build/app/outputs/flutter-apk/torto-0.5.0-7024-arm64.apk`; SHA-256 `37F631538324872AE69DA96ABA2143BDCFF67F335B2A27E076E805A25F8E5869`. App data and the wireless ADB connection were preserved.

## Visual spacing refinement — build 7025

The subsequent visual-design request reduces the dialog radius to 14 logical pixels, increases top content padding to 28, separates content and actions by 20, and uses a compact 36-pixel action height with 12-pixel bottom padding. Close uses a secondary foreground; Copy retains the primary action color. Content-sized height and formula zoom remain unchanged.

Reader-page static analysis and the arm64 release build passed. Installed **0.5.0 / 7025** in place at `2026-09-26 10:44:25`, preserving the original install date and data. Inspected the real equation (2.5) popup on the phone (`dialog-7025-preview.png` / `.xml`); the button hit bounds are 95 physical pixels high, down from 126 in the previous style. Returned to the prior reading page after inspection and left wireless ADB running.

Artifact: `build/app/outputs/flutter-apk/torto-0.5.0-7025-arm64.apk`; SHA-256 `031F2905C3315CEDDF2D7E297C0B43C2FCA346D2D07D1ADF400F50E4628E823D`.
