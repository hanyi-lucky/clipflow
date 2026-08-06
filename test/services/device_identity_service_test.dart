import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/device_identity_service.dart';

void main() {
  group('buildDefaultDeviceName', () {
    test('Android with model', () {
      expect(
        buildDefaultDeviceName(platform: 'android', model: 'Xiaomi 15'),
        'Android · Xiaomi 15',
      );
    });

    test('Android with empty model', () {
      expect(
        buildDefaultDeviceName(platform: 'android', model: ''),
        'Android Phone',
      );
    });

    test('Android with null model', () {
      expect(
        buildDefaultDeviceName(platform: 'android', model: null),
        'Android Phone',
      );
    });

    test('Windows with model', () {
      expect(
        buildDefaultDeviceName(platform: 'windows', model: 'DESKTOP-ABC123'),
        'Windows · DESKTOP-ABC123',
      );
    });

    test('Windows with empty model', () {
      expect(
        buildDefaultDeviceName(platform: 'windows', model: ''),
        'Windows PC',
      );
    });

    test('Windows with null model', () {
      expect(
        buildDefaultDeviceName(platform: 'windows', model: null),
        'Windows PC',
      );
    });

    test('macOS with model', () {
      expect(
        buildDefaultDeviceName(platform: 'macos', model: 'MacBookPro18,3'),
        'Mac · MacBookPro18,3',
      );
    });

    test('macOS with empty model', () {
      expect(
        buildDefaultDeviceName(platform: 'macos', model: ''),
        'Mac',
      );
    });

    test('macOS with null model', () {
      expect(
        buildDefaultDeviceName(platform: 'macos', model: null),
        'Mac',
      );
    });

    test('iOS with model', () {
      expect(
        buildDefaultDeviceName(platform: 'ios', model: 'iPhone'),
        'iOS · iPhone',
      );
    });

    test('iOS with empty model', () {
      expect(
        buildDefaultDeviceName(platform: 'ios', model: ''),
        'iOS Device',
      );
    });

    test('iOS with null model', () {
      expect(
        buildDefaultDeviceName(platform: 'ios', model: null),
        'iOS Device',
      );
    });

    test('Unknown platform', () {
      expect(
        buildDefaultDeviceName(platform: 'linux', model: 'Ubuntu'),
        'Unknown Device',
      );
    });

    test('Unknown platform with null model', () {
      expect(
        buildDefaultDeviceName(platform: 'linux', model: null),
        'Unknown Device',
      );
    });

    test('Model with leading/trailing spaces', () {
      expect(
        buildDefaultDeviceName(platform: 'android', model: '  Xiaomi 15  '),
        'Android · Xiaomi 15',
      );
    });
  });

  group('uniqueDeviceName', () {
    test('returns base name when not used', () {
      expect(
        uniqueDeviceName('Android · Xiaomi 15', ['Windows · PC']),
        'Android · Xiaomi 15',
      );
    });

    test('appends (2) when base name is used once', () {
      expect(
        uniqueDeviceName('Android · Xiaomi 15', ['Android · Xiaomi 15']),
        'Android · Xiaomi 15 (2)',
      );
    });

    test('appends increasing suffix for multiple collisions', () {
      expect(
        uniqueDeviceName('Android · Xiaomi 15', [
          'Android · Xiaomi 15',
          'Android · Xiaomi 15 (2)',
        ]),
        'Android · Xiaomi 15 (3)',
      );
    });
  });
}
