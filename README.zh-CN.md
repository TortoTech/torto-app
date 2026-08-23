<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="112" height="112" alt="Torto 小龟阅读 Android 图标">
</p>

<h1 id="torto-android" align="center">Torto · 小龟阅读 Android 版</h1>

<p align="center">
  一款使用原生 Dart 阅读管线、本地优先的 Android 电子书阅读器。<br>
  不依赖 WebView，不调用 Android 原生 PDF 渲染器，并通过用户自己的 WebDAV 直接同步。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android-3DDC84" alt="支持 Android">
  <img src="https://img.shields.io/badge/UI-Flutter-02569B" alt="使用 Flutter 构建">
  <img src="https://img.shields.io/badge/core-Dart-0175C2" alt="Dart 阅读内核">
</p>

<p align="center">
  <a href="#认识-torto-android-版">产品介绍</a> •
  <a href="#主要功能">主要功能</a> •
  <a href="#安装与使用">安装与使用</a> •
  <a href="#数据与隐私">数据与隐私</a> •
  <a href="#开发者信息">开发者信息</a> •
  <a href="#当前说明">当前说明</a>
</p>

## 认识 Torto Android 版

Torto Android 版是 [Torto 桌面阅读器](https://github.com/TortoTech/torto)的移动端伙伴。它将同一套与格式无关的阅读模型带到 Flutter，同时坚持使用 Dart 自行完成解析、排版、分页与渲染，而不是嵌入浏览器，也不把 PDF 页面交给 Android 原生渲染器。

应用提供封面式本地书架，可以恢复阅读进度、浏览层级目录，并通过点击或滑动翻页。阅读时既可以选择由阅读器统一控制的**统一版式**，也可以通过**跟随书籍**保留电子书自带的排版。

核心管线与桌面端架构保持对应：

```text
formats → Reading IR → layout → renderer
```

移动端代码使用 Dart 独立实现。Reading IR 等设计概念及 WebDAV 传输协议与桌面端兼容，具体渲染则建立在 `dart:ui`、Flutter Canvas 与 CustomPaint 之上。

## 主要功能

<div align="left">✅ 已实现</div>

| **功能** | **说明** | **状态** |
| --- | --- | --- |
| **多格式支持** | 阅读无 DRM 的 EPUB、MOBI、AZW、AZW3/KF8、FB2、FBZ、CBZ、CHM 与 PDF 文件。 | ✅ |
| **原生 Dart 渲染** | 不使用 WebView，由 Dart 完成书籍解析、排版、分页与页面绘制。 | ✅ |
| **纯 Dart PDF 管线** | 使用 Dart 解析 PDF 元数据与页面对象，并通过 Flutter Canvas 渲染固定版式页面，不依赖 Android `PdfRenderer`。 | ✅ |
| **语义化正文排版** | 保留标题、段落、引用、多级列表、表格、图片、Figure 图注、链接、引用标记与紧凑脚注。 | ✅ |
| **统一或原书版式** | 可以使用阅读器统一排版，也可以跟随书籍自带的字号、间距、缩进、对齐与颜色。 | ✅ |
| **封面式本地书架** | 导入支持的文件，提取元数据与封面，优先展示最近使用的书籍，并可长按删除。 | ✅ |
| **阅读导航** | 支持点击或滑动翻页、层级目录、当前章节跟随和稳定的阅读进度恢复。 | ✅ |
| **WebDAV 直接同步** | 直接通过坚果云、InfiniCLOUD、Koofr、HiDrive、Yandex Disk 或自定义 WebDAV 同步书籍与阅读状态。 | ✅ 可选 |

## 安装与使用

正式签名 APK 会发布到 [GitHub Releases](https://github.com/TortoTech/torto-app/releases)。大多数 Android 手机应下载 `arm64-v8a` 版本，同时也提供 `armeabi-v7a` 和 `x86_64` 构建。

开发构建可以克隆仓库后使用当前 Flutter stable 工具链完成：

```powershell
flutter pub get
flutter build apk --debug
```

APK 将生成在 `build/app/outputs/flutter-apk/app-debug.apk`。当前 Android 构建要求 API 24（Android 7.0）或更高版本。

## 数据与隐私

- 导入的电子书、封面、元数据与阅读进度保存在应用本地数据目录。
- 云同步默认关闭，只有完成配置并主动启用后才会运行。
- WebDAV 由手机直接连接用户选择的服务，不经过 Torto 自建中转服务器。
- WebDAV 应用密码保存在 Android 支持的安全存储中，而不是普通偏好设置。
- Torto 不包含广告或统计分析代码。

## 开发者信息

格式与渲染内核位于 `lib/core/`，不依赖 Flutter widgets；其中 `layout` 与 `render` 只使用 `dart:ui`，为后续进一步 isolate 化保留空间。`lib/app/` 则是围绕书架、阅读器、偏好设置、进度和同步服务构建的轻量 Flutter UI。

```text
lib/core/
  formats/   EPUB、FB2/FBZ、CBZ、MOBI/AZW/AZW3、CHM 与 PDF 适配器
  html_ir/   XHTML → Reading IR 与支持的 CSS 子集
  ir/        与格式无关的 Block、Inline、样式和原文定位
  layout/    段落塑形与单栏分页
  render/    页面显示列表与 CustomPaint 渲染
lib/app/     书架、阅读器、偏好设置、进度和 WebDAV 同步 UI
```

质量检查：

```powershell
flutter analyze
flutter test
flutter test test/perf/epub_open_benchmark_test.dart
```

集成与性能测试可以引用相邻 `../torto/test-data/` checkout 中无 DRM 的测试书籍；本地缺少夹具时会自动跳过，不会将电子书复制进本仓库。

共享设计约定可参阅桌面端的[原生渲染架构决策](https://github.com/TortoTech/torto/blob/main/docs/adr-0001-native-epub-renderer.md)与 [WebDAV 同步协议](https://github.com/TortoTech/torto/blob/main/docs/webdav-sync-v1.md)。

## 当前说明

Torto Android 版目前以 Android 为优先平台，并仍在持续开发。应用不支持带 DRM 的电子书。原生渲染器只实现面向电子书的 HTML/CSS 子集，而不追求完整浏览器兼容，因此复杂固定版式、竖排、Ruby 注音、内嵌脚本以及部分书内交互内容仍可能无法完整显示。

如果遇到可复现的问题，欢迎在 [Issues](https://github.com/TortoTech/torto-app/issues) 中反馈，并附上电子书格式、问题截图和复现步骤。请勿上传受版权保护的完整书籍。
