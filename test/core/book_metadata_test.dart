import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  test('metadata resolves the same writing-system hints as desktop', () {
    expect(
      const BookMetadata(languages: ['zh-CN']).writingSystem,
      WritingSystem.cjk,
    );
    expect(
      const BookMetadata(languages: ['en']).writingSystem,
      WritingSystem.latin,
    );
    expect(const BookMetadata(title: '系统之美').writingSystem, WritingSystem.cjk);
    expect(
      const BookMetadata(title: 'Thinking in Systems').writingSystem,
      WritingSystem.latin,
    );
  });
}
