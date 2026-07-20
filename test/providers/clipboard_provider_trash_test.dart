import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/services/history_service.dart';

void main() {
  group('ClipboardProvider trash integration', () {
    test('HistoryService.removeEntry removes entry by id', () {
      // This tests the core mechanism used by deletedIds sync
      final service = HistoryService(maxEntries: 100);

      service.addEntry(ClipboardEntry(
        id: 'entry-1',
        content: 'First',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.text,
      ));

      service.addEntry(ClipboardEntry(
        id: 'entry-2',
        content: 'Second',
        sourceDeviceId: 'd2',
        sourceDeviceName: 'Android',
        timestamp: DateTime(2024, 1, 2),
        type: ContentType.text,
      ));

      expect(service.entries.length, 2);

      // Simulate what deletedIds sync does: remove entries by id
      service.removeEntry('entry-1');

      expect(service.entries.length, 1);
      expect(service.entries.first.id, 'entry-2');
    });

    test('removeEntry with non-existent id does nothing', () {
      final service = HistoryService(maxEntries: 100);

      service.addEntry(ClipboardEntry(
        id: 'entry-1',
        content: 'Test',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.text,
      ));

      // Should not throw
      service.removeEntry('non-existent-id');
      expect(service.entries.length, 1);
    });

    test('multiple removeEntry calls for deletedIds batch', () {
      final service = HistoryService(maxEntries: 100);

      for (int i = 0; i < 5; i++) {
        service.addEntry(ClipboardEntry(
          id: 'entry-$i',
          content: 'Content $i',
          sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac',
          timestamp: DateTime(2024, 1, i + 1),
          type: ContentType.text,
        ));
      }

      expect(service.entries.length, 5);

      // Simulate batch deletion from deletedIds
      final deletedIds = ['entry-1', 'entry-3'];
      for (final id in deletedIds) {
        service.removeEntry(id);
      }

      expect(service.entries.length, 3);
      expect(service.entries.any((e) => e.id == 'entry-1'), isFalse);
      expect(service.entries.any((e) => e.id == 'entry-3'), isFalse);
      expect(service.entries.any((e) => e.id == 'entry-0'), isTrue);
      expect(service.entries.any((e) => e.id == 'entry-2'), isTrue);
      expect(service.entries.any((e) => e.id == 'entry-4'), isTrue);
    });
  });
}
