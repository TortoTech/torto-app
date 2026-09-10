# Project Instructions

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
