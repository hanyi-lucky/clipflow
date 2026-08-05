import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';

void main() {
  group('ClipboardEntry', () {
    test('should compute correct content hash', () {
      final entry = ClipboardEntry(
        id: 'entry-1',
        content: 'Hello, World!',
        sourceDeviceId: 'device-1',
        sourceDeviceName: 'MacBook',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.text,
        isPinned: false,
      );

      final hash = entry.contentHash;
      expect(hash, isNotEmpty);
      expect(hash.length, greaterThan(10));
    });

    test('same content should produce same hash', () {
      final entry1 = ClipboardEntry(
        id: '1', content: 'test', sourceDeviceId: 'd1',
        sourceDeviceName: 'M', timestamp: DateTime.now(),
        type: ContentType.text, isPinned: false,
      );
      final entry2 = ClipboardEntry(
        id: '2', content: 'test', sourceDeviceId: 'd2',
        sourceDeviceName: 'W', timestamp: DateTime.now(),
        type: ContentType.text, isPinned: false,
      );

      expect(entry1.contentHash, equals(entry2.contentHash));
    });

    test('different content should produce different hash', () {
      final entry1 = ClipboardEntry(
        id: '1', content: 'test1', sourceDeviceId: 'd1',
        sourceDeviceName: 'M', timestamp: DateTime.now(),
        type: ContentType.text, isPinned: false,
      );
      final entry2 = ClipboardEntry(
        id: '2', content: 'test2', sourceDeviceId: 'd2',
        sourceDeviceName: 'W', timestamp: DateTime.now(),
        type: ContentType.text, isPinned: false,
      );

      expect(entry1.contentHash, isNot(equals(entry2.contentHash)));
    });

    test('copyWith should preserve unchanged fields', () {
      final entry = ClipboardEntry(
        id: '1', content: 'test', sourceDeviceId: 'd1',
        sourceDeviceName: 'M', timestamp: DateTime.now(),
        type: ContentType.text, isPinned: false,
      );

      final pinned = entry.copyWith(isPinned: true);

      expect(pinned.isPinned, isTrue);
      expect(pinned.id, equals(entry.id));
      expect(pinned.content, equals(entry.content));
    });

    test('contentHash should use stableHash when present', () {
      final entry = ClipboardEntry(
        id: '1',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        timestamp: DateTime.now(),
        type: ContentType.image,
        stableHash: 'stable-hash-123',
      );

      expect(entry.contentHash, equals('stable-hash-123'));
    });

    test('toMap and fromMap should round-trip image fields', () {
      final entry = ClipboardEntry(
        id: '1',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.image,
        imageThumbEncryptedBase64: 'thumb-ciphertext',
        imageWidth: 1024,
        imageHeight: 768,
        imageFormat: 'jpeg',
        stableHash: 'hash-1',
      );

      final restored = ClipboardEntry.fromMap(entry.toMap());

      expect(restored.imageThumbEncryptedBase64, equals('thumb-ciphertext'));
      expect(restored.imageWidth, equals(1024));
      expect(restored.imageHeight, equals(768));
      expect(restored.imageFormat, equals('jpeg'));
      expect(restored.stableHash, equals('hash-1'));
      expect(restored.type, equals(ContentType.image));
    });

    test('fromMap should parse old JSON without image fields', () {
      final map = {
        'id': '1',
        'content': 'hello',
        'sourceDeviceId': 'd1',
        'sourceDeviceName': 'M',
        'sourcePlatform': 'macos',
        'timestamp': DateTime(2024, 1, 1).toIso8601String(),
        'type': 'text',
        'isPinned': false,
      };

      final entry = ClipboardEntry.fromMap(map);

      expect(entry.imageThumbEncryptedBase64, isNull);
      expect(entry.imageWidth, isNull);
      expect(entry.imageHeight, isNull);
      expect(entry.imageFormat, isNull);
      expect(entry.stableHash, isNull);
      expect(entry.content, equals('hello'));
      expect(entry.type, equals(ContentType.text));
    });

    test('toMap should not serialize full-image ciphertext', () {
      final entry = ClipboardEntry(
        id: '1',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        timestamp: DateTime.now(),
        type: ContentType.image,
        imageEncryptedBase64: 'full-ciphertext',
      );

      expect(entry.toMap().containsKey('imageEncryptedBase64'), isFalse);
    });

    test('contentHash prefers fileHash for file entries', () {
      final entry = ClipboardEntry(
        id: 'file-1',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        timestamp: DateTime.now(),
        type: ContentType.file,
        fileName: 'report.pdf',
        fileSize: 2048,
        mimeType: 'application/pdf',
        fileHash: 'file-hash-abc',
      );

      expect(entry.contentHash, equals('file-hash-abc'));
    });

    test('toMap and fromMap round-trip file fields', () {
      final entry = ClipboardEntry(
        id: 'file-2',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        sourcePlatform: 'macos',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.file,
        fileName: 'archive.zip',
        fileSize: 4096,
        mimeType: 'application/zip',
        fileHash: 'sha-256-of-file',
      );

      final restored = ClipboardEntry.fromMap(entry.toMap());

      expect(restored.type, equals(ContentType.file));
      expect(restored.fileName, equals('archive.zip'));
      expect(restored.fileSize, equals(4096));
      expect(restored.mimeType, equals('application/zip'));
      expect(restored.fileHash, equals('sha-256-of-file'));
      expect(restored.contentHash, equals('sha-256-of-file'));
    });

    test('copyWith updates file fields', () {
      final entry = ClipboardEntry(
        id: 'file-3',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        timestamp: DateTime.now(),
        type: ContentType.file,
        fileName: 'old.txt',
      );

      final updated = entry.copyWith(
        fileName: 'new.txt',
        fileSize: 100,
        mimeType: 'text/plain',
        fileHash: 'new-hash',
      );

      expect(updated.fileName, 'new.txt');
      expect(updated.fileSize, 100);
      expect(updated.mimeType, 'text/plain');
      expect(updated.fileHash, 'new-hash');
    });
  });
}
