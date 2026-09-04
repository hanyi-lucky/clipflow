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

  test('addEntry should not deduplicate image entries with empty content', () {
    service.addEntry(ClipboardEntry(
      id: 'img-1',
      content: '',
      sourceDeviceId: 'd1',
      sourceDeviceName: 'Mac',
      timestamp: DateTime(2024, 1, 1),
      type: ContentType.image,
      imageWidth: 10,
      imageHeight: 10,
    ));
    service.addEntry(ClipboardEntry(
      id: 'img-2',
      content: '',
      sourceDeviceId: 'd1',
      sourceDeviceName: 'Mac',
      timestamp: DateTime(2024, 1, 2),
      type: ContentType.image,
      imageWidth: 20,
      imageHeight: 20,
    ));

    expect(service.entries.length, equals(2));
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

  group('image ID dedup', () {
    test('same ID image entry should be replaced, not duplicated', () {
      service.addEntry(ClipboardEntry(
        id: 'img-same',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.image,
        imageWidth: 100,
        imageHeight: 100,
        stableHash: 'hash-a',
      ));
      service.addEntry(ClipboardEntry(
        id: 'img-same',
        content: '',
        sourceDeviceId: 'd2',
        sourceDeviceName: 'Android',
        timestamp: DateTime(2024, 1, 2),
        type: ContentType.image,
        imageWidth: 100,
        imageHeight: 100,
        stableHash: 'hash-a',
      ));
      expect(service.entries.length, equals(1));
      expect(service.entries.first.sourceDeviceName, equals('Android'));
    });

    test('same ID image preserves pinned state from existing entry', () {
      service.addEntry(ClipboardEntry(
        id: 'img-pin',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.image,
        isPinned: true,
        stableHash: 'hash-pin',
      ));
      service.addEntry(ClipboardEntry(
        id: 'img-pin',
        content: '',
        sourceDeviceId: 'd2',
        sourceDeviceName: 'Android',
        timestamp: DateTime(2024, 1, 2),
        type: ContentType.image,
        isPinned: false,
        stableHash: 'hash-pin',
      ));
      expect(service.entries.length, equals(1));
      expect(service.entries.first.isPinned, isTrue);
    });
  });

  group('image stableHash dedup', () {
    test('same stableHash image replaces existing entry', () {
      service.addEntry(ClipboardEntry(
        id: 'img-old',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.image,
        imageWidth: 100,
        imageHeight: 100,
        stableHash: 'same-hash',
      ));
      service.addEntry(ClipboardEntry(
        id: 'img-new',
        content: '',
        sourceDeviceId: 'd2',
        sourceDeviceName: 'Android',
        timestamp: DateTime(2024, 1, 2),
        type: ContentType.image,
        imageWidth: 100,
        imageHeight: 100,
        stableHash: 'same-hash',
      ));
      expect(service.entries.length, equals(1));
      expect(service.entries.first.id, equals('img-new'));
    });

    test('different stableHash images coexist', () {
      service.addEntry(ClipboardEntry(
        id: 'img-a',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.image,
        stableHash: 'hash-alpha',
      ));
      service.addEntry(ClipboardEntry(
        id: 'img-b',
        content: '',
        sourceDeviceId: 'd2',
        sourceDeviceName: 'Android',
        timestamp: DateTime(2024, 1, 2),
        type: ContentType.image,
        stableHash: 'hash-beta',
      ));
      expect(service.entries.length, equals(2));
    });

    test('different ID images without stableHash coexist', () {
      service.addEntry(ClipboardEntry(
        id: 'img-x',
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.image,
      ));
      service.addEntry(ClipboardEntry(
        id: 'img-y',
        content: '',
        sourceDeviceId: 'd2',
        sourceDeviceName: 'Android',
        timestamp: DateTime(2024, 1, 2),
        type: ContentType.image,
      ));
      expect(service.entries.length, equals(2));
    });
  });

  group('file entries', () {
    ClipboardEntry fileEntry({
      required String id,
      required String fileName,
      required String fileHash,
    }) {
      return ClipboardEntry(
        id: id,
        content: '',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime(2024, 1, 1),
        type: ContentType.file,
        fileName: fileName,
        fileSize: 100,
        mimeType: 'application/octet-stream',
        fileHash: fileHash,
      );
    }

    test('same fileHash deduplicates without trim-based text matching', () {
      service.addEntry(fileEntry(id: 'file-a', fileName: 'a.txt', fileHash: 'hash-1'));
      service.addEntry(fileEntry(id: 'file-b', fileName: 'b.txt', fileHash: 'hash-1'));

      expect(service.entries.length, equals(1));
      expect(service.entries.first.id, equals('file-b'));
    });

    test('different fileHash file entries coexist', () {
      service.addEntry(fileEntry(id: 'file-a', fileName: 'a.txt', fileHash: 'hash-a'));
      service.addEntry(fileEntry(id: 'file-b', fileName: 'b.txt', fileHash: 'hash-b'));

      expect(service.entries.length, equals(2));
    });

    test('file entries never match text content dedupe path', () {
      service.addEntry(
        ClipboardEntry(
          id: 'text-1',
          content: 'same',
          sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac',
          timestamp: DateTime(2024, 1, 1),
          type: ContentType.text,
        ),
      );
      service.addEntry(
        ClipboardEntry(
          id: 'file-1',
          content: 'same',
          sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac',
          timestamp: DateTime(2024, 1, 2),
          type: ContentType.file,
          fileName: 'x.bin',
          fileHash: 'hash-x',
        ),
      );

      expect(service.entries.length, equals(2));
    });
  });

  group('updateMaxEntries', () {
    test('updateMaxEntries_reducesLimit_trimsOldestUnpinned', () {
      final svc = HistoryService(maxEntries: 100);
      // Add 50 unpinned entries (newest last in addOrder)
      for (int i = 0; i < 50; i++) {
        svc.addEntry(ClipboardEntry(
          id: 'trim-$i', content: 'Trim $i', sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
          type: ContentType.text, isPinned: false,
        ));
      }
      expect(svc.entries.length, equals(50));

      // Reduce limit to 20 — should trim oldest 30 unpinned
      svc.updateMaxEntries(20);

      expect(svc.entries.length, equals(20));
      // entries sorted by timestamp desc: newest first
      expect(svc.entries.first.content, equals('Trim 49'));
      expect(svc.entries.last.content, equals('Trim 30'));
    });

    test('updateMaxEntries_preservesPinned', () {
      final svc = HistoryService(maxEntries: 100);
      // Add 10 pinned entries
      for (int i = 0; i < 10; i++) {
        svc.addEntry(ClipboardEntry(
          id: 'pin-$i', content: 'Pinned $i', sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
          type: ContentType.text, isPinned: true,
        ));
      }
      // Add 50 unpinned entries
      for (int i = 0; i < 50; i++) {
        svc.addEntry(ClipboardEntry(
          id: 'up-$i', content: 'Unpinned $i', sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac', timestamp: DateTime(2024, 2, i + 1),
          type: ContentType.text, isPinned: false,
        ));
      }
      // 60 total: 10 pinned + 50 unpinned
      expect(svc.entries.length, equals(60));

      // Reduce to 30 — should keep all 10 pinned + 30 most recent unpinned
      svc.updateMaxEntries(30);

      expect(svc.entries.length, equals(40)); // 10 pinned + 30 unpinned
      final pinned = svc.entries.where((e) => e.isPinned).toList();
      expect(pinned.length, equals(10));
    });

    test('updateMaxEntries_increaseLimit_noOp', () {
      final svc = HistoryService(maxEntries: 20);
      for (int i = 0; i < 20; i++) {
        svc.addEntry(ClipboardEntry(
          id: 'e-$i', content: 'Entry $i', sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
          type: ContentType.text, isPinned: false,
        ));
      }
      expect(svc.entries.length, equals(20));

      // Increase limit — nothing should be removed
      svc.updateMaxEntries(50);

      expect(svc.entries.length, equals(20));
    });

    test('updateMaxEntries_zeroOrNegative_ignoredOrClamped', () {
      final svc = HistoryService(maxEntries: 10);
      for (int i = 0; i < 5; i++) {
        svc.addEntry(ClipboardEntry(
          id: 'z-$i', content: 'Zero $i', sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
          type: ContentType.text, isPinned: false,
        ));
      }
      // Setting to 0 trims all unpinned (maxEntries=0 means keep 0 unpinned)
      svc.updateMaxEntries(0);
      expect(svc.entries.length, equals(0));

      // Negative is clamped to 0, also trims all
      final svc2 = HistoryService(maxEntries: 10);
      for (int i = 0; i < 3; i++) {
        svc2.addEntry(ClipboardEntry(
          id: 'n-$i', content: 'Neg $i', sourceDeviceId: 'd1',
          sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
          type: ContentType.text, isPinned: false,
        ));
      }
      svc2.updateMaxEntries(-5);
      expect(svc2.entries.length, equals(0));
    });
  });
}
