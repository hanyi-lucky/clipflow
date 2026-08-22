import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../models/device.dart';
import '../services/cloudbase_service.dart';
import '../services/oss_direct_client.dart';

class CloudRepository {
  final CloudBaseService _cloud;
  final OssDirectClient _oss;

  CloudRepository(this._cloud, {OssDirectClient? ossDirectClient})
      : _oss = ossDirectClient ?? OssDirectClient();

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

  // --- LAN 握手票据（Phase 2.1，仅 additive）---

  /// 获取 LAN 握手短时票据（HMAC 短时票据）。
  Future<Map<String, dynamic>> getLanTicket({required String deviceId}) async {
    final result = await _cloud.fetchLanTicket(deviceId: deviceId);
    return result['data'] as Map<String, dynamic>? ?? const <String, dynamic>{};
  }

  /// 校验 LAN 握手票据（返回 `data`：userId/deviceId/expiresAtMs）。
  Future<Map<String, dynamic>> verifyLanTicket({required String ticket}) async {
    final result = await _cloud.verifyLanTicket(ticket: ticket);
    return result['data'] as Map<String, dynamic>? ?? const <String, dynamic>{};
  }

  // --- 垃圾箱 ---

  /// 获取剪切板内容（含 deletedIds，用于同步删除）
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    return await _cloud.getClipboardWithDeletedIds();
  }

  // --- 同步操作（durable cursor + tombstone，Phase 5.2）---

  /// 拉取一页增量同步操作（旧服务器返回 null → legacy 回退）。
  Future<Map<String, dynamic>?> getSyncChanges({required int after, int? limit}) async {
    return await _cloud.fetchSyncChanges(after: after, limit: limit);
  }

  /// 提交删除/恢复操作，返回服务端响应 `data`（seq/duplicate/ignored/row）。
  Future<Map<String, dynamic>> commitSyncOperation({
    required String operationId,
    required String kind,
    required String entryId,
    Map<String, dynamic>? payload,
  }) async {
    final result = await _cloud.commitSyncOperation(
      operationId: operationId,
      kind: kind,
      entryId: entryId,
      payload: payload,
    );
    return result['data'] as Map<String, dynamic>? ?? const <String, dynamic>{};
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
  ///
  /// 优先 OSS 直传（Phase 5.3）：presign → 直传 PUT → confirm；任一步失败
  /// （presign 503 / OSS 不可达 / PUT 失败 / confirm HEAD 失败）回退服务器中转 relay。
  /// 对外签名不变，调用方（SyncCoordinator/outbox/LAN/fake 测试）零改动。
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

    // OSS 直传（forceFileRelay 调试开关强制走 relay）
    if (!AppConstants.forceFileRelay) {
      try {
        final presign = await _cloud.presignUpload(headers: headers);
        final presignData = presign['data'] as Map<String, dynamic>? ?? const {};
        final uploadUrl = presignData['uploadUrl'] as String?;
        final fileKey = presignData['fileKey'] as String?;
        if (uploadUrl == null || fileKey == null) {
          throw Exception('Invalid presign upload response');
        }
        final direct = await _oss.putStream(
          Uri.parse(uploadUrl),
          encryptedPath,
          timeout: AppConstants.ossDirectTimeout,
        );
        if (direct.statusCode < 200 || direct.statusCode >= 300) {
          await direct.stream.drain<void>();
          throw Exception('OSS direct upload failed: ${direct.statusCode}');
        }
        await direct.stream.drain<void>();
        // confirm 需要 JSON body（fileKey/historyId），去掉 octet-stream Content-Type
        final metadataHeaders = Map<String, String>.from(headers)
          ..remove('Content-Type');
        await _cloud.confirmPresignUpload(
          historyId: historyId,
          fileKey: fileKey,
          headers: metadataHeaders,
        );
        return; // 直传成功，全程不经 ECS 中转
      } catch (_) {
        // 任何异常回退 relay（保正确性优先：relay 自带流式计数校验）
      }
    }

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

  /// 下载文件密文：OSS 直下优先、relay 兜底（对外签名不变，返回 StreamedResponse）。
  Future<http.StreamedResponse> downloadFile(String entryId) async {
    if (!AppConstants.forceFileRelay) {
      try {
        final info = await _cloud.presignDownload(entryId);
        final data = info['data'] as Map<String, dynamic>? ?? const {};
        if (data['storage'] == 'oss') {
          final downloadUrl = data['downloadUrl'] as String?;
          if (downloadUrl != null) {
            final direct = await _oss.getStream(
              Uri.parse(downloadUrl),
              timeout: AppConstants.ossDirectTimeout,
            );
            if (direct.statusCode == 200) {
              return direct; // 直下成功
            }
            await direct.stream.drain<void>();
          }
        }
        // storage=='disk' 或直下失败 → 走 relay
      } catch (_) {
        // 直下异常（presign 失败/网络错误）→ 回退 relay
      }
    }
    return _cloud.downloadFileStream('/file/$entryId/content');
  }
}
