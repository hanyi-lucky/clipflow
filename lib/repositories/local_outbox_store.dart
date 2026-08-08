import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/sync_operation.dart';
import 'outbox_store.dart';

class LocalOutboxStore implements OutboxStore {
  final String? _overrideDirectoryPath;

  LocalOutboxStore({String? directoryPath}) : _overrideDirectoryPath = directoryPath;

  Future<String> _basePath() async {
    return _overrideDirectoryPath ??
        (await getApplicationSupportDirectory()).path;
  }

  Future<Directory> _userDirectory(String userId, {bool create = true}) async {
    final base = await _basePath();
    final dir = Directory('${base.pathSafe}/clipflow_outbox/$userId');
    if (create && !dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  @override
  Future<List<SyncOperation>> loadActive(String userId) async {
    final dir = await _userDirectory(userId, create: false);
    if (!dir.existsSync()) return [];

    final operations = <SyncOperation>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) {
          throw const FormatException('manifest must be a JSON object');
        }
        final operation = SyncOperation.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (operation.userId != userId || !operation.isActive) continue;
        if (operation.state == SyncOperationState.sending) {
          final restored = operation.copyWith(
            state: SyncOperationState.pending,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          await _write(restored);
          operations.add(restored);
        } else {
          operations.add(operation);
        }
      } catch (_) {
        try {
          await entity.delete();
        } catch (_) {
          // A corrupt record must not prevent other records from loading.
        }
      }
    }

    operations.sort((a, b) {
      final created = a.createdAtMs.compareTo(b.createdAtMs);
      return created != 0 ? created : a.operationId.compareTo(b.operationId);
    });
    return operations;
  }

  @override
  Future<void> put(SyncOperation operation) => _write(operation);

  @override
  Future<void> update(SyncOperation operation) => _write(operation);

  @override
  Future<SyncOperation?> findActiveByDedupeKey(
    String userId,
    SyncOperationKind kind,
    String dedupeKey,
  ) async {
    final operations = await loadActive(userId);
    for (final operation in operations) {
      if (operation.kind == kind && operation.dedupeKey == dedupeKey) {
        return operation;
      }
    }
    return null;
  }

  @override
  Future<void> remove(String userId, String operationId) async {
    final dir = await _userDirectory(userId, create: false);
    final file = File('${dir.path}/$operationId.json');
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<List<String>> clearUser(String userId) async {
    final dir = await _userDirectory(userId, create: false);
    if (!dir.existsSync()) return [];

    final artifactIds = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final decoded = jsonDecode(await entity.readAsString());
          if (decoded is Map) {
            final operation = SyncOperation.fromJson(
              Map<String, dynamic>.from(decoded),
            );
            if (operation.artifactId != null) artifactIds.add(operation.artifactId!);
          }
        } catch (_) {
          // Corrupt entries are deleted with the rest of this account.
        }
      }
    }
    await dir.delete(recursive: true);
    return artifactIds;
  }

  Future<void> _write(SyncOperation operation) async {
    final dir = await _userDirectory(operation.userId);
    final target = File('${dir.path}/${operation.operationId}.json');
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(operation.toJson()), flush: true);
    if (target.existsSync()) await target.delete();
    await temp.rename(target.path);
  }
}

extension on String {
  String get pathSafe => this;
}
