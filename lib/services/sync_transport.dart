import '../models/sync_operation.dart';
import '../services/sync_service.dart';

abstract interface class SyncTransport {
  Future<void> send(SyncOperation operation);

  Future<Map<String, dynamic>?> fetchCurrentClipboardWithDeletions();

  Future<void> close();
}
