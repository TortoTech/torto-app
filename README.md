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
  epub/      # EPUB 容器解析（= crates/formats/epub）
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
进度恢复 已走通。已知限制：表格退化为段落、无首行缩进/上下标、分页在 UI
isolate、node-id 未与 torto `crates/html` 对拍（接同步前必须完成）。
