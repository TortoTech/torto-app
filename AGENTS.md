# Project Instructions

## GitHub Release Notes

- Keep the release body in `docs/releases/<tag>.md` (for example, `docs/releases/v0.5.0.md`) before pushing a release tag. The Android asset workflow reads this file and uses the tag as the release title.
- Updating release notes does not authorize committing, pushing, or moving an existing tag unless the user explicitly asks for those actions.
- The GitHub Release title must exactly match its tag, including the lowercase `v` prefix (for example, `v0.5.0`). Do not add the product name, dates, subtitles, or descriptive suffixes. This is the release title, not a heading in the release notes body.
- When publishing with the GitHub CLI, explicitly use the tag as the title (for example, `gh release create v0.5.0 --title "v0.5.0" --notes-file <path>`), and verify the published title matches the tag.
- Write release notes in English first, followed by the Simplified Chinese translation inside an HTML `<details>` block.
- The summary tag must be exactly `<summary>中文更新说明</summary>`. Do not rename it or add attributes; the desktop updater uses this exact marker to select notes for the current interface language.
- Write for ordinary users. Lead with what changed in their experience and why it is useful, rather than how it was implemented.
- Prefer plain language and avoid library names, code symbols, architecture details, and other technical terminology unless users need them to understand compatibility or take action.
- Keep the notes concise. Use one short sentence per entry, combine closely related changes, and omit internal maintenance that has no meaningful user-facing effect.
- Classify changes under these headings and keep this order in both language sections:
  1. `## Feature` for new user-facing capabilities.
  2. `## Improvement` for enhancements to existing behavior, usability, performance, or quality.
  3. `## Fix` for corrected defects or regressions.
- Assign each change to one primary category and mention it only once per language. Do not repeat the same work under multiple headings with different wording.
- When a new feature includes supporting refinements, compatibility work, or corrections required to deliver that feature, describe them together in the `Feature` entry. Do not duplicate them as separate `Improvement` or `Fix` entries.
- Distinguish `Improvement` from `Fix` by intent: use `Fix` when previously intended behavior was incorrect, and `Improvement` when existing correct behavior was intentionally enhanced.
- Split work across categories only when the changes are independently meaningful to users and can each stand alone. Prefer one concise entry classified by its primary user-facing outcome when the distinction is uncertain.
- Keep the English and Chinese sections as one-to-one translations with the same categories and item order; neither language section should introduce additional or duplicated entries.
- Use the same English category headings in the Chinese section. Omit a category when it has no entries; do not invent filler items merely to include all three headings.
- Use this structure:

  ```markdown
  ## Feature

  - English description of a new capability.

  ## Improvement

  - English description of an enhancement.

  ## Fix

  - English description of a correction.

  <details>
  <summary>中文更新说明</summary>

  ## Feature

  - 新功能的中文说明。

  ## Improvement

  - 现有功能改进的中文说明。

  ## Fix

  - 问题修复的中文说明。

  </details>
  ```

- Keep all English-only content before `<details>`. Put all Chinese-only content inside the matching `<details>` block.
- If a Full Changelog link should appear in both languages, include it in both sections rather than placing it after `</details>`.

## PDF architecture

- Keep PDF parsing and rendering in the pure-Dart pipeline. The user explicitly chose this constraint when discussing performance; do not introduce Android `PdfRenderer` or another platform PDF renderer unless the user changes that requirement.
- Optimize decoding, scheduling and bounded caches while preserving text/image layers and the requested raster resolution. Validate performance on the actual problem PDF, not only small synthetic documents.

## Android deployment

- Preserve the app's private data during every deployment.
- Install or upgrade APKs with `adb install -r <apk-path>` (and the selected device via `adb -s <device> install -r <apk-path>` when needed).
- Do not use `flutter install`: it may uninstall the existing app before installing the APK and reset private data.
- Never uninstall the existing app as part of deployment unless the user explicitly requests a clean installation and acknowledges the data loss.
- If an in-place upgrade fails, including because of a signing mismatch or downgrade restriction, stop and report the error. Do not automatically uninstall, clear data, or retry with a destructive option.
- Keep wireless ADB running after deployment unless the user explicitly asks to stop it.

### Remote deployment through the laptop

