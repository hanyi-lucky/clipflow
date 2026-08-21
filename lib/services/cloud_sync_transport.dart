import '../models/sync_operation.dart';
import '../repositories/cloud_repository.dart';
import '../repositories/local_file_store.dart';
import 'sync_transport.dart';

class CloudSyncTransport implements SyncTransport {
  final CloudRepository _repository;
  final LocalFileStore _fileStore;

  CloudSyncTransport({
    required CloudRepository repository,
    required LocalFileStore fileStore,
  })  : _repository = repository,
        _fileStore = fileStore;

  @override
  Future<Map<String, dynamic>?> send(SyncOperation operation) async {
    switch (operation.kind) {
      case SyncOperationKind.text:
      case SyncOperationKind.image:
        final payload = Map<String, dynamic>.from(operation.payload);
        await _repository.setCurrentClipboard(payload);
        await _repository.addHistoryEntry({...payload, 'pinned': false});
        return null;
      case SyncOperationKind.file:
        final artifactId = operation.artifactId ?? operation.operationId;
        final encryptedPath = await _fileStore.loadEncryptedPath(artifactId);
        if (encryptedPath == null) {
          throw StateError('Missing encrypted artifact: $artifactId');
        }
        final payload = operation.payload;
        await _repository.uploadFile(
          encryptedPath: encryptedPath,
          historyId: operation.operationId,
          plaintextHash: payload['hash'] as String,
          fileName: payload['fileName'] as String,
          fileSize: payload['fileSize'] as int,
          mimeType: payload['mimeType'] as String,
          marker: payload['marker'] as String,
          sourceDevice: payload['sourceDevice'] as String,
          sourceDeviceName: payload['sourceDeviceName'] as String,
          sourcePlatform: payload['sourcePlatform'] as String,
          timestamp: payload['timestamp'] as int,
        );
        return null;
      case SyncOperationKind.delete:
      case SyncOperationKind.restore:
        final payload = operation.payload;
        return await _repository.commitSyncOperation(
          operationId: operation.operationId,
          kind: operation.kind.name,
          entryId: payload['entryId'] as String? ?? '',
          payload: payload,
        );
    }
  }

  @override
  Future<Map<String, dynamic>?> fetchSyncChanges({required int after}) {
    return _repository.getSyncChanges(after: after);
  }

  @override
  Future<Map<String, dynamic>?> fetchCurrentClipboardWithDeletions() {
    return _repository.getCurrentClipboardWithDeletions();
  }

  @override
  Future<void> close() async {}
}
