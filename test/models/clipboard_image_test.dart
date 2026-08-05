import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_image.dart';

void main() {
  group('ClipboardImage', () {
    test('should hold bytes, format, width and height', () {
      final image = ClipboardImage(
        bytes: Uint8List.fromList([1, 2, 3]),
        format: 'png',
        width: 10,
        height: 20,
      );

      expect(image.bytes, equals([1, 2, 3]));
      expect(image.format, equals('png'));
      expect(image.width, equals(10));
      expect(image.height, equals(20));
    });
  });
}
