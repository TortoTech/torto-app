# Android 实机部署与复测（2026-09-22）

设备：23013RK75C，arm64，无线 ADB `192.168.31.160:5555`。用户指定书架开始测试时的第 1、2 本：

- EPUB：Computational Models of Reading。
- PDF：My mother was a computer: digital subjects and literary texts。

## 部署

最初安装版本为 0.5.0 / 7015。通过手机 APK SHA-256 与本地 7015 完整包比对确认身份，再验证 Torto release 证书。使用 `adb install -r` 升级至 7017，实测发现渲染回归后修复并以同样方式升级到 7018。

最终包：`build/app/outputs/flutter-apk/torto-0.5.0-7018-arm64-signed.apk`。
最终版本：0.5.0 / 7018，更新时间 2026-09-22 20:17:10。
证书 SHA-256：`c46fb307beba870b610ef56995642a11b86e076126ca8173ab00aa25b13e3705`。
首次安装时间仍为 2026-08-30 08:47:45；没有卸载、清空数据或回退版本。

## 实测发现并修复

### PDF 文字层遗漏

7017 能打开扫描 PDF，但多页只显示纸张底图。Poppler 对同一本书第 16 页的参考渲染显示完整正文，资源检查显示两个 JPX 图像以及 JBIG2 软蒙版。不是原文件没有文字。

根因是 worker 使用 `sourceReference` 表示图片源，返回的多个请求暂时共享占位 stream。接入方未把引用绑定回本地 PDF 文档，而 Canvas 图片缓存按 stream 身份去重，导致底图和文字层共用错误的缓存身份。

7018 在回放前回绑图片源，并递归处理软蒙版和重复图案子命令，保留 worker 已解码像素及图层属性。继续在后台解码，没有将重计算退回 UI，也没有引入新的原生 PDF 引擎。

新增两张不同颜色 XObject 的确定性回归，以及嵌套蒙版/重复图案引用测试。实际问题书籍另作可选回归（环境变量 `TORTO_PDF_MASK_FIXTURE`），用同页截图和前景像素验证：修复前 worker 前景像素计数 0，修复后 2359；原路径 7513。两条路径的降采样不同，因此计数不是像素等价指标；完整正文通过截图逐页核对。

手机 7018 的第 7 章首页、Prologue 第 1/2 页均已确认正文恢复；对应截图仅保存在本地测试输出目录，不提交书籍内容。

### 云同步超大缓存行

7017 实机日志反复出现 `Row too big to fit into CursorWindow`，SQL 为读取 `meta` 中 `transfer:` 缓存。错误中断全量检查，引起反复 GET/PROPFIND。

7018 在事务内使用 SQL `substr(CAST(value AS BLOB), …)` 每次取最多 256 KiB，最后统一解码 UTF-8；兼容既有缓存，不删除同步数据。回归涵盖超过 2 MiB、多字节字符跨块、NUL、空串和账户隔离。

手机升级后全量同步记录为 `status=success`，随后阅读同步也成功；检查期间没有再次出现该 CursorWindow 错误。

## 验证证据

所有原始记录位于工作区 `output/torto-device-test-20260922/`：

- `device-logcat.txt`：两个版本的连续日志，按 PID/时间区分。
- `translation-cycles-7017.json`：20 次开关动作全部响应；实际译文另有截图确认。
- `pdf-cycles-7017.json`：5 次打开返回、1 次加载中返回成功，后续因 ADB 日志传输超时中断，不能记作 10 次通过。
- `pdf-cycles-7018.json`：最终版本重复打开和取消测试结果。
- `translation-cycles-7018.json`：最终版本 20 次开关动作全部响应；另检查真实中文译文及前后翻页。
- `pdf7018-prologue2.png` 与 `pdf-reference-16.png`：修复后手机页与原文件参考页。
- `pdf-repro-final.txt`：实际 PDF 及多图层专项 3 项通过。
- `fix-full-tests.txt`：完整 Flutter 回归 387 项通过、2 项跳过；之后新增的嵌套引用测试已包含在上述专项中。
- `fix-analyze-final.txt`：静态分析无问题。
- `build7018.txt`：release 构建退出码 0；符号位于 `build/symbols/7018`。

最终版本的 PDF 自动复测完成 5 次正常打开返回和 5 次加载中返回，全部保持同一进程、成功回到书架；另外人工核对章节跳转、翻页、前后台切换及正文截图。`exit-final7018.txt` 中没有测试期新增的 ANR/崩溃退出，`anr-events-final7018.txt` 也没有新 ANR/崩溃事件。先前退出历史新增项仅为两次安装导致的 PACKAGE UPDATED。

已实测设置页导出，手机文件为 `Download/torto-diagnostics.txt`，本地副本为 `diagnostics-export7018.txt`。按 7018 启动时间过滤后：没有事件循环延迟报警，记录到 1 个 135ms 慢帧；PDF 后台记录阶段中位 3423ms、最大 3810ms，UI 图片回放中位 18ms、最大 26ms，光栅化中位 3ms、最大 5ms。ADB 往返及 UI dump 自带数秒等待，自动化脚本的总耗时不能当作应用触摸响应延迟。

测试结束停留在书架，关闭了测试开启的翻译，ADB 服务和无线连接保留。7018 安装包 SHA-256 为 `9F6E9D7AE0B15EC70E620DF9AAB10ABA5BE5C6532F0F8FDB923704E6B81DD651`。

测试会正常触发阅读进度/统计记录，书架按最近阅读发生了排序变化；不把这些操作描述成“所有应用状态完全未变”。没有执行 Git 提交或对外上传测试资料。

## 结论边界

实机最初发现的是渲染回归，不能把“未出现 ANR”当成版本已通过。修复后再检查显示与操作。PDF 首次页面仍有数秒后台处理时间；这与触摸事件连续 5 秒不被处理的 ANR 不同。有限轮次没有复现，不能保证所有书籍和长期使用都不会卡死。
