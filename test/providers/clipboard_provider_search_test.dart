import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/services/history_service.dart';

void main() {
  late HistoryService service;

  final macEntry = ClipboardEntry(
    id: '1', content: 'Hello from Mac', sourceDeviceId: 'd1',
    sourceDeviceName: 'MacBook Pro', timestamp: DateTime(2024, 1, 1),
    type: ContentType.text,
  );
  final androidEntry = ClipboardEntry(
    id: '2', content: 'Link from Android', sourceDeviceId: 'd2',
    sourceDeviceName: 'Pixel 7', timestamp: DateTime(2024, 1, 2),
    type: ContentType.text,
  );
  final imageEntry = ClipboardEntry(
    id: '3', content: 'image_data', sourceDeviceId: 'd1',
    sourceDeviceName: 'MacBook Pro', timestamp: DateTime(2024, 1, 3),
    type: ContentType.image,
  );

  setUp(() {
    service = HistoryService(maxEntries: 100);
    service.addEntry(macEntry);
    service.addEntry(androidEntry);
    service.addEntry(imageEntry);
  });

  group('filteredHistory', () {
    test('returns all entries when no filters active', () {
      expect(service.entries.length, equals(3));
    });

    test('filters by content type', () {
      final filtered = service.entries.where((e) => e.type == ContentType.text).toList();
      expect(filtered.length, equals(2));
    });

    test('filters by device name', () {
      final filtered = service.entries.where((e) => e.sourceDeviceName == 'MacBook Pro').toList();
      expect(filtered.length, equals(2));
    });

    test('filters by search query (case-insensitive)', () {
      final query = 'hello';
      final filtered = service.entries.where((e) =>
        e.type == ContentType.text && e.content.toLowerCase().contains(query)
      ).toList();
      expect(filtered.length, equals(1));
      expect(filtered.first.id, equals('1'));
    });

    test('image entries do not match text search', () {
      final query = 'image';
      final filtered = service.entries.where((e) =>
        e.type == ContentType.text && e.content.toLowerCase().contains(query)
      ).toList();
      expect(filtered.length, equals(0));
    });

    test('combined type + device filter', () {
      var results = service.entries;
      results = results.where((e) => e.type == ContentType.text).toList();
      results = results.where((e) => e.sourceDeviceName == 'MacBook Pro').toList();
      expect(results.length, equals(1));
      expect(results.first.id, equals('1'));
    });

    test('available devices are unique', () {
      final devices = service.entries.map((e) => e.sourceDeviceName).toSet().toList();
      expect(devices.length, equals(2));
      expect(devices, containsAll(['MacBook Pro', 'Pixel 7']));
    });
  });
}
