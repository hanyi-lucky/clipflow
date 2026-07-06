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
  });
}
