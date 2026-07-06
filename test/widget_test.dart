import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/models/device.dart';
import 'package:clipflow/services/history_service.dart';
import 'package:clipflow/services/encryption_service.dart';

/// Smoke tests for core services.
/// Full UI tests will be verified manually via `flutter run` on each platform.
void main() {
  group('Core models smoke test', () {
    test('ClipboardEntry creation', () {
      final entry = ClipboardEntry(
        id: '1',
        content: 'Hello',
        sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac',
        timestamp: DateTime.now(),
        type: ContentType.text,
      );
      expect(entry.content, 'Hello');
      expect(entry.type, ContentType.text);
    });

    test('Device creation', () {
      final device = Device(
        id: 'd1',
        name: 'MacBook',
        platform: 'macos',
        lastSeen: DateTime.now(),
      );
      expect(device.id, 'd1');
      expect(device.platform, 'macos');
    });
  });

  group('HistoryService smoke test', () {
    test('basic add and remove', () {
      final service = HistoryService(maxEntries: 10);
      expect(service.entries.length, 0);

      service.addEntry(ClipboardEntry(
        id: '1', content: 'test', sourceDeviceId: 'd1',
        sourceDeviceName: 'M', timestamp: DateTime.now(),
        type: ContentType.text,
      ));
      expect(service.entries.length, 1);

      service.removeEntry('1');
      expect(service.entries.length, 0);
    });
  });

  group('EncryptionService smoke test', () {
    test('generateSalt returns bytes', () {
      final service = EncryptionService();
      final salt = service.generateSalt();
      expect(salt.length, 32);
    });
  });
}
