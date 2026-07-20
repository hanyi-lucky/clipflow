import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/hex_utils.dart';

void main() {
  group('hexToBytes', () {
    test('converts hex string to bytes', () {
      expect(hexToBytes('0a0b0c'), [0x0a, 0x0b, 0x0c]);
    });

    test('converts empty string to empty list', () {
      expect(hexToBytes(''), <int>[]);
    });

    test('handles uppercase hex', () {
      expect(hexToBytes('FF00AB'), [0xFF, 0x00, 0xAB]);
    });
  });

  group('bytesToHex', () {
    test('converts bytes to lowercase hex string', () {
      expect(bytesToHex([0x0a, 0x0b, 0x0c]), '0a0b0c');
    });

    test('converts empty list to empty string', () {
      expect(bytesToHex(<int>[]), '');
    });

    test('pads single-digit hex values with zero', () {
      expect(bytesToHex([0x00, 0x0F, 0xFF]), '000fff');
    });
  });

  group('round-trip', () {
    test('hexToBytes and bytesToHex are inverse operations', () {
      final original = [0x12, 0x34, 0xAB, 0xCD, 0xEF, 0x00, 0xFF];
      expect(hexToBytes(bytesToHex(original)), original);
    });
  });
}
