import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../core/ir/ir.dart' as ir;
import '../../core/semantic_layout/web_links.dart';
import '../../core/semantic_layout/media_references.dart';
import 'media_reference_scope.dart';
import 'reader_controller.dart' show ReaderFootnote;

import '../../core/ir/book.dart';
import '../../core/layout/layout_types.dart';
import '../../core/render/page_painter.dart' show footnoteIconColor;
import '../../core/linebreak/english_hyphenator.dart';
import '../../core/linebreak/paragraph_optimizer.dart';
import '../../core/linebreak/measurement.dart';
import '../../core/linebreak/unicode_line_breaker.dart';

/// Shows one reader footnote as a full-window-width bottom sheet.
Future<void> showReaderFootnoteSheet(
  BuildContext context, {
  required String text,
  required Color background,
  required Color foreground,
  String publicationLanguage = '',
  WritingSystem writingSystem = WritingSystem.unknown,
  ReaderTypography typography = const ReaderTypography(),
  TypesettingMode typesettingMode = TypesettingMode.unified,
  List<ReaderFootnote> entries = const [],
  int initialCitation = 0,
  int initialFootnoteNumber = 0,
  Color? markerColor,
  bool blockNavigation = false,
  Future<void> Function(String)? onMediaReference,
}) async {
  await EnglishHyphenator.instance.ensureLoadedForLanguage(publicationLanguage);
  if (!context.mounted) return;
  final viewport = MediaQuery.sizeOf(context);
  final baseTheme = Theme.of(context);
  final brightness = background.computeLuminance() < 0.5
      ? Brightness.dark
      : Brightness.light;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: baseTheme.colorScheme.primary,
    brightness: brightness,
  ).copyWith(surface: background, onSurface: foreground);
  final sheetTheme = baseTheme.copyWith(
    brightness: brightness,
    colorScheme: colorScheme,
    bottomSheetTheme: baseTheme.bottomSheetTheme.copyWith(
      backgroundColor: background,
    ),
    iconTheme: baseTheme.iconTheme.copyWith(color: foreground),
    textTheme: baseTheme.textTheme.apply(
      bodyColor: foreground,
      displayColor: foreground,
    ),
  );
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: background,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      minWidth: viewport.width,
      maxWidth: viewport.width,
      maxHeight: viewport.height * 0.75,
    ),
    builder: (context) => MediaReferenceScope(
      open: onMediaReference,
      child: Theme(
        data: sheetTheme,
        child: _FootnoteNavigator(
          blockNavigation: blockNavigation,
          sheet: ReaderFootnoteSheet(
            text: text,
            foreground: foreground,
            publicationLanguage: publicationLanguage,
            writingSystem: writingSystem,
            typography: typography,
            typesettingMode: typesettingMode,
            entries: entries,
            initialCitation: initialCitation,
            initialFootnoteNumber: initialFootnoteNumber,
            markerColor: markerColor ?? footnoteIconColor(background),
          ),
        ),
      ),
    ),
  );
}

class _FootnoteNavigator extends StatefulWidget {
  final ReaderFootnoteSheet sheet;
  final bool blockNavigation;
  const _FootnoteNavigator({
    required this.sheet,
    required this.blockNavigation,
  });
  @override
  State<_FootnoteNavigator> createState() => _FootnoteNavigatorState();
}

