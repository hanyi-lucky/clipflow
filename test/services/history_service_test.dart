import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/history_service.dart';
import 'package:clipflow/models/clipboard_entry.dart';

void main() {
  late HistoryService service;

  final testEntry1 = ClipboardEntry(
    id: '1', content: 'First entry', sourceDeviceId: 'd1',
    sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, 1),
    type: ContentType.text, isPinned: false,
  );

  final testEntry2 = ClipboardEntry(
    id: '2', content: 'Second entry', sourceDeviceId: 'd2',
    sourceDeviceName: 'Android', timestamp: DateTime(2024, 1, 2),
    type: ContentType.text, isPinned: false,
  );

  setUp(() {
    service = HistoryService(maxEntries: 100);
  });

  test('should start with empty history', () {
    expect(service.entries.length, equals(0));
  });

  test('addEntry should add entry to top of list', () {
    service.addEntry(testEntry1);
    expect(service.entries.length, equals(1));
    expect(service.entries.first.id, equals('1'));
  });

  test('addEntry should deduplicate by content', () {
    service.addEntry(testEntry1);
    service.addEntry(ClipboardEntry(
      id: '1b', content: 'First entry', sourceDeviceId: 'd1',
      sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, 3),
      type: ContentType.text, isPinned: false,
    ));
    expect(service.entries.where((e) => e.content == 'First entry').length, equals(1));
  });

  test('removeEntry should remove by id', () {
    service.addEntry(testEntry1);
    service.addEntry(testEntry2);
    service.removeEntry('1');
    expect(service.entries.length, equals(1));
    expect(service.entries.first.id, equals('2'));
  });

  test('togglePin should toggle isPinned', () {
    service.addEntry(testEntry1);
    service.togglePin('1');
    expect(service.entries.first.isPinned, isTrue);
    service.togglePin('1');
    expect(service.entries.first.isPinned, isFalse);
  });

  test('pinned entries should stay when trimming', () {
    final smallService = HistoryService(maxEntries: 3);
    for (int i = 0; i < 3; i++) {
      smallService.addEntry(ClipboardEntry(
        id: '$i', content: 'Entry $i', sourceDeviceId: 'd1',
        sourceDeviceName: 'M', timestamp: DateTime(2024, 1, i + 1),
        type: ContentType.text, isPinned: false,
      ));
    }
    smallService.togglePin('0');
    smallService.addEntry(ClipboardEntry(
      id: 'new', content: 'New entry', sourceDeviceId: 'd1',
      sourceDeviceName: 'M', timestamp: DateTime(2024, 1, 10),
      type: ContentType.text, isPinned: false,
    ));
    expect(smallService.entries.any((e) => e.id == '0'), isTrue);
  });

  test('toJson and fromJson should round-trip', () {
    service.addEntry(testEntry1);
    service.addEntry(testEntry2);
    final json = service.toJson();

    final restored = HistoryService(maxEntries: 100);
    restored.fromJson(json);

    expect(restored.entries.length, equals(2));
    expect(restored.entries[0].id, equals(service.entries[0].id));
  });
}
