import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import '../core/constants.dart';
import '../core/exceptions.dart';

class EncryptedData {
  final Uint8List ciphertext;
  final Uint8List iv;

  EncryptedData({required this.ciphertext, required this.iv});

  /// 序列化为单载荷字节：`[2字节IV长度][IV][密文+tag]`。
  Uint8List toBytes() {
    final bytes = Uint8List(2 + iv.length + ciphertext.length);
    final ivLen = iv.length;
    bytes[0] = (ivLen >> 8) & 0xFF;
    bytes[1] = ivLen & 0xFF;
    bytes.setAll(2, iv);
    bytes.setAll(2 + ivLen, ciphertext);
    return bytes;
  }

  String toBase64() => base64.encode(toBytes());

  factory EncryptedData.fromBytes(Uint8List bytes) {
    final ivLen = (bytes[0] << 8) | bytes[1];
    final iv = Uint8List.fromList(bytes.sublist(2, 2 + ivLen));
    final ciphertext = Uint8List.fromList(bytes.sublist(2 + ivLen));
    return EncryptedData(ciphertext: ciphertext, iv: iv);
  }

  factory EncryptedData.fromBase64(String encoded) {
    return EncryptedData.fromBytes(Uint8List.fromList(base64.decode(encoded)));
  }
}

/// PBKDF2 密钥派生（在 isolate 中执行）
/// 必须是顶层函数，compute() 要求闭包可序列化
Uint8List _deriveKeyInBackground(Map<String, dynamic> params) {
  final password = params['password'] as String;
  final salt = params['salt'] as List<int>;
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
  derivator.init(Pbkdf2Parameters(
    Uint8List.fromList(salt),
    AppConstants.pbkdf2Iterations,
    AppConstants.aesKeyLength,
  ));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

/// 二进制解密（在 isolate 中执行），供查看器大图解密
Uint8List _decryptBytesInBackground(Map<String, dynamic> params) {
  final key = Uint8List.fromList(params['key'] as List<int>);
  final data = EncryptedData.fromBase64(params['base64'] as String);
  final cipher = GCMBlockCipher(AESEngine());
  cipher.init(
    false,
    AEADParameters(KeyParameter(key), 128, data.iv, Uint8List(0)),
  );
  return cipher.process(data.ciphertext);
}

class EncryptionService {
  Future<Uint8List> deriveKey(String password, List<int> salt) async {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    derivator.init(Pbkdf2Parameters(
      Uint8List.fromList(salt),
      AppConstants.pbkdf2Iterations,
      AppConstants.aesKeyLength,
    ));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// 使用 compute isolate 派生密钥，不阻塞 UI 线程
  Future<Uint8List> deriveKeyIsolate(String password, List<int> salt) async {
    return compute(_deriveKeyInBackground, {
      'password': password,
      'salt': salt,
    });
  }

  Future<EncryptedData> encrypt(String plaintext, Uint8List key) async {
    try {
      final iv = generateIv();
      final cipher = _createCipher(true, key, iv);
      final inputBytes = Uint8List.fromList(utf8.encode(plaintext));
      final ciphertext = cipher.process(inputBytes);
      return EncryptedData(ciphertext: ciphertext, iv: iv);
    } catch (e) {
      throw EncryptionException('Encryption failed: $e');
    }
  }

  /// 加密二进制数据（图片全图/缩略图），打包格式与文本一致
  Future<EncryptedData> encryptBytes(Uint8List plaintext, Uint8List key) async {
    try {
      final iv = generateIv();
      final cipher = _createCipher(true, key, iv);
      final ciphertext = cipher.process(plaintext);
      return EncryptedData(ciphertext: ciphertext, iv: iv);
    } catch (e) {
      throw EncryptionException('Encryption failed: $e');
    }
  }

  /// 解密二进制数据，返回原始字节
  Future<Uint8List> decryptBytes(EncryptedData data, Uint8List key) async {
    try {
      final cipher = _createCipher(false, key, data.iv);
      return cipher.process(data.ciphertext);
    } catch (e) {
      throw EncryptionException('Decryption failed. Check your master password.');
    }
  }

  /// 使用 compute isolate 解密二进制大图，不阻塞 UI 线程
  Future<Uint8List> decryptBytesIsolate(
    Uint8List key,
    String encryptedBase64,
  ) async {
    return compute(_decryptBytesInBackground, {
      'key': key,
      'base64': encryptedBase64,
    });
  }

  Future<String> decrypt(EncryptedData data, Uint8List key) async {
    try {
      final cipher = _createCipher(false, key, data.iv);
      final plaintextBytes = cipher.process(data.ciphertext);
      return utf8.decode(plaintextBytes);
    } catch (e) {
      throw EncryptionException('Decryption failed. Check your master password.');
    }
  }

  List<int> generateSalt() {
    return _generateRandomBytes(32).toList();
  }

  Uint8List generateIv() {
    return _generateRandomBytes(AppConstants.ivLength);
  }

  GCMBlockCipher _createCipher(bool forEncryption, Uint8List key, Uint8List iv) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      forEncryption,
      AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
    );
    return cipher;
  }

  Uint8List _generateRandomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}
