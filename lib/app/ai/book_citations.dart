import 'dart:convert';
import '../../core/ir/ir.dart';

String sourceCitation(SourceRange range) =>
    '[原文](torto://source?range=${base64Url.encode(utf8.encode(jsonEncode(range.toJson()))).replaceAll('=', '')})';
String pageCitation(int unit) => '[第 ${unit + 1} 页](torto://page?unit=$unit)';
