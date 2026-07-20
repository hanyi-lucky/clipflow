import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/sync_service.dart';

void main() {
  group('DownloadResult', () {
    test('holds content and source device info', () {
      final result = DownloadResult(
        content: 'hello world',
        sourceDeviceId: 'device_mac_001',
        sourceDeviceName: 'MacBook Pro',
        sourcePlatform: 'macos',
        timestamp: DateTime(2026, 7, 17, 10, 30),
      );

      expect(result.content, 'hello world');
      expect(result.sourceDeviceId, 'device_mac_001');
      expect(result.sourceDeviceName, 'MacBook Pro');
      expect(result.sourcePlatform, 'macos');
      expect(result.timestamp, DateTime(2026, 7, 17, 10, 30));
    });

    test('deletedIds defaults to empty list', () {
      final result = DownloadResult(
        content: 'test',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        sourcePlatform: 'macos',
        timestamp: DateTime(2026, 7, 17),
      );

      expect(result.deletedIds, isEmpty);
    });

    test('deletedIds can be set explicitly', () {
      final result = DownloadResult(
        content: 'test',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        sourcePlatform: 'macos',
        timestamp: DateTime(2026, 7, 17),
        deletedIds: ['id-1', 'id-2', 'id-3'],
      );

      expect(result.deletedIds, ['id-1', 'id-2', 'id-3']);
      expect(result.deletedIds.length, 3);
    });
  });
}
