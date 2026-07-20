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
}
