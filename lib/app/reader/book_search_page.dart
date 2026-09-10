import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import '../../core/formats/formats.dart';
import '../../core/ir/block.dart';
import '../../core/ir/book.dart';
import '../../core/ir/text_index.dart';
import '../../l10n/app_localizations.dart';

Future<void> searchWorker((String, String, SendPort) args) async {
  try {
    if (args.$2.trim().isEmpty) {
      args.$3.send('done');
      return;
    }
    final file = File(args.$1);
    final source = await openBook(
      await file.readAsBytes(),
      file.uri.pathSegments.last,
      filePath: file.path,
    );
    var count = 0;
    final titles = <int, String>{};
    void visit(List<TocEntry> toc) {
      for (final entry in toc) {
        if (entry.spineIndex != null) {
          titles.putIfAbsent(entry.spineIndex!, () => entry.label);
        }
        visit(entry.children);
      }
    }

    visit(source.book.toc);
    for (var spine = 0; spine < source.book.spine.length; spine++) {
      final section = await source.parseSection(spine);
      final batch = <TextMatch>[];
      for (final node in sectionTextNodes(section)) {
        for (final (start, end) in sourceMatches(
          node.text,
          args.$2.trim(),
          caseSensitive: false,
        )) {
          final length = node.text.runes.length;
          final before = (start - 60).clamp(0, length);
          final after = (end + 60).clamp(0, length);
          batch.add(
            TextMatch(
              spine,
              titles[spine] ?? '${spine + 1}',
              sourceSlice(node.text, before, after),
              sourceSlice(node.text, start, end),
              SourceRange(
                start: SourceAnchor(
                  spine: section.id,
                  node: node.source.start.node,
                  textOffset: start,
                ),
                end: SourceAnchor(
                  spine: section.id,
                  node: node.source.start.node,
                  textOffset: end,
                ),
              ),
            ),
          );
          count++;
          if (count >= 200) break;
        }
        if (count >= 200) break;
      }
      args.$3.send((batch, (spine + 1) / source.book.spine.length));
      if (count >= 200) break;
    }
    args.$3.send('done');
  } catch (error) {
    args.$3.send({'error': error.toString()});
  }
}

class BookSearchChoice {
  final List<TextMatch> matches;
  final int index;
  const BookSearchChoice(this.matches, this.index);
}

class BookSearchPage extends StatefulWidget {
  final File file;
  const BookSearchPage({super.key, required this.file});
  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  Isolate? _worker;
  ReceivePort? _port;
  int _generation = 0;
  bool _busy = false;
  double _progress = 0;
  String? _error;
  final _results = <TextMatch>[];
  void _cancel() {
    _generation++;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _port?.close();
    _port = null;
  }

  void _changed(String value) {
    _debounce?.cancel();
    _cancel();
    setState(() {
      _results.clear();
      _error = null;
      _busy = value.trim().isNotEmpty;
      _progress = 0;
    });
    if (value.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String value) async {
    final generation = _generation;
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (!mounted || generation != _generation) return;
      if (message case (List<TextMatch> batch, double progress)) {
        setState(() {
          _results.addAll(batch);
          _progress = progress;
        });
      } else {
        setState(() {
          _busy = false;
          if (message is Map) {
            _error = context.l10n.text('搜索失败，请重试', 'Search failed. Try again.');
          }
        });
        _cancel();
      }
    });
    try {
      final isolate = await Isolate.spawn(searchWorker, (
        widget.file.path,
        value,
        port.sendPort,
      ));
      if (!mounted || generation != _generation) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _worker = isolate;
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _error = context.l10n.text(
            '搜索启动失败，请重试',
            'Could not start search. Try again.',
          );
        });
        _cancel();
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        controller: _query,
        autofocus: true,
        onChanged: _changed,
        decoration: InputDecoration(
          hintText: context.l10n.text('搜索原文', 'Search original text'),
          border: InputBorder.none,
          suffixIcon: IconButton(
            onPressed: () {
              _query.clear();
              _changed('');
            },
            icon: const Icon(Icons.clear),
          ),
        ),
      ),
    ),
    body: Column(
      children: [
        if (_busy) LinearProgressIndicator(value: _progress),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error ??
                context.l10n.text(
                  '${_results.length} 条结果${_results.length == 200 ? '（已达上限）' : ''}',
                  '${_results.length} results${_results.length == 200 ? ' (limit reached)' : ''}',
                ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final result = _results[index];
              final parts = result.excerpt.split(
                RegExp(
                  RegExp.escape(result.text),
                  caseSensitive: false,
                  unicode: true,
                ),
              );
              return ListTile(
                title: Text(
                  context.l10n.text(
                    '章节 ${result.title}',
                    'Section ${result.title}',
                  ),
                ),
                subtitle: Text.rich(
                  TextSpan(
                    children: [
                      for (var i = 0; i < parts.length; i++) ...[
                        TextSpan(text: parts[i]),
                        if (i + 1 < parts.length)
                          TextSpan(
                            text: result.text,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                onTap: () => Navigator.pop(
                  context,
                  BookSearchChoice(List.of(_results), index),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
