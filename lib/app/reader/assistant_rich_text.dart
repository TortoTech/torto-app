import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:xml/xml.dart';
import '../ai/llm_transport.dart';

class AssistantRichText extends StatelessWidget {
  final String text;
  final ValueChanged<Uri>? onBookReference;
  const AssistantRichText(this.text, {super.key, this.onBookReference});
  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    var at = 0;
    void prose(String value) {
      if (value.trim().isEmpty) return;
      children.add(
        MarkdownBody(
          data: value,
          selectable: true,
          extensionSet: md.ExtensionSet.gitHubFlavored,
          inlineSyntaxes: [_MathSyntax()],
          builders: {'torto-math': _MathBuilder()},
          imageBuilder: (_, _, alt) => Text(alt ?? ''),
          onTapLink: (_, href, _) {
            final uri = Uri.tryParse(href ?? '');
            if (uri?.scheme == 'torto' &&
                const {'source', 'page', 'toc'}.contains(uri?.host)) {
              onBookReference?.call(uri!);
            } else if (uri != null &&
                LlmTransport.safeSourceUrl(uri.toString())) {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
      );
    }

    for (final match in RegExp(
      r'^```(mermaid|svg)\s*\n([\s\S]*?)^```\s*$',
      multiLine: true,
    ).allMatches(text)) {
      prose(text.substring(at, match.start));
      final code = match[2]!;
      children.add(
        match[1] == 'svg' && safeAssistantSvg(code)
            ? SvgPicture.string(code, width: double.infinity, height: 300)
            : match[1] == 'mermaid' && code.length <= 20000
            ? _Mermaid(code, key: ValueKey(code))
            : SelectableText(code),
      );
      at = match.end;
    }
    prose(text.substring(at));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// Generated SVG is geometry only; no external resources or executable nodes.
bool safeAssistantSvg(String source) {
  if (source.length > 200000 ||
      source.contains(RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false))) {
    return false;
  }
  try {
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local != 'svg') return false;
    const tags = {
      'svg',
      'g',
      'path',
      'rect',
      'circle',
      'ellipse',
      'line',
      'polyline',
      'polygon',
      'text',
      'tspan',
      'defs',
      'clipPath',
      'linearGradient',
      'radialGradient',
      'stop',
      'title',
      'desc',
      'use',
      'symbol',
      'marker',
    };
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (!tags.contains(element.name.local)) return false;
      for (final attribute in element.attributes) {
        final name = attribute.name.local.toLowerCase(),
            value = attribute.value;
        if (name.startsWith('on') ||
            name == 'style' ||
            (name == 'href' && !value.startsWith('#')) ||
            value.contains(
              RegExp(
                r'javascript:|data:|https?:|url\(\s*["\x27]?(?!#)',
                caseSensitive: false,
              ),
            )) {
          return false;
        }
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

class _MathSyntax extends md.InlineSyntax {
  _MathSyntax()
    : super(
        r'\\\((.+?)\\\)|\\\[([\s\S]+?)\\\]|\$\$([\s\S]+?)\$\$|\$([^\$\n]+)\$',
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text(
        'torto-math',
        match[1] ?? match[2] ?? match[3] ?? match[4]!,
      ),
    );
    return true;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => fm.Math.tex(
    element.textContent,
    textStyle: parentStyle ?? Theme.of(context).textTheme.bodyMedium,
    onErrorFallback: (_) => Text(element.textContent),
  );
}

class _Mermaid extends StatefulWidget {
  final String code;
  const _Mermaid(this.code, {super.key});
  @override
  State<_Mermaid> createState() => _MermaidState();
}

class _MermaidState extends State<_Mermaid> {
  WebViewController? _controller;
  bool _failed = false;
  double _height = 300;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (kIsWeb ||
        !const {
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform)) {
      setState(() => _failed = true);
      return;
    }
    try {
      final script = await rootBundle.loadString(
        'assets/assistant/mermaid.min.js',
      );
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (_) => NavigationDecision.prevent,
          ),
        )
        ..addJavaScriptChannel(
          'Diagram',
          onMessageReceived: (message) {
            if (!mounted) return;
            final height = double.tryParse(message.message);
            setState(() {
              if (height == null) {
                _failed = true;
              } else {
                _height = height.clamp(120, 1200);
              }
            });
          },
        );
      final code = jsonEncode(widget.code).replaceAll('<', r'\u003c');
      final theme = Theme.of(context).brightness == Brightness.dark
          ? 'dark'
          : 'default';
      await controller.loadHtmlString(
        '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'">
<style>body{margin:0;padding:8px;overflow:auto}svg{max-width:100%;height:auto}</style>
</head><body><div id="diagram"></div><script>${script.replaceAll('</script', r'<\/script')}</script>
<script>mermaid.initialize({startOnLoad:false,theme:'$theme',securityLevel:'strict',maxTextSize:20000,maxEdges:300,flowchart:{htmlLabels:false}});
mermaid.render('tortoDiagram',$code).then(function(r){document.getElementById('diagram').innerHTML=r.svg;Diagram.postMessage(String(document.body.scrollHeight));}).catch(function(){Diagram.postMessage('error');});</script></body></html>''',
      );
      if (mounted) setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => _failed
      ? SelectableText(widget.code)
      : SizedBox(
          height: _height,
          child: _controller == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: _controller!),
        );
}
