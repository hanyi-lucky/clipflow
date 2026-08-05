import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/clipboard_channel_constants.dart';
import 'package:clipflow/services/file_clipboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppChannelNames.clipboard);

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('FileClipboardService', () {
    test('hasFiles returns native bool', () async {
      mockChannel((call) async {
        expect(call.method, AppChannelMethods.hasFiles);
        return true;
      });
      expect(await FileClipboardService().hasFiles(), isTrue);
    });

    test('hasFiles returns false when channel throws', () async {
      mockChannel((call) async => throw PlatformException(code: 'missing'));
      expect(await FileClipboardService().hasFiles(), isFalse);
    });

    test('getFiles parses metadata maps defensively', () async {
      mockChannel((call) async {
        expect(call.method, AppChannelMethods.getFiles);
        return [
          {
            'path': '/tmp/a.txt',
            'name': 'a.txt',
            'mimeType': 'text/plain',
            'size': 10,
            'lastModified': 1700000000000,
            'temp': false,
          },
          {'path': '/tmp/b.txt'},
        ];
      });

      final files = await FileClipboardService().getFiles();

      expect(files, isNotNull);
      expect(files, hasLength(2));
      expect(files!.first.path, '/tmp/a.txt');
      expect(files.first.name, 'a.txt');
      expect(files.first.size, 10);
      expect(files.last.name, isNull);
    });

    test('getFiles ignores malformed list entries', () async {
      mockChannel((call) async => [
            'not-a-map',
            123,
            {'path': '/tmp/ok.txt'},
          ]);

      final files = await FileClipboardService().getFiles();

      expect(files, hasLength(1));
      expect(files!.first.path, '/tmp/ok.txt');
    });

    test('getFiles returns null on channel failure', () async {
      mockChannel((call) async => throw PlatformException(code: 'boom'));
      expect(await FileClipboardService().getFiles(), isNull);
    });

    test('setFiles sends paths under map key and returns bool', () async {
      Object? captured;
      mockChannel((call) async {
        expect(call.method, AppChannelMethods.setFiles);
        captured = call.arguments;
        return true;
      });

      final result = await FileClipboardService().setFiles(['/tmp/a.txt']);

      expect(result, isTrue);
      expect((captured as Map)['paths'], ['/tmp/a.txt']);
    });

    test('setFiles returns false on channel failure', () async {
      mockChannel((call) async => throw PlatformException(code: 'boom'));
      expect(
        await FileClipboardService().setFiles(['/tmp/a.txt']),
        isFalse,
      );
    });
  });
}
