import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_file.dart';

void main() {
  group('ClipboardFile.fromMap', () {
    test('parses full metadata map', () {
      final file = ClipboardFile.fromMap({
        'path': '/tmp/a.txt',
        'name': 'a.txt',
        'mimeType': 'text/plain',
        'size': 1024,
        'lastModified': 1700000000000,
        'temp': true,
      });

      expect(file.path, '/tmp/a.txt');
      expect(file.name, 'a.txt');
      expect(file.mimeType, 'text/plain');
      expect(file.size, 1024);
      expect(file.lastModified, 1700000000000);
      expect(file.temp, isTrue);
      expect(file.errorCode, isNull);
    });

    test('parses numeric size/lastModified safely', () {
      final file = ClipboardFile.fromMap({
        'path': '/tmp/b.bin',
        'name': 'b.bin',
        'size': 123.0,
        'lastModified': 1700000000000.0,
      });

      expect(file.size, 123);
      expect(file.lastModified, 1700000000000);
    });

    test('missing fields degrade safely', () {
      final file = ClipboardFile.fromMap({'temp': true});

      expect(file.path, isNull);
      expect(file.name, isNull);
      expect(file.mimeType, isNull);
      expect(file.size, isNull);
      expect(file.lastModified, isNull);
      expect(file.temp, isTrue);
    });

    test('wrong types degrade to defaults', () {
      final file = ClipboardFile.fromMap({
        'path': 123,
        'name': ['x'],
        'size': 'big',
        'lastModified': 'now',
        'temp': 'yes',
        'errorCode': 'READ_ERROR',
      });

      expect(file.path, isNull);
      expect(file.name, isNull);
      expect(file.size, isNull);
      expect(file.lastModified, isNull);
      expect(file.temp, isFalse);
      expect(file.errorCode, 'READ_ERROR');
    });

    test('errorCode is preserved', () {
      final file = ClipboardFile.fromMap({
        'path': '/tmp/big.bin',
        'name': 'big.bin',
        'errorCode': 'FILE_TOO_LARGE',
      });

      expect(file.errorCode, 'FILE_TOO_LARGE');
    });
  });
}
