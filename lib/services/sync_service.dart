import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../repositories/cloud_repository.dart';
import '../services/encryption_service.dart';

class SyncService {
  final CloudRepository _repo;
  final EncryptionService _encryption;
  final String _deviceId;
  final String _deviceName;
  final String _devicePlatform;
  final Uint8List _key;

  String _lastUploadedHash = '';
  DateTime? _lastReceivedTimestamp;

  String get lastUploadedHash => _lastUploadedHash;

  /// 标记内容为"已同步"，防止剪切板监听器重复上传刚下载的内容
  void markAsDownloaded(String content) {
    _lastUploadedHash = sha256.convert(utf8.encode(content)).toString();
  }

  SyncService({
    required CloudRepository repo,
    required EncryptionService encryption,
    required String deviceId,
    required String deviceName,
    required String devicePlatform,
    required Uint8List key,
  })  : _repo = repo,
        _encryption = encryption,
        _deviceId = deviceId,
        _deviceName = deviceName,
        _devicePlatform = devicePlatform,
        _key = key;

  /// 上传内容到服务器。返回 true 表示成功上传，false 表示跳过（重复内容）
  Future<bool> uploadContent(String content) async {
    final hash = sha256.convert(utf8.encode(content)).toString();
    if (hash == _lastUploadedHash) return false;

    _lastUploadedHash = hash;

    final encrypted = await _encryption.encrypt(content, _key);
    final encryptedBase64 = encrypted.toBase64();
    final now = DateTime.now();

    final data = {
      'content': encryptedBase64,
      'hash': hash,
      'sourceDevice': _deviceId,
      'sourceDeviceName': _deviceName,
      'sourcePlatform': _devicePlatform,
      'timestamp': now.millisecondsSinceEpoch,
      'type': 'text',
    };

    await _repo.setCurrentClipboard(data);

    await _repo.addHistoryEntry({
      ...data,
      'pinned': false,
    });
    return true;
  }

  Future<String?> downloadLatestContent() async {
    final current = await _repo.getCurrentClipboard();
    if (current == null) return null;

    final sourceDevice = current['source_device'] as String?;
    if (sourceDevice == _deviceId) return null;

    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      current['timestamp'] as int,
    );

    if (_lastReceivedTimestamp != null &&
        !timestamp.isAfter(_lastReceivedTimestamp!)) {
      return null;
    }

    _lastReceivedTimestamp = timestamp;

    final encryptedBase64 = current['content'] as String;
    try {
      final encryptedData = EncryptedData.fromBase64(encryptedBase64);
      final result = await _encryption.decrypt(encryptedData, _key);
      return result;
    } catch (e) {
      debugPrint('[SYNC-DL] DECRYPT ERROR: $e');
      return null;
    }
  }

  Future<String?> getSalt() => _repo.getSalt();

  Future<void> saveSaltHex(List<int> salt) async {
    await _repo.setSalt(salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
  }

  List<int>? parseSaltHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
}
