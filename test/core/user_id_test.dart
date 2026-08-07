import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/user_id.dart';

void main() {
  test('deriveUserId 与红线公式逐字节一致（防漂移）', () {
    for (final p in ['x', 'abc123', 'my password', '中文密码', '']) {
      final expected =
          'user_${sha256.convert(utf8.encode('clipflow:$p')).toString().substring(0, 16)}';
      expect(deriveUserId(p), expected);
    }
  });

  test('deriveUserId 输出 user_ 前缀 + 16 位哈希前缀', () {
    final id = deriveUserId('x');
    expect(id.startsWith('user_'), isTrue);
    expect(id.length, 'user_'.length + 16);
  });
}
