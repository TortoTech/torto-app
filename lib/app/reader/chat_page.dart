import 'package:file_picker/file_picker.dart';
import '../ai/chat_attachments.dart';
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
  final VoidCallback? onClose;
  final ValueChanged<Uri>? onBookReference;
  const ChatPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.excerpt,
    required this.blockId,
    required this.file,
    this.tools,
    this.onClose,
    this.onBookReference,
  });
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _replyPending = false;
  bool _streaming = false;
  List<Map<String, String>> _messages = [];
  ChatAssistant? _request;
  bool _bookScope = false, _loading = true;
  int _epoch = 0;
  String? _error;
  final List<Map<String, String>> _attachments = [];
  final List<String> _steps = [];
  bool _picking = false;
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
              if (m['attachments'] is String)
                'attachments': m['attachments'] as String,
              if (m['steps'] is String) 'steps': m['steps'] as String,
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
        final previous = _messages.removeLast();
        _input.text = previous['content']!;
        _attachments.addAll(ChatAttachments.decode(previous['attachments']));
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
    if (text.isEmpty && _attachments.isEmpty ||
        text.length > 10000 ||
        _request != null ||
        _picking) {
      return;
    }
    final epoch = ++_epoch, key = _key;
    final request = ChatAssistant();
    setState(() {
      _request = request;
      _error = null;
      _steps.clear();
      _streaming = false;
      _messages.add({
        'role': 'user',
        'content': text,
        if (_attachments.isNotEmpty) 'attachments': jsonEncode(_attachments),
      });
      _attachments.clear();
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
      final history = <Map<String, String>>[];
      var contextBudget = 20000;
      for (final message in _messages.reversed.take(
        settings.historyTurns.clamp(1, 50) * 2,
      )) {
        if ((message['content'] ?? '').length > contextBudget) break;
        history.insert(0, Map<String, String>.of(message));
        contextBudget -= (message['content'] ?? '').length;
      }
      final attachmentStore = await ChatAttachments.open();
      final images = await attachmentStore.evidence(history);
      if (!mounted || epoch != _epoch) return;
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
        images: images,
        onToolProgress: (step) {
          if (mounted && epoch == _epoch) {
            setState(() {
              _steps.add(step);
              if (_steps.length > 24) _steps.removeAt(0);
            });
          }
        },
        title: widget.title,
        context: widget.excerpt,
        bookFile: _bookScope ? widget.file : null,
        bookTool: widget.tools == null ? null : _bookTool,
        bookInfo: widget.tools == null
            ? const {}
            : await _bookTool('getBookMetadata', {}),
        onPartial: (partial) {
          if (mounted && epoch == _epoch && replyIndex < _messages.length) {
            setState(() {
              _messages[replyIndex]['content'] = partial;
              _streaming = partial.isNotEmpty;
            });
            _scrollToEnd();
          }
        },
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _replyPending = false;
        _messages[replyIndex]['content'] = answer;
        if (_steps.isNotEmpty) {
          _messages[replyIndex]['steps'] = jsonEncode(_steps);
        }
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
          if (_messages.lastOrNull?['role'] == 'user') {
            _attachments.addAll(
              ChatAttachments.decode(_messages.removeLast()['attachments']),
            );
          }
        });
      }
    } finally {
      request.cancel();
      if (mounted && epoch == _epoch) setState(() => _request = null);
    }
  }

  Future<void> _pickImages() async {
    if (_picking || _request != null) return;
    setState(() => _picking = true);
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (!mounted) return;
      final store = await ChatAttachments.open();
      for (final file in files) {
        if (_attachments.length >= 8) {
          throw StateError('At most eight images per message');
        }
        if (await file.length() > 20 * 1024 * 1024) {
          throw StateError('Image exceeds 20 MB');
        }
        final data = await file.readAsBytes();
        final attachment = await store.save(data, file.name);
        if (!mounted) return;
        setState(() => _attachments.add(attachment));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      primary: widget.onClose == null,
      resizeToAvoidBottomInset: widget.onClose == null,
      appBar: AppBar(
        toolbarHeight: widget.onClose == null ? kToolbarHeight : 48,
        leading: widget.onClose == null
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
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
            dense: widget.onClose != null,
            visualDensity: widget.onClose == null
                ? null
                : VisualDensity.compact,
            title: Text(l.text('结合全书查找', 'Search within the book')),
            subtitle: widget.onClose != null
                ? null
                : Text(
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
                    itemCount:
                        _messages.length +
                        (_steps.isNotEmpty && _request != null ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == _messages.length) {
                        return ExpansionTile(
                          key: ValueKey(_replyPending && !_streaming),
                          initiallyExpanded: _replyPending && !_streaming,
                          title: Text(_steps.last),
                          dense: true,
                          children: [
                            for (final step in _steps)
                              ListTile(dense: true, title: Text(step)),
                          ],
                        );
                      }
                      return Padding(
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
                            if (_messages[i]['steps'] != null)
                              ExpansionTile(
                                dense: true,
                                title: Text(l.text('处理过程', 'Steps')),
                                children: [
                                  for (final step
                                      in jsonDecode(_messages[i]['steps']!)
                                          as List)
                                    ListTile(dense: true, title: Text('$step')),
                                ],
                              ),
                            if (_messages[i]['attachments'] != null)
                              Wrap(
                                children: [
                                  for (final image in ChatAttachments.decode(
                                    _messages[i]['attachments'],
                                  ))
                                    ChatAttachmentThumbnail(image),
                                ],
                              ),
                            AssistantText(
                              _messages[i]['content']!,
                              onBookReference: widget.onBookReference,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_attachments.isNotEmpty)
            SizedBox(
              height: 40,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final image in _attachments)
                      InputChip(
                        label: SizedBox(
                          width: 90,
                          child: Text(
                            image['name'] ?? 'Image',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        onDeleted: () =>
                            setState(() => _attachments.remove(image)),
                      ),
                  ],
                ),
              ),
            ),
          if (_request != null || _picking) const LinearProgressIndicator(),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(widget.onClose == null ? 12 : 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    tooltip: l.text('添加图片', 'Attach images'),
                    onPressed: _request != null || _picking
                        ? null
                        : _pickImages,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: widget.onClose == null ? 5 : 2,
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

class ChatAttachmentThumbnail extends StatefulWidget {
  final Map<String, String> attachment;
  const ChatAttachmentThumbnail(this.attachment, {super.key});
  @override
  State<ChatAttachmentThumbnail> createState() =>
      _ChatAttachmentThumbnailState();
}

class _ChatAttachmentThumbnailState extends State<ChatAttachmentThumbnail> {
  late final _bytes = ChatAttachments.open().then(
    (store) => store.read(widget.attachment),
  );
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return Chip(
          avatar: const Icon(Icons.image_outlined),
          label: Text(
            snapshot.hasError
                ? context.l10n.text('图片不可用', 'Image unavailable')
                : widget.attachment['name'] ?? 'Image',
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(4),
        child: InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              child: Stack(
                children: [
                  InteractiveViewer(
                    child: Image.memory(
                      bytes,
                      cacheWidth: 2048,
                      fit: BoxFit.contain,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: Semantics(
            label: widget.attachment['name'],
            image: true,
            child: Image.memory(
              bytes,
              width: 96,
              height: 80,
              cacheWidth: 240,
              fit: BoxFit.cover,
            ),
          ),
        ),
      );
    },
  );
}
