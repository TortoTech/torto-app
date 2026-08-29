# Project Instructions

## Android deployment

- Preserve the app's private data during every deployment.
- Install or upgrade APKs with `adb install -r <apk-path>` (and the selected device via `adb -s <device> install -r <apk-path>` when needed).
- Do not use `flutter install`: it may uninstall the existing app before installing the APK and reset private data.
- Never uninstall the existing app as part of deployment unless the user explicitly requests a clean installation and acknowledges the data loss.
- If an in-place upgrade fails, including because of a signing mismatch or downgrade restriction, stop and report the error. Do not automatically uninstall, clear data, or retry with a destructive option.
- Keep wireless ADB running after deployment unless the user explicitly asks to stop it.
