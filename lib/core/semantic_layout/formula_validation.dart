import 'package:flutter_math_fork/tex.dart';

const formulaParserSettings = TexParserSettings(
  maxExpand: 100,
  strict: Strict.error,
);

String? formulaError(String latex) {
  if (latex.trim().isEmpty || latex.length > 4096) {
    return 'Empty or oversized formula';
  }
  if (RegExp(
    r'\\(?:def|gdef|edef|newcommand|renewcommand|include|input|href|url|html|color|rule|kern|hspace|vspace)\b|\$',
  ).hasMatch(latex)) {
    return 'Unsupported command or formula delimiter';
  }
  var depth = 0;
  for (var i = 0; i < latex.length; i++) {
    if (latex[i] == '\\') {
      i++;
      continue;
    }
    if (latex[i] == '{' && ++depth > 32) return 'Formula nesting is too deep';
    if (latex[i] == '}' && --depth < 0) return 'Unbalanced braces';
  }
  if (depth != 0) return 'Unbalanced braces';
  try {
    TexParser(latex, formulaParserSettings).parse();
    return null;
  } on Object {
    return 'Unsupported or invalid LaTeX';
  }
}
