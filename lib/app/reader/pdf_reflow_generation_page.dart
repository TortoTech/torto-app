import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/formats/pdf/pdf_native_generator.dart';
import '../../l10n/app_localizations.dart';
import 'reader_controller.dart';

class PdfReflowGenerationPage extends StatefulWidget {
  final ReaderController controller;
  final File file;
  const PdfReflowGenerationPage({
    super.key,
    required this.controller,
    required this.file,
  });
  @override
  State<PdfReflowGenerationPage> createState() =>
      _PdfReflowGenerationPageState();
}

class _PdfReflowGenerationPageState extends State<PdfReflowGenerationPage> {
  PdfNativeGenerator? _job;
  Map<String, dynamic>? _stats;
  String? _error;
  int _page = 0, _total = 0, _epoch = 0;
  @override
  void dispose() {
    _epoch++;
    _job?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    final original = widget.controller.pdfSource,
        root = widget.controller.pdfDerivedDirectory;
    if (original == null || root == null || _job != null) return;
    final epoch = ++_epoch, job = PdfNativeGenerator();
    setState(() {
      _job = job;
      _stats = null;
      _error = null;
      _page = 0;
      _total = original.pageCount;
    });
    try {
      final result = await job.generate(
        file: widget.file,
        original: original,
        root: root,
        onProgress: (page, total) {
          if (mounted && epoch == _epoch) {
            setState(() {
              _page = page;
              _total = total;
            });
          }
        },
      );
      if (mounted && epoch == _epoch) {
        await widget.controller.preferPdfTextSource('native');
        if (mounted && epoch == _epoch) setState(() => _stats = result);
      }
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = '$error');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _job = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.text('本地 PDF 重排', 'Local PDF reflow'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            l.text(
              '提取 PDF 自带文字并重新排版；扫描页和复杂图形页保留原图。生成过程在本机完成。',
              'Reflow the PDF’s embedded text. Scans and complex graphic pages retain their original appearance. Processing stays on this device.',
            ),
          ),
          const SizedBox(height: 20),
          if (_job != null) ...[
            LinearProgressIndicator(value: _total > 0 ? _page / _total : null),
            Text('$_page / $_total'),
            TextButton(
              onPressed: () {
                _epoch++;
                _job?.cancel();
                setState(() => _job = null);
              },
              child: Text(l.text('停止', 'Stop')),
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_stats != null)
            Text(
              l.text(
                '已生成：${_stats!['text_pages']} 页文字，${_stats!['fallback_pages']} 页保留原图。重新打开本书后使用本地文字。',
                'Saved: ${_stats!['text_pages']} text pages, ${_stats!['fallback_pages']} original-image pages. Reopen this book to read the local text.',
              ),
            ),
          if (_job == null)
            FilledButton(
              onPressed: _generate,
              child: Text(
                l.text(
                  _stats == null ? '生成本地文字' : '重新生成',
                  _stats == null ? 'Generate local text' : 'Regenerate',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
