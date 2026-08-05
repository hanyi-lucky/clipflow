import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/clipboard_channel_constants.dart';
import 'package:clipflow/services/image_clipboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppChannelNames.clipboard);

  void mockHandler(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('ImageClipboardService', () {
    test('hasImage returns false when platform channel is missing', () async {
      final service = ImageClipboardService();

      expect(await service.hasImage(), isFalse);
    });

    test('hasImage returns true when channel returns true', () async {
      mockHandler((call) async {
        if (call.method == AppChannelMethods.hasImage) return true;
        return null;
      });

      final service = ImageClipboardService();

      expect(await service.hasImage(), isTrue);
    });

    test('getImage returns null when channel returns null', () async {
      mockHandler((call) async {
        if (call.method == AppChannelMethods.getImage) return null;
        return null;
      });

      final service = ImageClipboardService();

      expect(await service.getImage(), isNull);
    });

    test('getImage parses Uint8List bytes from map result', () async {
      mockHandler((call) async {
        if (call.method == AppChannelMethods.getImage) {
          return {
            'bytes': Uint8List.fromList([1, 2, 3]),
            'format': 'png',
            'width': 10,
            'height': 20,
          };
        }
        return null;
      });

      final service = ImageClipboardService();
      final image = await service.getImage();

      expect(image, isNotNull);
      expect(image!.bytes, equals([1, 2, 3]));
      expect(image.format, equals('png'));
      expect(image.width, equals(10));
      expect(image.height, equals(20));
    });

    test('getImage handles non-Uint8List bytes defensively', () async {
      mockHandler((call) async {
        if (call.method == AppChannelMethods.getImage) {
          return {
            'bytes': [4, 5, 6],
            'format': 'png',
            'width': 1,
            'height': 1,
          };
        }
        return null;
      });

      final service = ImageClipboardService();
      final image = await service.getImage();

      expect(image, isNotNull);
      expect(image!.bytes, equals([4, 5, 6]));
    });

    test('getImage returns null when channel throws', () async {
      mockHandler((call) async {
        throw PlatformException(code: 'ERROR');
      });

      final service = ImageClipboardService();

      expect(await service.getImage(), isNull);
    });

    test('setImage sends bytes and format to channel', () async {
      String? capturedMethod;
      Map<Object?, Object?>? capturedArgs;
      mockHandler((call) async {
        capturedMethod = call.method;
        capturedArgs = call.arguments as Map<Object?, Object?>;
        return true;
      });

      final service = ImageClipboardService();
      final ok = await service.setImage(
        Uint8List.fromList([9, 9, 9]),
        format: 'png',
      );

      expect(ok, isTrue);
      expect(capturedMethod, equals(AppChannelMethods.setImage));
      expect(capturedArgs!['bytes'], equals([9, 9, 9]));
      expect(capturedArgs!['format'], equals('png'));
    });

    test('setImage returns false when channel throws', () async {
      mockHandler((call) async {
        throw PlatformException(code: 'ERROR');
      });

      final service = ImageClipboardService();

      expect(await service.setImage(Uint8List.fromList([1])), isFalse);
    });
  });
}
