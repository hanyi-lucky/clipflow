import '../models/sync_operation.dart';

abstract interface class SyncTransport {
  Future<void> send(SyncOperation operation);

  Future<Map<String, dynamic>?> fetchCurrentClipboardWithDeletions();

  Future<void> close();
}
