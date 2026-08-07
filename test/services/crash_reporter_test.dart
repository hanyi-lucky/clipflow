import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:clipflow/services/app_info.dart';
import 'package:clipflow/services/crash_reporter.dart';

void main() {
  group('CrashReporter 去重', () {
    test('同一指纹 60s 内只上报一次', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final policy = CrashReportPolicy(
        now: () => DateTime(2026, 1, 1, 12, 0, 0),
      );
      final reporter = CrashReporter.forTest(client: client, policy: policy)
        ..init(appInfo: const AppInfo(version: '1.5.0', buildNumber: '1'));

      final stack = StackTrace.fromString('test stack line');
      final first = await reporter.report(StateError('boom'), stack);
      final second = await reporter.report(StateError('boom'), stack);

      expect(first, isTrue);
      expect(second, isFalse);
      expect(requests.length, 1);
    });

    test('不同指纹不误伤', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final policy = CrashReportPolicy(
        now: () => DateTime(2026, 1, 1, 12, 0, 0),
      );
      final reporter = CrashReporter.forTest(client: client, policy: policy);

      await reporter.report(StateError('a'), StackTrace.current);
      await reporter.report(StateError('b'), StackTrace.current);

      expect(requests.length, 2);
    });

    test('窗口过后同指纹可再次上报', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final policy = CrashReportPolicy(
        dedupWindow: const Duration(seconds: 60),
        now: () => now,
      );
      final reporter = CrashReporter.forTest(client: client, policy: policy);
      final stack = StackTrace.fromString('test stack line');

      await reporter.report(StateError('boom'), stack);
      now = now.add(const Duration(seconds: 61));
      final again = await reporter.report(StateError('boom'), stack);

      expect(again, isTrue);
      expect(requests.length, 2);
    });
  });

  group('CrashReporter 限频', () {
    test('超过 5 次/分钟则丢弃', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final policy = CrashReportPolicy(
        maxPerMinute: 5,
        maxPerSession: 100,
        now: () => DateTime(2026, 1, 1, 12, 0, 0),
      );
      final reporter = CrashReporter.forTest(client: client, policy: policy);

      for (var i = 0; i < 6; i++) {
        await reporter.report(StateError('err$i'), StackTrace.current);
      }

      expect(requests.length, 5);
    });

    test('超过 20 次/会话则丢弃', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final policy = CrashReportPolicy(
        maxPerMinute: 1000,
        maxPerSession: 20,
        now: () => now,
      );
      final reporter = CrashReporter.forTest(client: client, policy: policy);

      for (var i = 0; i < 25; i++) {
        // 每次推进 1 秒，绕开分钟窗口但累计会话计数
        now = now.add(const Duration(seconds: 1));
        await reporter.report(StateError('err$i'), StackTrace.current);
      }

      expect(requests.length, 20);
    });

    test('分钟窗口滑动后恢复上报', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final policy = CrashReportPolicy(
        maxPerMinute: 5,
        maxPerSession: 100,
        now: () => now,
      );
      final reporter = CrashReporter.forTest(client: client, policy: policy);

      for (var i = 0; i < 5; i++) {
        await reporter.report(StateError('err$i'), StackTrace.current);
      }
      now = now.add(const Duration(minutes: 2));
      final again = await reporter.report(
        StateError('fresh'),
        StackTrace.current,
      );

      expect(again, isTrue);
      expect(requests.length, 6);
    });
  });

  group('CrashReporter 上报内容与静默', () {
    test('上报体包含白名单字段（栈/版本/类型/平台），不含剪贴板内容', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final reporter = CrashReporter.forTest(client: client)
        ..init(
          appInfo: const AppInfo(version: '1.5.0', buildNumber: '1'),
        )
        ..setDeviceId('dev-123');

      await reporter.report(StateError('boom'), StackTrace.current);

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(captured!.url.path, '/api/crash');
      expect(body['exceptionType'], 'StateError');
      expect(body['message'], 'Bad state: boom');
      expect(body['stack'], isA<String>());
      expect(body['appVersion'], '1.5.0+1');
      expect(body['platform'], isA<String>());
      expect(body['deviceId'], 'dev-123');
      expect(body['reportedAt'], isA<int>());
    });

    test('带 token 时附带 Authorization 头', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"code":"SUCCESS"}', 200);
      });
      final reporter = CrashReporter.forTest(client: client)
        ..setAuthTokenProvider(() => 'tok-123');

      await reporter.report(StateError('boom'), StackTrace.current);

      expect(captured!.headers['Authorization'], 'Bearer tok-123');
    });

    test('上报失败静默，不抛出、不影响主流程', () async {
      final client = MockClient((request) async {
        throw http.ClientException('network down');
      });
      final reporter = CrashReporter.forTest(client: client);

      final result = await reporter.report(
        StateError('boom'),
        StackTrace.current,
      );

      expect(result, isFalse);
    });
  });
}
