import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device.dart';
import '../services/cloudbase_service.dart';

class CloudRepository {
  final CloudBaseService _cloud;

  CloudRepository(this._cloud);

  // --- 设备管理 ---

  Future<void> registerDevice(Device device) async {
    await _cloud.setDocument('devices', device.id, device.toMap());
  }

  Future<void> updateDeviceLastSeen(String deviceId) async {
    await _cloud.updateDocument('devices', deviceId, {
      'lastSeen': DateTime.now().toIso8601String(),
    });
  }

  Future<void> updateDeviceName(String deviceId, String name) async {
    await _cloud.updateDocument('devices', deviceId, {'name': name});
  }

  Future<List<Device>> getDevices() async {
    final docs = await _cloud.queryDocuments('devices');
    return docs.map((d) => Device.fromMap(d)).toList();
  }

  Future<void> removeDevice(String deviceId) async {
    await _cloud.deleteDocument('devices', deviceId);
  }

  // --- 剪切板当前内容 ---

  Future<Map<String, dynamic>?> getCurrentClipboard() async {
    return await _cloud.getDocument('clipboard', 'current');
  }

  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {
    await _cloud.setDocument('clipboard', 'current', data);
  }

  // --- 加密盐值 ---

  Future<String?> getSalt() async {
    final doc = await _cloud.getDocument('clipboard', 'salt');
    if (doc == null) return null;
    return doc['value'] as String?;
  }

  Future<void> setSalt(String salt) async {
    await _cloud.setDocument('clipboard', 'salt', {'value': salt});
  }

  // --- 剪切板历史 ---

  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    await _cloud.addDocument('history', data);
  }

  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async {
    return await _cloud.queryDocuments(
      'history',
      orderBy: 'timestamp',
      descending: true,
      limit: limit,
    );
  }

  Future<void> deleteHistoryEntry(String entryId) async {
    await _cloud.deleteDocument('history', entryId);
  }

  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {
    await _cloud.updateDocument('history', entryId, data);
  }

  // --- 垃圾箱 ---

  /// 获取剪切板内容（含 deletedIds，用于同步删除）
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    return await _cloud.getClipboardWithDeletedIds();
  }

  /// 获取垃圾箱条目
  Future<List<Map<String, dynamic>>> getTrashEntries() async {
    return await _cloud.queryDocuments('trash');
  }

  /// 恢复已删除条目
  Future<void> restoreHistoryEntry(String entryId) async {
    await _cloud.restoreHistoryEntry(entryId);
  }

  /// 倾倒垃圾桶：委托 cloud service 执行并返回删除数量。
  Future<int> emptyTrash() => _cloud.emptyTrash();

  /// 获取历史记录完整内容（图片全图密文）
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async {
    return await _cloud.getHistoryEntryContent(entryId);
  }

  // --- 文件同步 ---

  /// 流式上传文件密文，元数据走 `x-clipflow-*` headers（base64url）。
  Future<void> uploadFile({
    required String encryptedPath,
    required String historyId,
    required String plaintextHash,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String marker,
    required String sourceDevice,
    required String sourceDeviceName,
    required String sourcePlatform,
    required int timestamp,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/octet-stream',
      'x-clipflow-history-id': historyId,
      'x-clipflow-hash': plaintextHash,
      'x-clipflow-file-name': base64UrlEncode(utf8.encode(fileName)),
      'x-clipflow-file-size': '$fileSize',
      'x-clipflow-mime-type': base64UrlEncode(utf8.encode(mimeType)),
      'x-clipflow-source-device': base64UrlEncode(utf8.encode(sourceDevice)),
      'x-clipflow-source-device-name':
          base64UrlEncode(utf8.encode(sourceDeviceName)),
      'x-clipflow-source-platform':
          base64UrlEncode(utf8.encode(sourcePlatform)),
      'x-clipflow-timestamp': '$timestamp',
      'x-clipflow-marker': base64UrlEncode(utf8.encode(marker)),
    };
    final response = await _cloud.uploadFileStream(
      encryptedPath,
      headers: headers,
    );
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('HTTP ${response.statusCode}: $body');
    }
    await response.stream.drain<void>();
  }

  Future<http.StreamedResponse> downloadFile(String entryId) {
    return _cloud.downloadFileStream('/file/$entryId/content');
  }
}
