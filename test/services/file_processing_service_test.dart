import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/file_processing_service.dart';

void main() {
  late Directory tempDir;
  late FileProcessingService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('clipflow_file_processing_');
    service = FileProcessingService();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  File writeSource(String name, List<int> bytes) {
    final file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  String sha256Hex(List<int> bytes) =>
      sha256.convert(bytes).toString();

  group('FileProcessingService hashFile', () {
    test('computes streaming SHA-256 of file content', () async {
      final bytes = List<int>.generate(200000, (i) => i % 251);
      final source = writeSource('hash.bin', bytes);

      final hash = await service.hashFile(source.path);

      expect(hash, equals(sha256Hex(bytes)));
    });

    test('hash of empty file is valid sha256', () async {
      final source = writeSource('empty.bin', []);
      final hash = await service.hashFile(source.path);

      expect(hash, equals(sha256Hex([])));
    });
  });

  group('FileProcessingService streaming encrypt/decrypt', () {
    late EncryptionService encryption;
    late Uint8List key;

    setUp(() async {
      encryption = EncryptionService();
      key = await encryption.deriveKey('file-test-password', [
        for (var i = 0; i < 32; i++) i,
      ]);
    });

    test('streaming payload interoperates with EncryptedData.fromBytes/decryptBytes',
        () async {
      final bytes = List<int>.generate(300000, (i) => (i * 7) % 251);
      final source = writeSource('interop.bin', bytes);
      final encryptedPath = '${tempDir.path}/interop.enc';

      final hash = await service.encryptFile(
        sourcePath: source.path,
        encryptedPath: encryptedPath,
        key: key,
      );
      expect(hash, equals(sha256Hex(bytes)));

      // 兼容门禁：streaming 产物必须能被现有 EncryptedData 读回
      final encryptedBytes = File(encryptedPath).readAsBytesSync();
      final data = EncryptedData.fromBytes(
        Uint8List.fromList(encryptedBytes),
      );
      final decrypted = await encryption.decryptBytes(data, key);

      expect(decrypted, equals(bytes));
      expect(data.iv.length, greaterThanOrEqualTo(12));

      // base64 路径同样可读（与旧客户端格式完全一致）
      final fromBase64 = EncryptedData.fromBase64(
        EncryptedData(
          ciphertext: data.ciphertext,
          iv: data.iv,
        ).toBase64(),
      );
      expect(
        await encryption.decryptBytes(fromBase64, key),
        equals(bytes),
      );
    });

    test('decryptFile returns plaintext file and correct hash', () async {
      final bytes = List<int>.generate(100000, (i) => i % 256);
      final source = writeSource('roundtrip.bin', bytes);
      final encryptedPath = '${tempDir.path}/roundtrip.enc';
      final plaintextPath = '${tempDir.path}/roundtrip.out';

      await service.encryptFile(
        sourcePath: source.path,
        encryptedPath: encryptedPath,
        key: key,
      );
      final hash = await service.decryptFile(
        encryptedPath: encryptedPath,
        plaintextPath: plaintextPath,
        key: key,
      );

      expect(hash, equals(sha256Hex(bytes)));
      expect(File(plaintextPath).readAsBytesSync(), equals(bytes));
    });

    test('tampered ciphertext fails decryption', () async {
      final source = writeSource('tamper.bin', List.generate(4096, (i) => i));
      final encryptedPath = '${tempDir.path}/tamper.enc';
      final plaintextPath = '${tempDir.path}/tamper.out';
      await service.encryptFile(
        sourcePath: source.path,
        encryptedPath: encryptedPath,
        key: key,
      );

      final bytes = File(encryptedPath).readAsBytesSync();
      bytes[bytes.length ~/ 2] ^= 0x01;
      File(encryptedPath).writeAsBytesSync(bytes);

      await expectLater(
        service.decryptFile(
          encryptedPath: encryptedPath,
          plaintextPath: plaintextPath,
          key: key,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('wrong key fails decryption', () async {
      final source = writeSource('wrongkey.bin', [1, 2, 3, 4, 5]);
      final encryptedPath = '${tempDir.path}/wrongkey.enc';
      final plaintextPath = '${tempDir.path}/wrongkey.out';
      await service.encryptFile(
        sourcePath: source.path,
        encryptedPath: encryptedPath,
        key: key,
      );
      final wrongKey = await encryption.deriveKey('wrong-password', [
        for (var i = 0; i < 32; i++) i,
      ]);

      await expectLater(
        service.decryptFile(
          encryptedPath: encryptedPath,
          plaintextPath: plaintextPath,
          key: wrongKey,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('decrypts a file larger than one chunk (chunk boundary)', () async {
      final chunk = AppConstants.fileChunkSize;
      final bytes = List<int>.generate(chunk + 12345, (i) => (i * 13) % 251);
      final source = writeSource('big.bin', bytes);
      final encryptedPath = '${tempDir.path}/big.enc';
      final plaintextPath = '${tempDir.path}/big.out';

      await service.encryptFile(
        sourcePath: source.path,
        encryptedPath: encryptedPath,
        key: key,
      );
      final hash = await service.decryptFile(
        encryptedPath: encryptedPath,
        plaintextPath: plaintextPath,
        key: key,
      );

      expect(hash, equals(sha256Hex(bytes)));
      expect(File(plaintextPath).readAsBytesSync(), equals(bytes));
    });
  });
}
