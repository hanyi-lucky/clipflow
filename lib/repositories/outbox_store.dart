import '../models/sync_operation.dart';

abstract interface class OutboxStore {
  Future<List<SyncOperation>> loadActive(String userId);

  Future<void> put(SyncOperation operation);

  Future<void> update(SyncOperation operation);

  Future<SyncOperation?> findActiveByDedupeKey(
    String userId,
    SyncOperationKind kind,
    String dedupeKey,
  );

  Future<void> remove(String userId, String operationId);

  Future<List<String>> clearUser(String userId);
}
