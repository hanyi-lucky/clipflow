import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/clipboard_channel_constants.dart';
import 'package:clipflow/models/clipboard_image.dart';
import 'package:clipflow/services/clipboard_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const imageChannel = MethodChannel(AppChannelNames.clipboard);

  void mockImageChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(imageChannel, handler);
  }

  void mockClipboardText(String? text) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': text};
      }
      return null;
    });
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(imageChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('ClipboardMonitor image echo suppression', () {
    test('syncClipboard skips preReadImage whose hash is in ignoreHashes', () async {
      final events = <ClipboardImage>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onImageChanged = events.add;

      final bytes = Uint8List.fromList([10, 20, 30, 40]);
      final hash = sha256.convert(bytes).toString();
      monitor.addIgnoreHash(hash);

      await monitor.syncClipboard(
        preReadImage: ClipboardImage(
          bytes: bytes,
          format: 'png',
          width: 2,
          height: 2,
        ),
      );

      expect(events, isEmpty);
      // 忽略条目被消费，不会长期占用
      expect(monitor.ignoreHashes, isNot(contains(hash)));
    });

    test('syncClipboard with unknown preReadImage triggers onImageChanged once', () async {
      final events = <ClipboardImage>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onImageChanged = events.add;

      final image = ClipboardImage(
        bytes: Uint8List.fromList([1, 2, 3]),
        format: 'png',
        width: 1,
        height: 1,
      );

      await monitor.syncClipboard(preReadImage: image);

      expect(events, hasLength(1));
    });
  });

  group('ClipboardMonitor placeholder/garbage text guard', () {
    test('hasImage true but getImage null: text branch is not reached', () async {
      var clipboardReads = 0;
      mockImageChannel((call) async {
        if (call.method == AppChannelMethods.hasImage) return true;
        if (call.method == AppChannelMethods.getImage) return null;
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          clipboardReads++;
          return <String, dynamic>{'text': 'real text'};
        }
        return null;
      });

      final texts = <String>[];
      final monitor = ClipboardMonitor(onChanged: texts.add);
      await monitor.syncClipboard();

      // 图片存在但读取失败时不得回退到文本分支
      expect(clipboardReads, 0);
    });

    test('[文件] placeholder text is not forwarded', () async {
      mockImageChannel((call) async {
        if (call.method == AppChannelMethods.hasImage) return false;
        return null;
      });
      mockClipboardText('[文件]');

      final texts = <String>[];
      final monitor = ClipboardMonitor(onChanged: texts.add);
      await monitor.debugCheckClipboard();

      expect(texts, isEmpty);
    });

    test('binary garbage text (NUL / many U+FFFD) is not forwarded', () async {
      mockImageChannel((call) async {
        if (call.method == AppChannelMethods.hasImage) return false;
        return null;
      });

      final texts = <String>[];
      final monitor = ClipboardMonitor(onChanged: texts.add);

      mockClipboardText('prefix\u0000suffix');
      await monitor.debugCheckClipboard();
      expect(texts, isEmpty);

      mockClipboardText('\uFFFD\uFFFD\uFFFDreal\uFFFD\uFFFD\uFFFD');
      await monitor.debugCheckClipboard();
      expect(texts, isEmpty);
    });
  });

  group('ClipboardMonitor Android onClipboardChanged guard', () {
    test('onClipboardChanged skips placeholder text like [文件]', () async {
      final texts = <String>[];
      final monitor = ClipboardMonitor(onChanged: texts.add);

      await monitor.debugHandleAndroidMethodCall(
        const MethodCall('onClipboardChanged', '[文件]'),
      );

      expect(texts, isEmpty);
    });

    test('onClipboardChanged skips NUL-containing garbage text', () async {
      final texts = <String>[];
      final monitor = ClipboardMonitor(onChanged: texts.add);

      await monitor.debugHandleAndroidMethodCall(
        const MethodCall('onClipboardChanged', 'prefix\u0000suffix'),
      );

      expect(texts, isEmpty);
    });

    test('onClipboardChanged forwards normal text', () async {
      final texts = <String>[];
      final monitor = ClipboardMonitor(onChanged: texts.add);

      await monitor.debugHandleAndroidMethodCall(
        const MethodCall('onClipboardChanged', 'real android text'),
      );

      expect(texts, ['real android text']);
    });
  });
}
