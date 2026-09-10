import 'package:flutter/material.dart';
import '../../core/layout/layout_types.dart';
import '../../l10n/app_localizations.dart';
import '../reader/reader_preferences_store.dart';
import '../reader/system_reader_fonts.dart';

/// Shared by Settings and the in-reader typesetting panel.
class ReadingSettingsPage extends StatefulWidget {
  final ReaderPreferencesStore? store;
  const ReadingSettingsPage({super.key, this.store});
  @override
  State<ReadingSettingsPage> createState() => _ReadingSettingsPageState();
}

class _ReadingSettingsPageState extends State<ReadingSettingsPage> {
  late final _store = widget.store ?? ReaderPreferencesStore();
  ReaderTypography? _value;
  TypesettingMode _mode = TypesettingMode.unified;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = await _store.loadTypography();
    final mode = await _store.loadTypesettingMode();
    await SystemReaderFonts.instance.scan();
    if (mounted) {
      setState(() {
        _value = value;
        _mode = mode;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final value = _value!;
      await SystemReaderFonts.instance.load([
        value.cjkPrimaryFont.family,
        value.otherPrimaryFont.family,
        if (value.cjkLatinFont != null) value.cjkLatinFont!.family,
        if (value.otherCjkFont != null) value.otherCjkFont!.family,
      ]);
      await _store.saveTypography(value);
      await _store.saveTypesettingMode(_mode);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('保存失败，请重试', 'Could not save. Try again.'),
            ),
          ),
        );
      }
    }
  }

  Widget _heading(String zh, String en) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      context.l10n.text(zh, en),
      style: Theme.of(context).textTheme.titleSmall,
    ),
  );
  Widget _font(
    String label,
    String? selected,
    bool cjk,
    bool follow,
    void Function(String?) changed,
  ) {
    final options = <String, String>{
      if (follow)
        'follow': context.l10n.text(
          '跟随另一组主要字体',
          'Follow the other primary font',
        ),
      if (cjk) 'lxgwWenKai': '霞鹜文楷' else 'literata': 'Literata',
      'systemSerif': context.l10n.text('系统衬线', 'System serif'),
      'systemSansSerif': context.l10n.text('系统无衬线', 'System sans serif'),
      for (final name in SystemReaderFonts.instance.families)
        if (!cjk || SystemReaderFonts.instance.cjk.contains(name)) name: name,
    };
    if (selected != null) options.putIfAbsent(selected, () => selected);
    return ListTile(
      title: Text(label),
      subtitle: DropdownButton<String>(
        isExpanded: true,
        value: selected ?? 'follow',
        items: options.entries
            .map(
              (entry) => DropdownMenuItem(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: _saving
            ? null
            : (name) => setState(() => changed(name == 'follow' ? null : name)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.text('排版', 'Typesetting')),
        actions: [
          TextButton(
            onPressed: v == null || _saving ? null : _save,
            child: Text(l.text('保存', 'Save')),
          ),
        ],
      ),
      body: v == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _heading('正文样式', 'Content style'),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SegmentedButton<TypesettingMode>(
                    segments: [
                      ButtonSegment(
                        value: TypesettingMode.unified,
                        label: Text(l.text('统一版式', 'Unified')),
                      ),
                      ButtonSegment(
                        value: TypesettingMode.book,
                        label: Text(l.text('跟随书籍', 'Follow book')),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (m) => setState(() => _mode = m.single),
                  ),
                ),
                _heading('中日韩书籍', 'CJK books'),
                _font(
                  l.text('主要字体', 'Primary font'),
                  v.cjkPrimaryFont.name,
                  true,
                  false,
                  (s) => _value = v.copyWith(
                    cjkPrimaryFont: ReaderCjkFont.parse(s!),
                  ),
                ),
                _font(
                  l.text('拉丁字体', 'Latin font'),
                  v.cjkLatinFont?.name,
                  false,
                  true,
                  (s) => _value = v.copyWith(
                    cjkLatinFont: s == null ? null : ReaderLatinFont.parse(s),
                    clearCjkLatinFont: s == null,
                  ),
                ),
                _heading('其他语言书籍', 'Other-language books'),
                _font(
                  l.text('主要字体', 'Primary font'),
                  v.otherPrimaryFont.name,
                  false,
                  false,
                  (s) => _value = v.copyWith(
                    otherPrimaryFont: ReaderLatinFont.parse(s!),
                  ),
                ),
                _font(
                  l.text('中日韩字体', 'CJK font'),
                  v.otherCjkFont?.name,
                  true,
                  true,
                  (s) => _value = v.copyWith(
                    otherCjkFont: s == null ? null : ReaderCjkFont.parse(s),
                    clearOtherCjkFont: s == null,
                  ),
                ),
                _heading('通用', 'General'),
                ListTile(
                  title: Text(l.text('字号', 'Font size')),
                  trailing: Text('${v.fontSize.round()}'),
                  subtitle: Slider(
                    min: 12,
                    max: 28,
                    divisions: 16,
                    value: v.fontSize,
                    onChanged: (size) =>
                        setState(() => _value = v.copyWith(fontSize: size)),
                  ),
                ),
                ListTile(
                  title: Text(l.text('字重', 'Font weight')),
                  trailing: Text('${v.fontWeight}'),
                  subtitle: Slider(
                    min: 200,
                    max: 900,
                    divisions: 28,
                    value: v.fontWeight.toDouble(),
                    onChanged: (weight) => setState(
                      () => _value = v.copyWith(fontWeight: weight.round()),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
