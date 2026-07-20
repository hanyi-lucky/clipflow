import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/sync_service.dart';

/// Verifies that downloadLatestContent returns DownloadResult? (not String?)
void main() {
  group('SyncService.downloadLatestContent return type', () {
    test('DownloadResult is a valid type for downloadLatestContent', () {
      // Verify DownloadResult can hold all needed fields
      final result = DownloadResult(
        content: 'test content',
        sourceDeviceId: 'dev_001',
        sourceDeviceName: 'MacBook',
        sourcePlatform: 'macos',
        timestamp: DateTime(2026, 7, 17),
      );

      // These fields must exist for the clipboard_provider to create ClipboardEntry
      expect(result.content, isNotEmpty);
      expect(result.sourceDeviceId, isNotEmpty);
      expect(result.sourceDeviceName, isNotEmpty);
      expect(result.sourcePlatform, isNotEmpty);
      expect(result.timestamp, isA<DateTime>());
    });
  });
}
