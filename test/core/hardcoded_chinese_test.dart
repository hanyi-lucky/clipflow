import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 国际化护栏：lib/ 下除资源层 app_strings.dart 外，不允许单引号字符串字面量
/// 内出现硬编码中文（含 rg `\p{Han}` 会误报的中缀点「·」与 CJK 标点）。
/// 注释、test/ 断言不受此约束。
void main() {
  test('lib/ 下除资源层外无硬编码中文 UI 文案', () {
    // 匹配 rg -n "'[^']*[\p{Han}][^']*'" 的行为，并补齐其误报的 · 与 CJK 标点。
    // Dart RegExp 不支持字符类内 \p{Han}，改用显式 CJK 区间 + CJK 标点区。
    final pattern = RegExp(
      r"'[^']*[\u00b7\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff][^']*'",
    );
    final hits = <String>[];

    void scan(Directory dir) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is Directory) {
          scan(entity);
        } else if (entity is File && entity.path.endsWith('.dart')) {
          if (entity.path.endsWith('${Platform.pathSeparator}l10n'
              '${Platform.pathSeparator}app_strings.dart')) {
            continue;
          }
          final lines = entity.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (pattern.hasMatch(lines[i])) {
              hits.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
            }
          }
        }
      }
    }

    scan(Directory('lib'));
    expect(
      hits,
      isEmpty,
      reason: '发现硬编码中文文案，请迁移到 lib/l10n/app_strings.dart：\n'
          '${hits.take(20).join('\n')}',
    );
  });
}
