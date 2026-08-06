import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/device.dart';

void main() {
  group('Device.fromMap', () {
    test('parses server snake_case last_seen', () {
      final device = Device.fromMap({
        'id': 'dev-1',
        'name': 'Android · Xiaomi 15',
        'platform': 'android',
        'last_seen': '2026-08-06 10:38:14',
      });

      expect(device.id, 'dev-1');
      expect(device.name, 'Android · Xiaomi 15');
      expect(device.platform, 'android');
      expect(device.lastSeen.year, 2026);
      expect(device.lastSeen.month, 8);
      expect(device.lastSeen.day, 6);
    });

    test('parses camelCase lastSeen', () {
      final device = Device.fromMap({
        'id': 'dev-2',
        'name': 'Mac',
        'platform': 'macos',
        'lastSeen': '2026-08-06T10:38:14.000',
      });

      expect(device.lastSeen.year, 2026);
    });

    test('missing or malformed lastSeen falls back without throwing', () {
      final device = Device.fromMap({
        'id': 'dev-3',
        'name': 'Windows PC',
        'platform': 'windows',
      });

      expect(device.id, 'dev-3');
      expect(device.lastSeen, isA<DateTime>());
    });
  });
}
