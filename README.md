<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="112" height="112" alt="Torto app icon">
</p>

<h1 id="torto-for-android" align="center">Torto for Android</h1>

<p align="center">
  A local-first mobile ebook reader powered by a native Dart reading pipeline.<br>
  No WebView, no platform PDF renderer, and direct sync through your own WebDAV storage.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android-3DDC84" alt="Android">
  <img src="https://img.shields.io/badge/UI-Flutter-02569B" alt="Built with Flutter">
  <img src="https://img.shields.io/badge/core-Dart-0175C2" alt="Dart reading core">
</p>

<p align="center">
  <a href="#about">About</a> •
  <a href="#features">Features</a> •
  <a href="#installation">Installation</a> •
  <a href="#privacy">Privacy</a> •
  <a href="#development">Development</a> •
  <a href="#project-status">Project status</a>
</p>

## About

Torto for Android is the mobile companion to the [Torto desktop reader](https://github.com/TortoTech/torto). It brings the same format-neutral reading model to Flutter while keeping parsing, layout, pagination, and rendering in Dart instead of embedding a browser or delegating PDF pages to Android's native renderer.

The app imports books into a cover-first local library, restores reading progress, exposes a hierarchical table of contents, and supports tap or swipe page turns. Readers can choose a consistent **Unified layout** or preserve the typography authored by each book with **Follow book**.

Its core pipeline mirrors the desktop architecture:

```text
formats → Reading IR → layout → renderer
```

The implementation is written independently in Dart. Shared concepts and the WebDAV wire protocol remain compatible with desktop Torto, while the mobile renderer is built on `dart:ui`, Flutter Canvas, and CustomPaint.

## Features

<div align="left">✅ Implemented</div>

| **Feature** | **Description** | **Status** |
| --- | --- | --- |
| **Multi-format support** | Read DRM-free EPUB, MOBI, AZW, AZW3/KF8, FB2, FBZ, CBZ, CHM, and PDF files. | ✅ |
| **Native Dart rendering** | Parse, lay out, paginate, and paint book content without a WebView. | ✅ |
| **Pure-Dart PDF stack** | Parse PDF metadata and page objects in Dart, then render fixed-layout pages through Flutter Canvas without Android `PdfRenderer`. | ✅ |
| **Semantic book layout** | Preserve headings, paragraphs, quotations, nested lists, tables, images, figures, captions, links, citations, and compact footnotes. | ✅ |
| **Unified or authored typography** | Use a consistent reader-controlled layout or follow the book's font sizes, spacing, indentation, alignment, and colors. | ✅ |
| **Cover-first local library** | Import supported files, extract metadata and covers, resume recently used books first, and remove books with a long press. | ✅ |
| **Reading navigation** | Turn pages by tap or swipe, browse a hierarchical table of contents, follow the active chapter, and restore durable reading progress. | ✅ |
| **Direct WebDAV sync** | Sync books and reading state directly with Jianguoyun, InfiniCLOUD, Koofr, HiDrive, Yandex Disk, or a custom WebDAV server. | ✅ Optional |

## Installation

Signed APKs are published on [GitHub Releases](https://github.com/TortoTech/torto-app/releases). Most Android phones should use the `arm64-v8a` build; the release also includes `armeabi-v7a` and `x86_64` variants.

For development builds, clone the repository and build with the current Flutter stable toolchain:

```powershell
flutter pub get
flutter build apk --debug
```

The APK is written to `build/app/outputs/flutter-apk/app-debug.apk`. The current Android build requires API 24 (Android 7.0) or later.

## Privacy

- Imported books, covers, metadata, and reading progress are stored in the app's local data directory.
- Cloud sync is disabled until you configure and enable it.
- WebDAV traffic goes directly from the device to the provider you choose; there is no Torto-operated relay.
- The WebDAV app password is stored with Android-backed secure storage rather than ordinary preferences.
- Torto does not contain advertising or analytics code.

## Development

The format and rendering core lives under `lib/core/` and does not depend on Flutter widgets. `layout` and `render` use only `dart:ui`, keeping the pipeline suitable for further isolate work. The user interface under `lib/app/` is a thin Flutter shell around the library, reader, progress, and sync services.

```text
lib/core/
  formats/   EPUB, FB2/FBZ, CBZ, MOBI/AZW/AZW3, CHM, and PDF adapters
  html_ir/   XHTML to Reading IR conversion and the supported CSS subset
  ir/        format-neutral blocks, inlines, styles, and source locators
  layout/    paragraph shaping and single-column pagination
  render/    page display lists and CustomPaint rendering
lib/app/     library, reader, preferences, progress, and WebDAV sync UI
```

Quality checks:

```powershell
flutter analyze
flutter test
flutter test test/perf/epub_open_benchmark_test.dart
```

Integration and performance tests can use DRM-free fixtures from a sibling `../torto/test-data/` checkout. Missing local fixtures are skipped rather than copied into this repository.

See the desktop project's [native rendering architecture decision](https://github.com/TortoTech/torto/blob/main/docs/adr-0001-native-epub-renderer.md) and [WebDAV sync protocol](https://github.com/TortoTech/torto/blob/main/docs/webdav-sync-v1.md) for the shared design contracts.

## Project status

Torto for Android is Android-first and under active development. DRM-protected books are not supported. The native renderer intentionally implements an ebook-focused HTML/CSS subset rather than browser-level compatibility, so complex fixed-layout publications, vertical writing, Ruby annotations, embedded scripts, and interactive book content may not render completely yet.

Please report reproducible problems in [Issues](https://github.com/TortoTech/torto-app/issues). Include the book format, screenshots, and reproduction steps, but do not upload complete copyrighted books.
