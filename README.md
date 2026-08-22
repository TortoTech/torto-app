# torto-app

Torto 的手机端（Android 优先）。纯 Dart 实现的电子书阅读器，架构移植自桌面端
[torto](../torto) 的渲染管线（见 `../torto/docs/adr-0001-native-epub-renderer.md`）：

```
formats → Reading IR → layout → render
```

## 结构

```
lib/core/
  ir/        # Reading IR：Block/Inline/SourceAnchor/LocatorV1（= crates/publication）
  formats/   # 全部格式（= crates/formats）：
             #   book_format / open     格式检测 + 统一入口 openBook
             #   epub_book_source       EPUB 容器解析（zip/OPF/NCX/nav）
             #   fb2_book_source        FB2 与 FBZ（zip 包装）→ XHTML 片段走 HTML→IR 管线
             #   cbz_book_source        漫画页 → ImageBlock（ComicInfo.xml 元数据）
             #   mobi/                  PDB 容器 + PalmDOC/HUFF-CDIC 解压 + KF8
             #                         （SKEL/FRAG/INDX）+ MOBI6 分章（= mobi.rs/kf8.rs）
             #   chm/                   ITSF 容器 + 纯 Dart LZX 解压器 + HHC 目录
             #                         （= chm.rs，chmlib 的纯 Dart 替代）
             #   pdf/                   纯 Dart PDF 解析 + 文本提取：对象/xref/
             #                         ObjStm、Flate+预测器、ToUnicode CMap、
             #                         内容流文本（结构对齐 pdf.rs，以文本替代
             #                         hayro 光栅化）
             #   direct_book_source     内存型 BookSource 基座（fb2/cbz/mobi/pdf 共用）
  html_ir/   # XHTML→IR + CSS 子集（= crates/html）
  layout/    # 分页引擎 Paginator（= crates/layout），仅用 dart:ui
  render/    # CustomPaint 页面渲染（= crates/renderer）
lib/app/     # 薄 UI 壳：书架导入、阅读器、进度恢复（LocatorV1）
```

约束：`core/` 不依赖 Flutter widgets（layout/render 仅用 `dart:ui`），为后续
isolate 化预留。

## 构建与测试

本机 Git Bash 环境下 `flutter.bat` 不可用（cmd 继承的 PATH 缺 git），统一使用
包装脚本：

```bash
bash tool/f.sh pub get
bash tool/f.sh analyze
bash tool/f.sh test                    # 全部测试
bash tool/f.sh test test/perf/benchmark_test.dart   # 真实书籍性能基准
```

APK 构建（Gradle 内部会调 flutter.bat，需要在 cmd 里显式补 PATH）：

```bash
cmd //c "set PATH=C:\Windows\System32;C:\Program Files\Git\cmd;%PATH% && D:\flutter\bin\flutter.bat build apk --debug"
```

## 测试数据

集成测试引用 `../torto/test-data/` 下的真实电子书（不复制进仓库，文件缺失时自动跳过）。

## 当前里程碑状态

垂直切片（walking skeleton）：EPUB 导入 → 解析 → 分页 → 渲染 → 翻页 →
进度恢复 已走通。多格式：torto 支持的九种格式已全部接入——EPUB、
FB2/FBZ、CBZ、MOBI/AZW/AZW3（KF8 与 MOBI6，含 PalmDOC/HUFF-CDIC 解压）、
CHM（ITSF + 纯 Dart LZX 解压器）、PDF（纯 Dart 解析 + 文本提取）。书架与
阅读器统一走 `BookSource`，全部格式均以 `../torto/test-data/` 真实书籍
做了集成测试（期望值与 Rust 侧夹具测试一致）。

已知限制：表格退化为段落、无首行缩进/上下标、分页在 UI isolate、node-id
未与 torto `crates/html` 对拍（接同步前必须完成）、CBZ 漫画页无固定布局
（PrePaginated）模式按可重排版式缩放、PDF 以文本模式阅读（torto 为 hayro
光栅化 + 文本层；此处无光栅化——扫描版/纯图片 PDF 无法提取文本，多栏
或复杂版式的阅读顺序按 y-x 启发式近似，混排空格可能偏多）、CHM 的 CJK
字符集（GB2312/Big5/Shift-JIS）按 Windows-1252 回退解码会乱码、MOBI 的
`kindle:pos:fid:off:` TOC 链接目标未映射为页内锚点。