- The normal remote path is: current host -> Tailscale -> the Windows laptop's ADB server -> phone over USB or the laptop's local Wi-Fi.
- Resolve the laptop's current tailnet IPv4 with `tailscale status`; do not assume that the host alias `laptop` resolves for SSH.
- The laptop must expose its ADB server on the tailnet interface. The user can start it on the laptop with `adb -a start-server`; if an existing loopback-only server prevents that, the user may explicitly restart it with `adb kill-server` followed by `adb -a start-server`.
- Do not stop or restart the laptop's ADB server after a successful deployment. In particular, do not run `adb kill-server` as cleanup.
- Check reachability before transferring an APK: TCP port 5037 on the laptop must be open, then run `adb -H <laptop-tailnet-ip> -P 5037 devices -l`.
- A reachable ADB server with an empty device list is not sufficient. For wireless debugging, try `adb -H <laptop-tailnet-ip> -P 5037 connect <phone-ip:port>` using the address shown on the phone. If it times out or pairing is required, ask the user to connect/pair locally on the laptop. USB is the preferred fallback.
- When a USB device appears, use its explicit serial for every subsequent command. Do not rely on an implicit default device.
- The current host's `adb` may not be on `PATH`. Obtain the Android SDK location from `flutter doctor -v` and invoke `<sdk>\platform-tools\adb.exe` directly.

### Build artifact and version preflight

- Prefer an arm64 release APK for the user's phone instead of the universal APK. A universal APK contains arm32, arm64, and x86_64 native libraries and is much larger.
- Build the phone artifact with `flutter build apk --release --split-per-abi --target-platform android-arm64`, adding an explicit `--build-number` when an upgrade code is needed.
- Flutter adds an ABI-specific offset to split APK version codes. For example, an arm64 split built with `--build-number 4010` installs as `versionCode 6010`. Never infer the final code from `pubspec.yaml` alone.
- Before installation, query the installed package with `adb shell dumpsys package com.example.torto` and inspect `versionCode`. Inspect the built APK's final manifest/version code as well. The new APK must have a strictly compatible, non-downgrade code.
- `INSTALL_FAILED_VERSION_DOWNGRADE` is a preflight failure. Do not use `adb install -d`, uninstall the app, or clear its data. Rebuild with a higher compatible build number only after reporting the failure or receiving confirmation to continue.

### Release signing

- Never assume `flutter build --release` produced a release-signed APK. `android/app/build.gradle.kts` intentionally falls back to the Android Debug key when the ignored `android/key.properties` file is absent.
- The local release material is under the gitignored `signing/` directory. The keystore is `signing/torto-upload-keystore.jks`; signing values are stored in `signing/github-secrets.txt`. Never print, commit, or copy those secret values into tracked files.
- The expected Torto release certificate SHA-256 fingerprint is `c46fb307beba870b610ef56995642a11b86e076126ca8173ab00aa25b13e3705` (`CN=Torto Android Release, OU=Mobile, O=TortoTech, C=CN`). The fingerprint is public metadata; passwords and private key material are not.
- Verify every deployment APK with Android build-tools `apksigner verify --print-certs` before installation. If needed, retrieve the installed APK path with `adb shell pm path com.example.torto`, pull it, and compare its certificate fingerprint.
- `INSTALL_FAILED_UPDATE_INCOMPATIBLE` means the APK signature does not match the installed package. Stop immediately. Locate and use the matching release keystore; never solve it by uninstalling or clearing data.
- If local Gradle signing configuration is missing, either restore a gitignored `android/key.properties` or explicitly sign a separate output APK with the local release keystore. Keep passwords in process-local, task-specific environment variables and do not expose them in logs or command text.

### Installation and verification

- Install only after all of these are true: the selected device reports `device`, the APK architecture matches, its final version code is compatible, and its signing certificate matches the installed package.
- Use `adb -H <laptop-tailnet-ip> -P 5037 -s <serial> install -r <apk-path>` for the remote path. A successful result must contain `Success`.
- After installation, verify `versionName`, `versionCode`, and `lastUpdateTime` through `dumpsys package`. Launching the app with `adb shell monkey -p com.example.torto -c android.intent.category.LAUNCHER 1` is acceptable as a final smoke check.
- Report whether installation succeeded, which artifact/version was installed, that private data was preserved, and that the remote ADB service was left running.
