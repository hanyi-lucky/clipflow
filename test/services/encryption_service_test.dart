import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/encryption_service.dart';

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
    const plaintext = 'Hello, Universal Clipboard!';

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
}
