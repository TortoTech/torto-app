import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/ir/ir.dart' show ImageBlock;
import '../../l10n/app_localizations.dart';
import '../ai/ai_settings_store.dart';
import '../ai/assistant_settings.dart';
import '../ai/pdf_discovery_service.dart';
import '../settings/assistant_settings_page.dart';
import 'reader_controller.dart';

class PdfDiscoveryPage extends StatefulWidget {
  final ReaderController controller;
  final Directory booksDirectory;
  const PdfDiscoveryPage({
    super.key,
    required this.controller,
    required this.booksDirectory,
  });
  @override
  State<PdfDiscoveryPage> createState() => _PdfDiscoveryPageState();
}

class _PdfDiscoveryPageState extends State<PdfDiscoveryPage> {
  PdfDiscoveryService? _service;
  PdfDiscoveryResult? _result;
  String? _error;
  int _inspected = 0, _epoch = 0;
  bool _applying = false;
  final Set<String> _goals = {'metadata', 'toc', 'special_pages'};
  void _stop() {
    _epoch++;
    _service?.cancel();
    setState(() => _service = null);
  }

  @override
  void dispose() {
    _epoch++;
    _service?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final source = widget.controller.pdfSource;
    if (source == null || _service != null) return;
    final epoch = ++_epoch, service = PdfDiscoveryService();
    setState(() {
      _service = service;
      _error = null;
      _inspected = 0;
      _result = null;
    });
    try {
      final ai = await AiSettingsStore().load(),
          settings = await const AssistantSettingsStore().load();
      if (!mounted || epoch != _epoch) return;
      final provider = settings.provider(ai);
      if (provider == null) {
        throw StateError(
          context.l10n.text(
            '请先配置阅读助手模型',
            'Configure a reading assistant model first',
          ),
        );
      }
      final result = await service.discover(
        bookId: source.book.id,
        pageCount: source.pageCount,
        provider: provider,
        model: settings.resolvedModel(ai),
        goals: Set.of(_goals),
        pageText: (page) async => source.pageText(page - 1)?.text ?? '',
        pageCrop: (page, rect) async {
          final section = await source.parseSection(page - 1);
          final image = await source.rasterResource(
            section.blocks.whereType<ImageBlock>().first.href,
            maxDimension: 2000,
          );
          if (image == null) {
            throw const FormatException('Could not render crop');
          }
          ui.Image? cropped;
          ui.Picture? picture;
          try {
            final area = ui.Rect.fromLTWH(
              rect[0] * image.width,
              rect[1] * image.height,
              rect[2] * image.width,
              rect[3] * image.height,
            );
            final recorder = ui.PictureRecorder();
            ui.Canvas(recorder).drawImageRect(
              image,
              area,
              ui.Rect.fromLTWH(0, 0, area.width, area.height),
              ui.Paint(),
            );
            picture = recorder.endRecording();
            cropped = await picture.toImage(
              area.width.ceil().clamp(1, 2000),
              area.height.ceil().clamp(1, 2000),
            );
            final data = await cropped.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              throw const FormatException('Could not encode crop');
            }
            return base64Encode(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
          } finally {
            cropped?.dispose();
            picture?.dispose();
            image.dispose();
          }
        },
        pageImage: (physicalPage) async {
          final section = await source.parseSection(physicalPage - 1);
          final href = section.blocks.whereType<ImageBlock>().first.href;
          final image = await source.rasterResource(href, maxDimension: 1000);
          if (image == null) {
            throw const FormatException('Could not inspect PDF page');
          }
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            if (data == null) {
              throw const FormatException('Could not encode PDF page');
            }
            return base64Encode(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
          } finally {
            image.dispose();
          }
        },
        onProgress: (count) {
          if (mounted && epoch == _epoch) setState(() => _inspected = count);
        },
      );
      if (mounted && epoch == _epoch) setState(() => _result = result);
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = error.toString());
    } finally {
      service.cancel();
      if (mounted && epoch == _epoch) setState(() => _service = null);
    }
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      await widget.controller.applyPdfDiscovery(
        _result!,
        widget.booksDirectory,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, result = _result;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.text('识别 PDF 目录', 'Discover PDF contents')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _service != null
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const AssistantSettingsPage(),
                    ),
                  ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l.text(
              'AI 按需查看页面，识别书名、作者和目录，并核验实际跳转页。页面预览会发送给所选模型；草稿保留以便重试。',
              'AI inspects pages as needed to identify book metadata and verify TOC destinations. Page previews are sent to your selected model; drafts are retained for retries.',
            ),
          ),
          const SizedBox(height: 16),
          for (final goal in ['metadata', 'toc', 'special_pages'])
            CheckboxListTile(
              title: Text(switch (goal) {
                'metadata' => l.text('书名和作者', 'Title and authors'),
                'toc' => l.text('目录及目标页', 'Contents and destinations'),
                _ => l.text('特殊页面', 'Special pages'),
              }),
              value: _goals.contains(goal),
              onChanged: _service != null
                  ? null
                  : (selected) => setState(() {
                      if (selected == true) {
                        _goals.add(goal);
                      } else {
                        _goals.remove(goal);
                      }
                    }),
            ),
          FilledButton(
            onPressed: _applying || _goals.isEmpty
                ? null
                : _service == null
                ? _start
                : _stop,
            child: Text(
              _service == null
                  ? l.text('识别并核验', 'Discover and verify')
                  : l.text('停止', 'Stop'),
            ),
          ),
          if (_service != null) ...[
            const LinearProgressIndicator(),
            Text(l.text('已查看 $_inspected 页', 'Inspected $_inspected pages')),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (result != null) ...[
            Text(
              result.status == 'partial'
                  ? l.text(
                      '部分完成，仅应用已核验结果',
                      'Partially complete; apply verified results only',
                    )
                  : l.text('识别完成', 'Discovery complete'),
            ),
            Text(result.title, style: Theme.of(context).textTheme.titleLarge),
            Text(result.authors.join(', ')),
            Text(
              l.text(
                '已核验 ${result.entries.length} 个目录目标',
                '${result.entries.length} verified destinations',
              ),
            ),
            for (final entry in result.entries)
              ListTile(
                contentPadding: EdgeInsets.only(
                  left: ((entry['depth'] as int).clamp(0, 6) * 12).toDouble(),
                ),
                title: Text(entry['title'] as String),
                trailing: Text('${entry['physical_page']}'),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed:
                  _applying ||
                      result.title.isEmpty &&
                          result.authors.isEmpty &&
                          result.entries.isEmpty
                  ? null
                  : _apply,
              child: Text(l.text('应用识别结果', 'Apply discovered metadata')),
            ),
          ],
        ],
      ),
    );
  }
}
