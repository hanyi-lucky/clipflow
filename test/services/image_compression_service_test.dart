import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/core/exceptions.dart';
import 'package:clipflow/services/image_compression_service.dart';

void main() {
  final service = ImageCompressionService();

  Uint8List encodeTestImage(int width, int height, {bool alpha = false}) {
    final image = img.Image(
      width: width,
      height: height,
      numChannels: alpha ? 4 : 3,
    );
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgba(x, y, 200, 120, 40, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  group('ImageCompressionService', () {
    test('should downscale large image long edge to maxImageDimension', () async {
      final bytes = encodeTestImage(3000, 2000);

      final result = await service.compress(bytes);

      expect(result.width, equals(AppConstants.maxImageDimension));
      expect(result.height, lessThanOrEqualTo(AppConstants.maxImageDimension));
    });

    test('should not upscale small image', () async {
      final bytes = encodeTestImage(100, 80);

      final result = await service.compress(bytes);

      expect(result.width, equals(100));
      expect(result.height, equals(80));
    });

    test('should keep PNG format when image has alpha channel', () async {
      final bytes = encodeTestImage(400, 300, alpha: true);

      final result = await service.compress(bytes);

      expect(result.format, equals('png'));
    });

    test('should use JPEG format for opaque images', () async {
      final bytes = encodeTestImage(400, 300);

      final result = await service.compress(bytes);

      expect(result.format, equals('jpeg'));
    });

    test('should produce thumbnail with long edge within thumbDimension', () async {
      final bytes = encodeTestImage(1600, 1200);

      final result = await service.compress(bytes);
      final decoded = img.decodeImage(result.thumbBytes);

      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(AppConstants.thumbDimension));
      expect(decoded.height, lessThanOrEqualTo(AppConstants.thumbDimension));
    });

    test('should reduce file size of large noisy image', () async {
      // 带噪点的图片 PNG 几乎不可压缩，JPEG 重编码后体积应明显下降
      final image = img.Image(width: 3000, height: 2000, numChannels: 3);
      final random = math.Random(42);
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          image.setPixelRgba(
            x,
            y,
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
            255,
          );
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(image));

      final result = await service.compress(bytes);

      expect(result.bytes.length, lessThan(bytes.length));
    });

    test('should throw ImageCompressionException on invalid bytes', () async {
      final bogus = Uint8List.fromList(List.generate(100, (i) => i));

      expect(
        () async => await service.compress(bogus),
        throwsA(isA<ImageCompressionException>()),
      );
    });

    test('stableHash is stable across lossless re-encoding', () async {
      final original = encodeTestImage(800, 600);

      final first = await service.compress(original);

      // 模拟 macOS/Android 写入剪切板时的重编码：
      // 解码压缩产物后无损重编码为 PNG，字节必然不同，但像素内容一致
      final decoded = img.decodeImage(first.bytes)!;
      final reencoded = Uint8List.fromList(img.encodePng(decoded));
      final second = await service.compress(reencoded);

      expect(first.stableHash, isNotEmpty);
      expect(second.stableHash, equals(first.stableHash));
    });

    test('stableHash differs for different pixel content', () async {
      final red = img.Image(width: 64, height: 64, numChannels: 3);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          red.setPixelRgba(x, y, 200, 30, 30, 255);
        }
      }
      final blue = img.Image(width: 64, height: 64, numChannels: 3);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          blue.setPixelRgba(x, y, 30, 30, 200, 255);
        }
      }

      final a = await service.compress(Uint8List.fromList(img.encodePng(red)));
      final b = await service.compress(Uint8List.fromList(img.encodePng(blue)));

      expect(a.stableHash, isNot(equals(b.stableHash)));
    });
  });
}
