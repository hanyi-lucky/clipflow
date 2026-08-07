import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/app_info.dart';

void main() {
  group('AppInfo.fullVersion', () {
    test('组合 version + buildNumber', () {
      const info = AppInfo(version: '1.5.0', buildNumber: '1');
      expect(info.fullVersion, '1.5.0+1');
    });

    test('buildNumber 为空时回退到 version', () {
      const info = AppInfo(version: '1.5.0', buildNumber: '');
      expect(info.fullVersion, '1.5.0');
    });

    test('buildNumber 为 unknown 时回退到 version', () {
      const info = AppInfo(version: '1.5.0', buildNumber: 'unknown');
      expect(info.fullVersion, '1.5.0');
    });
  });

  group('AppInfo.load', () {
    test('loader 返回信息则原样返回', () async {
      final info = await AppInfo.load(
        loader: () async =>
            const AppInfo(version: '2.0.0', buildNumber: '7'),
      );
      expect(info.version, '2.0.0');
      expect(info.buildNumber, '7');
      expect(info.fullVersion, '2.0.0+7');
    });

    test('loader 抛出异常时兜底 unknown，不抛错', () async {
      final info = await AppInfo.load(
        loader: () async => throw Exception('platform unavailable'),
      );
      expect(info.version, 'unknown');
      expect(info.fullVersion, 'unknown');
    });
  });
}