class _FootnoteNavigatorState extends State<_FootnoteNavigator> {
  late int index;
  @override
  void initState() {
    super.initState();
    final sheet = widget.sheet;
    final initial = sheet.entries.indexWhere(
      (e) => sheet.initialCitation > 0
          ? e.citationOrdinal == sheet.initialCitation
          : sheet.initialFootnoteNumber > 0
          ? e.footnoteNumber == sheet.initialFootnoteNumber
          : false,
    );
    index = initial < 0 ? 0 : initial;
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet, entries = sheet.entries;
    final active = entries.isEmpty ? null : entries[index];
    final navigation = widget.blockNavigation && entries.length > 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (navigation)
              IconButton(
                key: const Key('footnote-previous'),
                tooltip: context.l10n.text('上一条', 'Previous note'),
                onPressed: () =>
                    setState(() => index = (index - 1) % entries.length),
                icon: const Icon(Icons.chevron_left),
              ),
            Expanded(
              child: Text(
                navigation ? '${index + 1} / ${entries.length}' : '',
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              key: const Key('footnote-copy'),
              tooltip: context.l10n.text('复制脚注', 'Copy footnote'),
              onPressed: () => Clipboard.setData(
                ClipboardData(text: active?.text ?? sheet.text),
              ),
              icon: const Icon(Icons.copy_outlined),
            ),
            if (navigation)
              IconButton(
                key: const Key('footnote-next'),
                tooltip: context.l10n.text('下一条', 'Next note'),
                onPressed: () =>
                    setState(() => index = (index + 1) % entries.length),
                icon: const Icon(Icons.chevron_right),
              ),
          ],
        ),
        Flexible(
          child: navigation
              ? ReaderFootnoteSheet(
                  key: ValueKey(index),
                  text: active!.text,
                  foreground: sheet.foreground,
                  publicationLanguage: sheet.publicationLanguage,
                  writingSystem: sheet.writingSystem,
                  typography: sheet.typography,
                  typesettingMode: sheet.typesettingMode,
                  entries: [active],
                  initialCitation: active.citationOrdinal,
                  initialFootnoteNumber: active.footnoteNumber,
                  markerColor: sheet.markerColor,
                )
              : sheet,
        ),
      ],
    );
  }
}

class ReaderFootnoteSheet extends StatelessWidget {
  final String text;
  final Color foreground;
  final String publicationLanguage;
  final WritingSystem writingSystem;
  final ReaderTypography typography;
  final TypesettingMode typesettingMode;
  final List<ReaderFootnote> entries;
  final int initialCitation;
  final int initialFootnoteNumber;
  final Color? markerColor;

  const ReaderFootnoteSheet({
    super.key,
    required this.text,
    required this.foreground,
    this.publicationLanguage = '',
    this.writingSystem = WritingSystem.unknown,
    this.typography = const ReaderTypography(),
    this.typesettingMode = TypesettingMode.unified,
    this.entries = const [],
    this.initialCitation = 0,
    this.initialFootnoteNumber = 0,
    this.markerColor,
  });

