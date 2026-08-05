import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' hide Digest;
import '../core/constants.dart';
import '../core/exceptions.dart';

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

String _hashFileInBackground(String path) {
  try {
    final digestSink = _DigestSink();
    final sink = sha256.startChunkedConversion(digestSink);
    final file = File(path).openSync();
    try {
      final buffer = Uint8List(AppConstants.fileChunkSize);
      while (true) {
        final count = file.readIntoSync(buffer, 0, buffer.length);
        if (count <= 0) break;
        sink.add(Uint8List.sublistView(buffer, 0, count));
      }
    } finally {
      file.closeSync();
    }
    sink.close();
    return digestSink.digest!.toString();
  } catch (e) {
    throw EncryptionException('File hash failed: $e');
  }
}

String _encryptFileInBackground(Map<String, dynamic> params) {
  try {
    final key = Uint8List.fromList(params['key'] as List<int>);
    final sourcePath = params['sourcePath'] as String;
    final encryptedPath = params['encryptedPath'] as String;
    final iv = Uint8List(AppConstants.ivLength);
    final random = Random.secure();
    for (var i = 0; i < iv.length; i++) {
      iv[i] = random.nextInt(256);
    }

    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      true,
      AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
    );

    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    final source = File(sourcePath).openSync();
    final output = File(encryptedPath).openSync(mode: FileMode.write);
    try {
      output.writeFromSync([(iv.length >> 8) & 0xFF, iv.length & 0xFF]);
      output.writeFromSync(iv);

      final buffer = Uint8List(AppConstants.fileChunkSize);
      final outBuffer = Uint8List(buffer.length + 16);
      while (true) {
        final count = source.readIntoSync(buffer, 0, buffer.length);
        if (count <= 0) break;
        hashSink.add(Uint8List.sublistView(buffer, 0, count));
        final written = cipher.processBytes(
          buffer,
          0,
          count,
          outBuffer,
          0,
        );
        if (written > 0) {
          output.writeFromSync(
            Uint8List.sublistView(outBuffer, 0, written),
          );
        }
      }
      final tagLength = cipher.doFinal(outBuffer, 0);
      output.writeFromSync(Uint8List.sublistView(outBuffer, 0, tagLength));
    } finally {
      source.closeSync();
      output.closeSync();
    }
    hashSink.close();
    return digestSink.digest!.toString();
  } catch (e) {
    throw EncryptionException('File encryption failed: $e');
  }
}

String _decryptFileInBackground(Map<String, dynamic> params) {
  try {
    final key = Uint8List.fromList(params['key'] as List<int>);
    final encryptedPath = params['encryptedPath'] as String;
    final plaintextPath = params['plaintextPath'] as String;

    final source = File(encryptedPath).openSync();
    final header = Uint8List(2);
    source.readIntoSync(header, 0, 2);
    final ivLength = (header[0] << 8) | header[1];
    final iv = Uint8List(ivLength);
    source.readIntoSync(iv, 0, ivLength);

    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      false,
      AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
    );

    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    final output = File(plaintextPath).openSync(mode: FileMode.write);
    try {
      final buffer = Uint8List(AppConstants.fileChunkSize);
      final outBuffer = Uint8List(buffer.length);
      while (true) {
        final count = source.readIntoSync(buffer, 0, buffer.length);
        if (count <= 0) break;
        final written = cipher.processBytes(
          buffer,
          0,
          count,
          outBuffer,
          0,
        );
        if (written > 0) {
          output.writeFromSync(
            Uint8List.sublistView(outBuffer, 0, written),
          );
          hashSink.add(Uint8List.sublistView(outBuffer, 0, written));
        }
      }
      final finalLength = cipher.doFinal(outBuffer, 0);
      if (finalLength > 0) {
        output.writeFromSync(Uint8List.sublistView(outBuffer, 0, finalLength));
        hashSink.add(Uint8List.sublistView(outBuffer, 0, finalLength));
      }
    } finally {
      source.closeSync();
      output.closeSync();
    }
    hashSink.close();
    return digestSink.digest!.toString();
  } catch (e) {
    throw EncryptionException('File decryption failed: $e');
  }
}

/// 有界内存流式文件哈希/加解密（isolate 中执行）。
///
/// 加密产物与现有 `EncryptedData` 完全同构：
/// `[2字节IV长度][IV][密文+tag]`，内存峰值约一个 chunk。
class FileProcessingService {
  Future<String> hashFile(String path) {
    return compute(_hashFileInBackground, path);
  }

  Future<String> encryptFile({
    required String sourcePath,
    required String encryptedPath,
    required Uint8List key,
  }) {
    return compute(_encryptFileInBackground, {
      'sourcePath': sourcePath,
      'encryptedPath': encryptedPath,
      'key': key,
    });
  }

  Future<String> decryptFile({
    required String encryptedPath,
    required String plaintextPath,
    required Uint8List key,
  }) {
    return compute(_decryptFileInBackground, {
      'encryptedPath': encryptedPath,
      'plaintextPath': plaintextPath,
      'key': key,
    });
  }
}
