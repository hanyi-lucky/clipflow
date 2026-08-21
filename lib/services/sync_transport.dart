import '../models/sync_operation.dart';

abstract interface class SyncTransport {
  /// 发送操作。text/image/file 返回 null（行为不变）；
  /// delete/restore 返回 `/api/sync/commit` 响应 `data`（restore 的 LAN row 来源）。
  Future<Map<String, dynamic>?> send(SyncOperation operation);

  /// 拉取一页增量同步操作（durable cursor）。旧服务器（404）返回 null → legacy 回退。
  Future<Map<String, dynamic>?> fetchSyncChanges({required int after});

  Future<Map<String, dynamic>?> fetchCurrentClipboardWithDeletions();

  Future<void> close();
}