  @override
  Widget build(BuildContext context) {
    final latinFont = typography.latinFontFor(writingSystem);
    final cjkFont = typography.cjkFontFor(writingSystem);
    return SafeArea(
      top: false,
      child: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: entries.isNotEmpty
              ? _ReferenceRows(
                  entries,
                  initialCitation,
                  initialFootnoteNumber,
                  foreground,
                  markerColor ??
                      footnoteIconColor(Theme.of(context).colorScheme.surface),
                  publicationLanguage,
                  typesettingMode == TypesettingMode.unified,
                )
              : _PopupText(
                  inlines: [ir.TextRun(text)],
                  websiteIcons: typesettingMode == TypesettingMode.unified,
                  linkColor:
                      markerColor ??
                      footnoteIconColor(Theme.of(context).colorScheme.surface),
                  publicationLanguage: publicationLanguage,
                  style: TextStyle(
                    color: foreground,
                    fontFamily: latinFont.family,
                    fontFamilyFallback: [cjkFont.family],
                    fontWeight:
                        FontWeight.values[((typography.fontWeight / 100)
                                    .round() -
                                1)
                            .clamp(0, 8)],
                    fontVariations: latinFont == ReaderLatinFont.literata
                        ? [
                            ui.FontVariation(
                              'wght',
                              typography.fontWeight.toDouble(),
                            ),
                            const ui.FontVariation('opsz', 12.75),
                          ]
                        : null,
                    fontSize: 17,
                    height: 1.55,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ReferenceRows extends StatefulWidget {
  final List<ReaderFootnote> entries;
  final int selected;
  final int selectedFootnote;
  final Color color;
  final Color markerColor;
  final String publicationLanguage;
  final bool websiteIcons;
  const _ReferenceRows(
    this.entries,
    this.selected,
    this.selectedFootnote,
    this.color,
    this.markerColor,
    this.publicationLanguage,
    this.websiteIcons,
  );
  @override
  State<_ReferenceRows> createState() => _ReferenceRowsState();
}

class _ReferenceRowsState extends State<_ReferenceRows> {
  final selected = GlobalKey();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = selected.currentContext;
      if (context != null) Scrollable.ensureVisible(context, alignment: .15);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // Measure exactly the style that Text paints, including theme spacing and
    // weight. Otherwise a bracket can wrap out of the one-line marker slot.
    final markerStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: widget.markerColor,
        fontSize: 17,
        height: 1,
        fontFamily: 'Literata',
      ),
    );
    var slot = 0.0;
    for (final note in widget.entries) {
      final painter = TextPainter(
        text: TextSpan(text: note.displayMarker, style: markerStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      slot = math.max(slot, painter.width.ceilToDouble() + 2);
      painter.dispose();
    }
    final gap = scaler.scale(17) * 0.3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final note in widget.entries)
          Padding(
            key:
                (widget.selected > 0 &&
                        note.citationOrdinal == widget.selected) ||
                    (widget.selectedFootnote > 0 &&
                        note.footnoteNumber == widget.selectedFootnote)
                ? selected
                : null,
            padding: const EdgeInsets.only(bottom: 16),
            child: _NoteContent(
              note,
              widget.color,
              publicationLanguage: widget.publicationLanguage,
              websiteIcons: widget.websiteIcons,
              linkColor: widget.markerColor,
              leadingWidth: slot + gap,
              leading: WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox(
                  width: slot + gap,
                  height: MediaQuery.textScalerOf(context).scale(17),
                  child: Padding(
                    padding: EdgeInsets.only(right: gap),
                    child: Center(
                      child: Text(
                        note.displayMarker,
                        style: markerStyle,
                        textDirection: TextDirection.ltr,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _NoteContent extends StatelessWidget {
  final ReaderFootnote note;
  final Color color;
  final InlineSpan leading;
  final String publicationLanguage;
  final double leadingWidth;
  final bool websiteIcons;
  final Color linkColor;
  const _NoteContent(
    this.note,
    this.color, {
    required this.leading,
    required this.publicationLanguage,
    required this.leadingWidth,
    required this.websiteIcons,
    required this.linkColor,
  });
  @override
  Widget build(BuildContext context) {
    return _PopupText(
      inlines: _noteInlines(note),
      style: TextStyle(color: color, fontSize: 17, height: 1.55),
      leading: leading,
      leadingWidth: leadingWidth,
      publicationLanguage: publicationLanguage,
      websiteIcons: websiteIcons,
      linkColor: linkColor,
    );
  }
}

List<ir.Inline> _noteInlines(ReaderFootnote note) {
  final source = note.inlines;
  if (source == null || source.isEmpty) return [ir.TextRun(note.popupText)];
  // Linked definitions can retain their authored marker in the rich content.
  // Remove it without discarding links or formulas in the remaining runs.
  final prefix = source
      .takeWhile((i) => i is ir.TextRun)
      .cast<ir.TextRun>()
      .map((r) => r.text)
      .join();
  final marker = note.marker.trim();
  var skip = 0;
  final trimmed = prefix.trimLeft();
  if (marker.isNotEmpty && trimmed.startsWith(marker)) {
    skip = prefix.length - trimmed.length + marker.length;
    skip +=
        RegExp(
          r'^[\s.。．、,，:：;；)）\]】]+',
        ).firstMatch(prefix.substring(skip))?.end ??
        0;
  }
  final result = <ir.Inline>[];
  for (final inline in source) {
    if (inline is ir.TextRun && skip > 0) {
      if (skip < inline.text.length) {
        result.add(
          ir.TextRun(
            inline.text.substring(skip),
            style: inline.style,
            link: inline.link,
            language: inline.language,
            displayWritingSystem: inline.displayWritingSystem,
          ),
        );
      }
      skip = math.max(0, skip - inline.text.length);
    } else {
      result.add(inline);
    }
  }
  return result;
}

typedef PopupInlineWidget = ({WidgetSpan span, double width, double height});

class _PopupText extends StatelessWidget {
  final List<ir.Inline> inlines;
  final TextStyle style;
  final String publicationLanguage;
  final bool websiteIcons;
  final Color linkColor;
  final InlineSpan? leading;
  final double leadingWidth;
  const _PopupText({
    required this.inlines,
    required this.style,
    required this.publicationLanguage,
    required this.websiteIcons,
    required this.linkColor,
    this.leading,
    this.leadingWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Popup content is a new paragraph: a citation's outer semantic role must
    // not suppress detection of a URL inside its expanded text.
    final inlines = MediaReferences.link(
      translationInlines([
        for (final inline in this.inlines)
          if (inline is ir.TextRun)
            ir.TextRun(
              inline.text,
              style: inline.style.copyWith(
                inlineCitation: 0,
                inlineRole: ir.InlineRole.normal,
                linkRole: ir.LinkRole.normal,
              ),
              link: inline.style.linkRole == ir.LinkRole.footnoteBacklink
                  ? null
                  : inline.link,
            )
          else
            inline,
      ]),
    );
    if (!inlines.any((inline) => inline is ir.MathInline)) {
      final text = StringBuffer();
      final widgets = <int, PopupInlineWidget>{};
      final em = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 17);
      for (final inline in inlines) {
        if (inline is ir.TextRun) {
          if (inline.link?.startsWith('torto-media:') == true) {
            final painter = TextPainter(
              text: TextSpan(text: inline.text, style: style),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            widgets[text.length] = (
              span: _mediaSpan(context, inline, style),
              width: painter.width,
              height: painter.height,
            );
            painter.dispose();
            text.write('\ufffc');
          } else if (websiteIcons &&
              inline.style.website &&
              inline.link != null) {
            widgets[text.length] = (
              span: _websiteSpan(inline.link!, em, linkColor),
              width: em * 1.25,
              height: em,
            );
            text.write('\ufffc');
          } else {
            text.write(inline.text);
          }
        } else if (inline is ir.BreakInline) {
          text.write('\n');
        }
      }
      return OptimizedJustifiedText(
        text.toString(),
        style: style,
        leading: leading,
        leadingWidth: leadingWidth,
        publicationLanguage: publicationLanguage,
        inlineWidgets: widgets,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Text.rich(
        TextSpan(
          style: style,
          children: [
            ?leading,
            for (final inline in inlines)
              if (inline is ir.TextRun)
                if (inline.link?.startsWith('torto-media:') == true)
                  _mediaSpan(context, inline, style)
                else if (websiteIcons &&
                    inline.style.website &&
                    inline.link != null)
                  _websiteSpan(
                    inline.link!,
                    MediaQuery.textScalerOf(
                      context,
                    ).scale(style.fontSize ?? 17),
                    linkColor,
                  )
                else
                  TextSpan(text: inline.text)
              else if (inline is ir.BreakInline)
                const TextSpan(text: '\n')
              else if (inline is ir.MathInline)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: GestureDetector(
                    onLongPress: () =>
                        Clipboard.setData(ClipboardData(text: inline.latex)),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: fm.Math.tex(
                          inline.latex,
                          mathStyle: fm.MathStyle.text,
                          textStyle: style.copyWith(height: 1),
                          onErrorFallback: (_) => Text(
                            inline.sourceText.isEmpty
                                ? inline.latex
                                : inline.sourceText,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

WidgetSpan _mediaSpan(BuildContext context, ir.TextRun run, TextStyle style) =>
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        onTap: () => MediaReferenceScope.of(context)?.open?.call(run.link!),
        onLongPress: () => Clipboard.setData(ClipboardData(text: run.text)),
        child: Text(
          run.text,
          style: style.copyWith(
            color: Colors.blue,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );

WidgetSpan _websiteSpan(String url, double em, Color color) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Semantics(
    link: true,
    label: url,
    child: Tooltip(
      message: url,
      child: GestureDetector(
        onTap: () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        onLongPress: () => Clipboard.setData(ClipboardData(text: url)),
        child: SizedBox(
          width: em * 1.25,
          height: em,
          child: Center(
            child: Icon(Icons.language, size: em * .9, color: color),
          ),
        ),
      ),
    ),
  ),
);

/// Plain-text adapter for the same whole-paragraph optimizer used by the
/// reader layout engine. Explicit line breaks and per-cluster spacing keep
/// popup notes consistent with unified body text.
class OptimizedJustifiedText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final String publicationLanguage;
  final ParagraphHyphenator? hyphenator;
  final InlineSpan? leading;
  final double leadingWidth;
  final Map<int, PopupInlineWidget> inlineWidgets;

  const OptimizedJustifiedText(
    this.text, {
    super.key,
    required this.style,
    this.publicationLanguage = '',
    this.hyphenator,
    this.leading,
    this.leadingWidth = 0,
    this.inlineWidgets = const {},
  });

  @override
  Widget build(BuildContext context) {
    final paragraphs = text.split(RegExp(r'\r?\n'));
    final lineHeight = (style.fontSize ?? 17) * (style.height ?? 1.0);
    var offset = 0;
    final paragraphWidgets = <Map<int, PopupInlineWidget>>[];
    for (final paragraph in paragraphs) {
      paragraphWidgets.add({
        for (final entry in inlineWidgets.entries)
          if (entry.key >= offset && entry.key < offset + paragraph.length)
            entry.key - offset: entry.value,
      });
      offset += paragraph.length + 1;
      if (offset < text.length && text[offset - 1] == '\r') offset++;
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < paragraphs.length; index++) ...[
            if (paragraphs[index].isEmpty)
              SizedBox(height: lineHeight)
            else
              _OptimizedParagraphText(
                paragraphs[index],
                style: style,
                publicationLanguage: publicationLanguage,
                hyphenator: hyphenator ?? EnglishHyphenator.instance,
                leading: index == 0 ? leading : null,
                leadingWidth: index == 0 ? leadingWidth : 0,
                inlineWidgets: paragraphWidgets[index],
              ),
          ],
        ],
      ),
    );
  }
}

class _OptimizedParagraphText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final String publicationLanguage;
  final ParagraphHyphenator hyphenator;
  final InlineSpan? leading;
  final double leadingWidth;
  final Map<int, PopupInlineWidget> inlineWidgets;

  const _OptimizedParagraphText(
    this.text, {
    required this.style,
    required this.publicationLanguage,
    required this.hyphenator,
    this.leading,
    this.leadingWidth = 0,
    this.inlineWidgets = const {},
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (!width.isFinite || width <= 0) return const SizedBox.shrink();
      final span = _optimizedTextSpan(
        text,
        DefaultTextStyle.of(context).style.merge(style),
        width,
        MediaQuery.textScalerOf(context),
        publicationLanguage,
        hyphenator,
        leading: leading,
        leadingWidth: leadingWidth,
        inlineWidgets: inlineWidgets,
      );
      if (span == null) {
        if (inlineWidgets.isNotEmpty) {
          final children = <InlineSpan>[?leading];
          var start = 0;
          for (final entry in inlineWidgets.entries) {
            children.add(TextSpan(text: text.substring(start, entry.key)));
            children.add(entry.value.span);
            start = entry.key + 1;
          }
          children.add(TextSpan(text: text.substring(start)));
          return Text.rich(
            TextSpan(style: style, children: children),
            textAlign: TextAlign.justify,
          );
        }
        if (leading != null) {
          return Text.rich(
            TextSpan(
              style: style,
              children: [
                leading!,
                TextSpan(text: text),
              ],
            ),
            textAlign: TextAlign.justify,
          );
        }
        return Text(text, style: style, textAlign: TextAlign.justify);
      }
      return Text.rich(
        span,
        textAlign: TextAlign.left,
        softWrap: false,
        overflow: TextOverflow.visible,
      );
    },
  );
}

TextSpan? _optimizedTextSpan(
  String text,
  TextStyle style,
  double width,
  TextScaler textScaler,
  String publicationLanguage,
  ParagraphHyphenator hyphenator, {
  InlineSpan? leading,
  double leadingWidth = 0,
  Map<int, PopupInlineWidget> inlineWidgets = const {},
}) {
  final hyphenationBreaks = hyphenator.breakOpportunities(
    text: text,
    spans: [HyphenationSpan(start: 0, end: text.length)],
    publicationLanguage: publicationLanguage,
  );
  final legalBreaks = Icu4xLineBreaker.instance.breakOpportunities(text);
  final measurementBreaks = {...legalBreaks, ...hyphenationBreaks};
  final ranges = <({int start, int end})>[];
  var offset = 0;
  int? groupedStart;
  void flushGroup() {
    if (groupedStart != null && groupedStart! < offset) {
      ranges.add((start: groupedStart!, end: offset));
    }
    groupedStart = null;
  }

  for (final grapheme in text.characters) {
    final start = offset;
    if (inlineWidgets.containsKey(start) ||
        requiresStandaloneMeasurement(grapheme)) {
      flushGroup();
      ranges.add((start: start, end: start + grapheme.length));
    } else {
      groupedStart ??= start;
    }
    offset += grapheme.length;
    if (measurementBreaks.contains(offset)) flushGroup();
  }
  flushGroup();
  if (ranges.isEmpty) return null;

  final measurement = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout(maxWidth: 1000000);
  final clusters = <MeasuredCluster>[];
  for (final range in ranges) {
    final boxes = measurement.getBoxesForSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    var advance = boxes.fold<double>(
      0,
      (total, box) => total + box.right - box.left,
    );
    if (inlineWidgets.containsKey(range.start)) {
      advance = inlineWidgets[range.start]!.width;
    }
    if ((boxes.isEmpty && !inlineWidgets.containsKey(range.start)) ||
        !advance.isFinite ||
        advance < 0) {
      final fallback = TextPainter(
        text: TextSpan(
          text: text.substring(range.start, range.end),
          style: style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      advance = fallback.width;
      fallback.dispose();
    }
    clusters.add(
      MeasuredCluster(
        start: range.start,
        end: range.end,
        advance: advance,
        em: textScaler.scale(style.fontSize ?? 17),
      ),
    );
  }
  measurement.dispose();

  final hyphenPainter = TextPainter(
    text: TextSpan(text: '\u2010', style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final hyphenWidth = hyphenPainter.width;
  hyphenPainter.dispose();

  final plan = const ParagraphOptimizer().plan(
    text: text,
    clusters: clusters,
    legalBreaks: legalBreaks,
    hyphenBreaks: {
      for (final offset in hyphenationBreaks)
        if (hyphenWidth.isFinite && hyphenWidth > 0) offset: hyphenWidth,
    },
    lineWidth: math.max(
      1.0,
      width - math.min(1.0, textScaler.scale(style.fontSize ?? 17) * 0.05),
    ),
    firstLineIndent: leadingWidth,
    defaultEm: textScaler.scale(style.fontSize ?? 17),
  );
  if (plan == null) return null;

  final children = <InlineSpan>[?leading];
  for (var lineIndex = 0; lineIndex < plan.lines.length; lineIndex++) {
    final line = plan.lines[lineIndex];
    final plain = StringBuffer();

    void flushPlain() {
      if (plain.isEmpty) return;
      children.add(TextSpan(text: plain.toString()));
      plain.clear();
    }

    for (var index = line.startCluster; index < line.endCluster; index++) {
      final cluster = clusters[index];
      final value = text.substring(cluster.start, cluster.end);
      final adjustment = plan.adjustments[index];
      final inlineWidget = inlineWidgets[cluster.start];
      if (inlineWidget != null) {
        flushPlain();
        children.add(
          WidgetSpan(
            alignment: inlineWidget.span.alignment,
            baseline: inlineWidget.span.baseline,
            child: SizedBox(
              width: math.max(.1, inlineWidget.width + adjustment),
              height: inlineWidget.height,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: inlineWidget.width,
                maxWidth: inlineWidget.width,
                child: inlineWidget.span.child,
              ),
            ),
          ),
        );
        continue;
      }
      if (adjustment.abs() <= 0.0001) {
        plain.write(value);
      } else {
        flushPlain();
        // A measured Latin word is one shaping unit. Apply the trailing
        // adjustment once, rather than once per letter in that word.
        final last = value.characters.last;
        if (value.length > last.length) {
          children.add(
            TextSpan(text: value.substring(0, value.length - last.length)),
          );
        }
        children.add(
          TextSpan(
            text: last,
            style: TextStyle(
              letterSpacing: (style.letterSpacing ?? 0) + adjustment,
            ),
          ),
        );
      }
    }
    flushPlain();
    if (lineIndex + 1 < plan.lines.length) {
      if (line.hyphenated) children.add(const TextSpan(text: '\u2010'));
      children.add(const TextSpan(text: '\n'));
    }
  }
  return TextSpan(style: style, children: children);
}
