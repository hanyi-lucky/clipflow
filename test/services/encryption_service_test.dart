import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'dart:typed_data';

void main() {
  late EncryptionService service;
  const testPassword = 'my-test-password-2024';
  final testSalt = List<int>.generate(32, (i) => i % 256);

  setUp(() {
    service = EncryptionService();
  });

  test('deriveKey should produce 32-byte key', () async {
    final key = await service.deriveKey(testPassword, testSalt);
    expect(key.length, equals(32));
  });

  test('deriveKey with same inputs should produce same key', () async {
    final key1 = await service.deriveKey(testPassword, testSalt);
    final key2 = await service.deriveKey(testPassword, testSalt);
    expect(key1, equals(key2));
  });

  test('deriveKey with different passwords should produce different keys', () async {
    final key1 = await service.deriveKey(testPassword, testSalt);
    final key2 = await service.deriveKey('different-password', testSalt);
    expect(key1, isNot(equals(key2)));
  });

  test('encrypt and decrypt should round-trip correctly', () async {
    final key = await service.deriveKey(testPassword, testSalt);
    const plaintext = 'Hello, ClipFlow!';

    final encrypted = await service.encrypt(plaintext, key);
    final decrypted = await service.decrypt(encrypted, key);

    expect(decrypted, equals(plaintext));
  });

  test('encrypt should produce different ciphertext each time (random IV)', () async {
    final key = await service.deriveKey(testPassword, testSalt);
    const plaintext = 'Same content';

    final enc1 = await service.encrypt(plaintext, key);
    final enc2 = await service.encrypt(plaintext, key);

    expect(enc1.ciphertext, isNot(equals(enc2.ciphertext)));
  });

  test('decrypt with wrong key should throw', () async {
    final key = await service.deriveKey(testPassword, testSalt);
    final wrongKey = await service.deriveKey('wrong-password', testSalt);
    final encrypted = await service.encrypt('test', key);

    expect(
      () async => await service.decrypt(encrypted, wrongKey),
      throwsA(isA<Exception>()),
    );
  });

  test('generateSalt should return 32 bytes', () {
    final salt = service.generateSalt();
    expect(salt.length, equals(32));
  });

  test('generateSalt should produce different results each call', () {
    final salt1 = service.generateSalt();
    final salt2 = service.generateSalt();
    expect(salt1, isNot(equals(salt2)));
  });

  test('encrypt and decrypt empty string', () async {
    final key = await service.deriveKey(testPassword, testSalt);
    final encrypted = await service.encrypt('', key);
    final decrypted = await service.decrypt(encrypted, key);
    expect(decrypted, equals(''));
  });

  test('encrypt and decrypt long text', () async {
    final key = await service.deriveKey(testPassword, testSalt);
    final plaintext = 'A' * 10000;

    final encrypted = await service.encrypt(plaintext, key);
    final decrypted = await service.decrypt(encrypted, key);

    expect(decrypted, equals(plaintext));
  });

  test('deriveKeyIsolate should produce same key as deriveKey', () async {
    final keySync = await service.deriveKey(testPassword, testSalt);
    final keyIsolate = await service.deriveKeyIsolate(testPassword, testSalt);
    expect(keyIsolate, equals(keySync));
  });

  test('deriveKeyIsolate should produce 32-byte key', () async {
    final key = await service.deriveKeyIsolate(testPassword, testSalt);
    expect(key.length, equals(32));
  });

  test('deriveKeyIsolate with different passwords should produce different keys', () async {
    final key1 = await service.deriveKeyIsolate(testPassword, testSalt);
    final key2 = await service.deriveKeyIsolate('different-password', testSalt);
    expect(key1, isNot(equals(key2)));
  });

  group('encryptBytes/decryptBytes (binary)', () {
    test('should round-trip binary data', () async {
      final key = await service.deriveKey(testPassword, testSalt);
      final plaintext = Uint8List.fromList(
        List.generate(1024, (i) => i % 251),
      );

      final encrypted = await service.encryptBytes(plaintext, key);
      final decrypted = await service.decryptBytes(encrypted, key);

      expect(decrypted, equals(plaintext));
    });

    test('base64 output should parse back with EncryptedData.fromBase64', () async {
      final key = await service.deriveKey(testPassword, testSalt);
      final encrypted = await service.encryptBytes(
        Uint8List.fromList([1, 2, 3, 4]),
        key,
      );

      final decoded = EncryptedData.fromBase64(encrypted.toBase64());

      expect(decoded.ciphertext, equals(encrypted.ciphertext));
      expect(decoded.iv, equals(encrypted.iv));
    });

    test('should produce different ciphertext each time (random IV)', () async {
      final key = await service.deriveKey(testPassword, testSalt);
      final plaintext = Uint8List.fromList([9, 9, 9]);

      final enc1 = await service.encryptBytes(plaintext, key);
      final enc2 = await service.encryptBytes(plaintext, key);

      expect(enc1.ciphertext, isNot(equals(enc2.ciphertext)));
    });

    test('decryptBytes with wrong key should throw', () async {
      final key = await service.deriveKey(testPassword, testSalt);
      final wrongKey = await service.deriveKey('wrong-password', testSalt);
      final encrypted = await service.encryptBytes(
        Uint8List.fromList([1, 2, 3]),
        key,
      );

      expect(
        () async => await service.decryptBytes(encrypted, wrongKey),
        throwsA(isA<Exception>()),
      );
    });

    test('decryptBytesIsolate should decrypt encrypted payload', () async {
      final key = await service.deriveKey(testPassword, testSalt);
      final plaintext = Uint8List.fromList(
        List.generate(65536, (i) => i % 256),
      );
      final encrypted = await service.encryptBytes(plaintext, key);

      final decrypted = await service.decryptBytesIsolate(
        key,
        encrypted.toBase64(),
      );

      expect(decrypted, equals(plaintext));
    });
  });
}
