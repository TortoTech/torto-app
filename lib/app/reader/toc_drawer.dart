import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'toc_items.dart';

/// Table-of-contents drawer for the reader, modeled on torto's desktop
/// sidebar (egui_view.rs): flattened rows, indent by depth, expand/collapse
/// toggles, active-row highlight, and auto-scroll to the active row when
/// opened. Long lists are virtualized by [ListView.builder].
class TocDrawer extends StatefulWidget {
  /// Pre-flattened rows (document order).
  final List<TocViewItem> items;

  /// Currently active row id, or null when unknown.
  final String? activeId;

  /// Called with rows that have a jump target when tapped.
  final void Function(TocViewItem item) onNavigate;

  const TocDrawer({
    super.key,
    required this.items,
    required this.activeId,
    required this.onNavigate,
  });

  @override
  State<TocDrawer> createState() => _TocDrawerState();
}

class _TocDrawerState extends State<TocDrawer> {
  /// Row height: 44dp minimum touch target (desktop uses 36px).
  static const double _rowHeight = 44;
  static const double _indentPerDepth = 16;

  final ScrollController _scroll = ScrollController();

  /// Ids of expanded rows; roots are always visible.
  final Set<String> _expandedIds = {};

  List<TocViewItem> get _visible => visibleTocItems(widget.items, _expandedIds);

  @override
  void initState() {
    super.initState();
    _revealActive();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  @override
  void didUpdateWidget(TocDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeId == widget.activeId &&
        identical(oldWidget.items, widget.items)) {
      return;
    }
    _revealActive();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  /// Reveal the active row: expand its ancestors (torto does the same when
  /// the active path changes), then let [_scrollToActive] center it.
  void _revealActive() {
    final active = widget.activeId;
    if (active == null) return;
    for (final item in widget.items) {
      if (item.id == active) {
        _expandedIds.addAll(item.ancestors);
        return;
      }
    }
  }

  void _scrollToActive() {
    if (!mounted || !_scroll.hasClients) return;
    final active = widget.activeId;
    if (active == null) return;
    final visible = _visible;
    final index = visible.indexWhere((item) => item.id == active);
    if (index < 0) return;
    final viewport = _scroll.position.viewportDimension;
    final offset = (index * _rowHeight - (viewport - _rowHeight) / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.jumpTo(offset);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Drawer(
      child: SafeArea(
        child: visible.isEmpty
            ? Center(
                child: Text(context.l10n.text('没有目录', 'No table of contents')),
              )
            : ListView.builder(
                controller: _scroll,
                itemCount: visible.length,
                itemExtent: _rowHeight,
                itemBuilder: (context, index) =>
                    _buildRow(context, visible[index]),
              ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, TocViewItem item) {
    final theme = Theme.of(context);
    final selected = item.id == widget.activeId;
    final expanded = _expandedIds.contains(item.id);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      child: InkWell(
        onTap: item.spineIndex == null ? null : () => widget.onNavigate(item),
        child: Padding(
          padding: EdgeInsets.only(left: 8 + item.depth * _indentPerDepth),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                height: _rowHeight,
                child: item.hasChildren
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        tooltip: expanded
                            ? context.l10n.text('收起', 'Collapse')
                            : context.l10n.text('展开', 'Expand'),
                        icon: Icon(
                          expanded ? Icons.expand_more : Icons.chevron_right,
                        ),
                        onPressed: () => setState(() {
                          expanded
                              ? _expandedIds.remove(item.id)
                              : _expandedIds.add(item.id);
                        }),
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: item.spineIndex == null ? theme.disabledColor : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
