import 'dart:convert';
import 'assistant_rich_text.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../ai/ai_settings_store.dart';
import '../ai/assistant_settings.dart';
import '../ai/chat_assistant.dart';
import '../settings/assistant_settings_page.dart';
import '../ai/reader_book_tools.dart';

class ChatPage extends StatefulWidget {
  final String bookId, title, excerpt, blockId, file;
  final ReaderBookTools? tools;
  final ValueChanged<Uri>? onBookReference;
  const ChatPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.excerpt,
    required this.blockId,
    required this.file,
    this.tools,
    this.onBookReference,
  });
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _replyPending = false;
  List<Map<String, String>> _messages = [];
  ChatAssistant? _request;
  bool _bookScope = false, _loading = true;
  int _epoch = 0;
  String? _error;
  Future<Map<String, dynamic>> _bookTool(
    String action,
    Map<String, dynamic> arguments,
  ) async {
    final epoch = _epoch;
    final result = await widget.tools!.execute(
      action,
      arguments,
      wholeBook: _bookScope,
    );
    if (result['pending_confirmation'] != true || !mounted) return result;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.text('确认修改', 'Confirm change')),
        content: SingleChildScrollView(
          child: Text(
            '${result['quote'] ?? ''}\n${result['note'] ?? ''}\n${result['original'] ?? ''}\n${result['blocks'] ?? ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.text('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.text('应用', 'Apply')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted || epoch != _epoch) {
      return {'status': 'cancelled', 'applied': false};
    }
    final applied = await widget.tools!.execute(
      action,
      arguments,
      wholeBook: _bookScope,
      confirmed: true,
    );
    if (mounted) setState(() {});
    return applied;
  }

  String get _key =>
      'assistant_chat_v1_${sha256.convert(utf8.encode(jsonEncode([widget.bookId, _bookScope ? 'book' : widget.blockId])))}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, String>> messages = [];
    try {
      messages = (jsonDecode(prefs.getString(_key) ?? '[]') as List)
          .whereType<Map>()
          .where(
            (m) =>
                const {'user', 'assistant'}.contains(m['role']) &&
                m['content'] is String,
          )
          .take(100)
          .map(
            (m) => {
              'role': m['role'] as String,
              'content': m['content'] as String,
            },
          )
          .toList();
    } catch (_) {}
    if (mounted && epoch == _epoch) {
      setState(() {
        _messages = messages;
        _loading = false;
      });
      _scrollToEnd(force: true);
    }
  }

  void _scrollToEnd({bool force = false}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _scroll.hasClients &&
            (force ||
                _scroll.position.maxScrollExtent - _scroll.offset < 160)) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });

  Future<void> _persist(String key, List<Map<String, String>> messages) async {
    await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode(messages),
    );
  }

  void _cancel() {
    _epoch++;
    _request?.cancel();
    setState(() {
      _request = null;
      if (_replyPending && _messages.lastOrNull?['role'] == 'assistant') {
        _messages.removeLast();
      }
      _replyPending = false;
      if (_messages.lastOrNull?['role'] == 'user') {
        _input.text = _messages.removeLast()['content']!;
      }
    });
  }

  @override
  void dispose() {
    _epoch++;
    _request?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || text.length > 10000 || _request != null) return;
    final epoch = ++_epoch, key = _key;
    final request = ChatAssistant();
    setState(() {
      _request = request;
      _error = null;
      _messages.add({'role': 'user', 'content': text});
      if (_messages.length > 100) {
        _messages.removeRange(0, _messages.length - 100);
      }
      _input.clear();
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
      final history = List<Map<String, String>>.of(_messages);
      final replyIndex = _messages.length;
      setState(() {
        _replyPending = true;
        _messages.add({'role': 'assistant', 'content': ''});
      });
      _scrollToEnd(force: true);
      final answer = await request.answer(
        provider: provider,
        model: settings.resolvedModel(ai),
        settings: settings,
        history: history,
        title: widget.title,
        context: widget.excerpt,
        bookFile: _bookScope ? widget.file : null,
        bookTool: widget.tools == null ? null : _bookTool,
        bookInfo: widget.tools == null
            ? const {}
            : await _bookTool('getBookMetadata', {}),
        onPartial: (partial) {
          if (mounted && epoch == _epoch && replyIndex < _messages.length) {
            setState(() => _messages[replyIndex]['content'] = partial);
            _scrollToEnd();
          }
        },
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _replyPending = false;
        _messages[replyIndex]['content'] = answer;
      });
      if (_messages.length > 100) {
        _messages.removeRange(0, _messages.length - 100);
      }
      await _persist(key, List.of(_messages));
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _error = error.toString();
          _input.text = text;
          if (_replyPending && _messages.lastOrNull?['role'] == 'assistant') {
            _messages.removeLast();
          }
          _replyPending = false;
          if (_messages.lastOrNull?['role'] == 'user') _messages.removeLast();
        });
      }
    } finally {
      request.cancel();
      if (mounted && epoch == _epoch) setState(() => _request = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.text('阅读助手', 'Reading assistant')),
        actions: [
          if (widget.tools?.controller.hasTemporaryRewrites == true)
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: l.text('还原临时改写', 'Undo temporary rewrites'),
              onPressed: _request != null
                  ? null
                  : () async {
                      await widget.tools!.controller.clearTemporaryRewrites();
                      if (mounted) setState(() {});
                    },
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l.text('助手设置', 'Assistant settings'),
            onPressed: _request != null
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
      body: Column(
        children: [
          SwitchListTile(
            title: Text(l.text('结合全书查找', 'Search within the book')),
            subtitle: Text(
              _bookScope
                  ? widget.title
                  : l.text('当前激活内容', 'Active reading block'),
            ),
            value: _bookScope,
            onChanged: _request != null || _loading
                ? null
                : (value) {
                    setState(() {
                      _bookScope = value;
                      _loading = true;
                      _messages = [];
                      _error = null;
                    });
                    _load();
                  },
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _messages[i]['role'] == 'user'
                                ? l.text('你', 'You')
                                : 'Torto',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          AssistantText(
                            _messages[i]['content']!,
                            onBookReference: widget.onBookReference,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_request != null) const LinearProgressIndicator(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 10000,
                      decoration: InputDecoration(
                        hintText: l.text('提问或讨论这段内容', 'Ask about this content'),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    icon: Icon(_request == null ? Icons.send : Icons.stop),
                    tooltip: l.text(
                      _request == null ? '发送' : '停止',
                      _request == null ? 'Send' : 'Stop',
                    ),
                    onPressed: _loading
                        ? null
                        : _request == null
                        ? _send
                        : _cancel,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AssistantText extends StatelessWidget {
  final String text;
  final ValueChanged<Uri>? onBookReference;
  const AssistantText(this.text, {super.key, this.onBookReference});
  @override
  Widget build(BuildContext context) =>
      AssistantRichText(text, onBookReference: onBookReference);
}
