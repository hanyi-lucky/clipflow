import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/sync_service.dart';

void main() {
  group('SyncService deletedIds handling', () {

    test('DownloadResult carries deletedIds from server response', () {
      // Simulate a server response with deletedIds
      final deletedIds = ['entry-001', 'entry-002'];

      final result = DownloadResult(
        content: 'synced content',
        sourceDeviceId: 'device_remote',
        sourceDeviceName: 'Android Phone',
        sourcePlatform: 'android',
        timestamp: DateTime(2026, 7, 17, 12, 0),
        deletedIds: deletedIds,
      );

      expect(result.deletedIds, equals(['entry-001', 'entry-002']));
      expect(result.deletedIds.length, 2);
    });

    test('DownloadResult with empty deletedIds behaves like before', () {
      final result = DownloadResult(
        content: 'content',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        sourcePlatform: 'macos',
        timestamp: DateTime(2026, 7, 17),
      );

      expect(result.deletedIds, isEmpty);
      expect(result.content, 'content');
    });

    test('deletedIds defaults to empty list when not provided', () {
      // This ensures backward compatibility - existing code that creates
      // DownloadResult without deletedIds still works
      final result = DownloadResult(
        content: 'test',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'M',
        sourcePlatform: 'macos',
        timestamp: DateTime.now(),
      );

      expect(result.deletedIds, const []);
    });
  });
}
