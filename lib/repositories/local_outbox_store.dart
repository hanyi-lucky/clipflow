import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/sync_operation.dart';
import 'outbox_store.dart';

typedef OutboxRename = Future<void> Function(File source, String target);

class _OutboxRecord {
  final File file;
  final SyncOperation operation;

  const _OutboxRecord(this.file, this.operation);
}

class _CorruptManifest implements Exception {
  const _CorruptManifest();
}

class LocalOutboxStore implements OutboxStore {
  final String? _overrideDirectoryPath;
  final OutboxRename _rename;
  int _tempSequence = 0;

  LocalOutboxStore({String? directoryPath, OutboxRename? rename})
      : _overrideDirectoryPath = directoryPath,
        _rename = rename ??
            ((source, target) async {
              await source.rename(target);
            });

  Future<String> _basePath() async {
    return _overrideDirectoryPath ??
        (await getApplicationSupportDirectory()).path;
  }

  Future<Directory> _userDirectory(String userId, {bool create = true}) async {
    final base = await _basePath();
    final dir = Directory('$base/clipflow_outbox/$userId');
    if (create && !dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String canonicalName(String operationId) {
    final digest = sha256.convert(utf8.encode(operationId)).toString();
    return 'v2-$digest.json';
  }

  @override
  Future<List<SyncOperation>> loadActive(String userId) async {
    final dir = await _userDirectory(userId, create: false);
    if (!dir.existsSync()) return [];

    final grouped = <String, List<_OutboxRecord>>{};
    await for (final entity in dir.list()) {
      if (entity is! File || !_isOutboxCandidate(entity)) continue;
      final record = await _readRecord(entity, userId);
      if (record == null || !record.operation.isActive) continue;
      grouped
          .putIfAbsent(record.operation.operationId, () => <_OutboxRecord>[])
          .add(record);
    }

    final operations = <SyncOperation>[];
    for (final group in grouped.values) {
      final operation = await _selectAndMigrate(group);
      if (operation != null) operations.add(operation);
    }

    operations.sort((a, b) {
      final created = a.createdAtMs.compareTo(b.createdAtMs);
      return created != 0 ? created : a.operationId.compareTo(b.operationId);
    });
    return operations;
  }

  Future<_OutboxRecord?> _readRecord(File file, String userId) async {
    try {
      final operation = await _readManifest(file);
      if (operation.userId != userId) return null;
      return _OutboxRecord(file, operation);
    } on _CorruptManifest {
      // JSON/schema damage is not recoverable. Delete only that artifact.
      await _deleteQuietly(file);
      return null;
    } on FileSystemException {
      // An I/O failure may be transient. Never delete the source.
      return null;
    }
  }

  Future<SyncOperation> _readManifest(File file) async {
    final raw = await file.readAsString();
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const _CorruptManifest();
    }
    if (decoded is! Map) {
      throw const _CorruptManifest();
    }
    try {
      return SyncOperation.fromJson(Map<String, dynamic>.from(decoded));
    } on SyncOperationFormatException {
      throw const _CorruptManifest();
    } catch (_) {
      throw const _CorruptManifest();
    }
  }

  Future<SyncOperation?> _selectAndMigrate(List<_OutboxRecord> records) async {
    if (records.isEmpty) return null;

    final operationId = records.first.operation.operationId;
    final dir = records.first.file.parent;
    final target = File('${dir.path}/${canonicalName(operationId)}');
    final canonical = records
        .where((record) => _samePath(record.file, target))
        .toList();
    final legacy = records
        .where((record) =>
            !_isTemp(record.file) && !_samePath(record.file, target))
        .toList()
      ..sort((a, b) =>
          b.operation.updatedAtMs.compareTo(a.operation.updatedAtMs));
    final temps = records.where((record) => _isTemp(record.file)).toList()
      ..sort((a, b) =>
          b.operation.updatedAtMs.compareTo(a.operation.updatedAtMs));

    if (canonical.isNotEmpty) {
      final current = canonical.first;
      var operation = current.operation;
      if (operation.state == SyncOperationState.sending) {
        operation = operation.copyWith(
          state: SyncOperationState.pending,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        try {
          await _writeManifest(operation, target);
          operation = await _readManifest(target);
        } on FileSystemException {
          operation = current.operation;
        } on _CorruptManifest {
          operation = current.operation;
        }
      }
      await _cleanupSecondary(
        records,
        target,
        canonical.first.operation.operationId,
      );
      return operation;
    }

    final occupant = await _canonicalOccupant(dir, operationId);
    if (occupant != null) {
      // A different valid opId owns this hash path. Keep this group's source
      // and return it without overwriting the occupant.
      final source = legacy.isNotEmpty ? legacy.first : temps.first;
      return source.operation;
    }

    final chosen = legacy.isNotEmpty ? legacy.first : temps.first;
    final operation = chosen.operation.state == SyncOperationState.sending
        ? chosen.operation.copyWith(
            state: SyncOperationState.pending,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          )
        : chosen.operation;

    try {
      await _promote(chosen, operation, target);
      final readBack = await _readManifest(target);
      if (readBack.operationId != operationId) return operation;
      await _cleanupSecondary(records, target, operationId);
      return readBack;
    } on FileSystemException {
      // The source remains recoverable for the next load.
      return operation;
    } on _CorruptManifest {
      return operation;
    }
  }

  Future<File?> _canonicalOccupant(Directory dir, String operationId) async {
    final target = File('${dir.path}/${canonicalName(operationId)}');
    if (!target.existsSync()) return null;
    try {
      final existing = await _readManifest(target);
      return existing.operationId == operationId ? null : target;
    } on _CorruptManifest {
      return null;
    } on FileSystemException {
      return target;
    }
  }

  Future<void> _promote(
    _OutboxRecord source,
    SyncOperation operation,
    File target,
  ) async {
    if (target.existsSync()) {
      try {
        final existing = await _readManifest(target);
        if (existing.operationId == operation.operationId) return;
        throw const FileSystemException('canonical hash path occupied');
      } on _CorruptManifest {
        // JSON/schema damage may be quarantined; I/O errors preserve both.
        final corrupt = File(
          '${target.path}.corrupt-${pid}-${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await _rename(target, corrupt.path);
      }
    }

    await _writeManifest(operation, target);
    final readBack = await _readManifest(target);
    if (readBack.operationId != operation.operationId) {
      throw const FileSystemException('canonical readback identity mismatch');
    }
  }

  Future<void> _writeManifest(SyncOperation operation, File target) async {
    final dir = target.parent;
    if (!dir.existsSync()) await dir.create(recursive: true);
    final temp = File(
      '${target.path}.${pid}-${DateTime.now().microsecondsSinceEpoch}-${_tempSequence++}.tmp',
    );
    try {
      await temp.writeAsString(jsonEncode(operation.toJson()), flush: true);
      if (target.existsSync()) {
        try {
          final existing = await _readManifest(target);
          if (existing.operationId != operation.operationId) {
            throw const FileSystemException('canonical hash path occupied');
          }
        } on _CorruptManifest {
          final corrupt = File(
            '${target.path}.corrupt-${pid}-${DateTime.now().microsecondsSinceEpoch}.tmp',
          );
          await _rename(target, corrupt.path);
        }
      }
      await _rename(temp, target.path);
    } catch (_) {
      await _deleteQuietly(temp);
      rethrow;
    }
  }

  Future<void> _cleanupSecondary(
    List<_OutboxRecord> records,
    File canonical,
    String operationId,
  ) async {
    bool canonicalBelongs = false;
    if (canonical.existsSync()) {
      try {
        canonicalBelongs =
            (await _readManifest(canonical)).operationId == operationId;
      } catch (_) {
        canonicalBelongs = false;
      }
    }
    for (final record in records) {
      if (_samePath(record.file, canonical)) continue;
      if (record.operation.operationId != operationId) continue;
      if (_isTemp(record.file) || canonicalBelongs) {
        await _deleteQuietly(record.file);
      }
    }
  }

  @override
  Future<void> put(SyncOperation operation) async {
    final dir = await _userDirectory(operation.userId);
    final target = File('${dir.path}/${canonicalName(operation.operationId)}');
    await _writeManifest(operation, target);
  }

  @override
  Future<void> update(SyncOperation operation) => put(operation);

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
    if (!dir.existsSync()) return;

    final matches = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !_isOutboxCandidate(entity)) continue;
      try {
        final operation = await _readManifest(entity);
        if (operation.operationId == operationId) matches.add(entity);
      } catch (_) {
        // An unreadable or foreign manifest is not proof of this operation.
      }
    }

    final exactCanonicalName = canonicalName(operationId);
    final secondary = matches
        .where((file) => file.uri.pathSegments.last != exactCanonicalName)
        .toList();
    final canonical = matches
        .where((file) => file.uri.pathSegments.last == exactCanonicalName)
        .toList();

    // The canonical manifest is the last authoritative copy. Any failure on a
    // secondary artifact propagates before canonical deletion is attempted.
    for (final file in secondary) {
      await _deleteRequired(file);
    }
    for (final file in canonical) {
      await _deleteRequired(file);
    }
  }

  @override
  Future<List<String>> clearUser(String userId) async {
    final dir = await _userDirectory(userId, create: false);
    if (!dir.existsSync()) return [];

    final artifactIds = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! File || !_isOutboxCandidate(entity)) continue;
      try {
        final operation = await _readManifest(entity);
        if (operation.userId == userId && operation.artifactId != null) {
          artifactIds.add(operation.artifactId!);
        }
      } catch (_) {
        // Corrupt entries are removed with the account directory.
      }
    }
    await dir.delete(recursive: true);
    return artifactIds.toList();
  }

  bool _isOutboxCandidate(File file) {
    final name = file.uri.pathSegments.last;
    return name.endsWith('.json') || name.endsWith('.tmp');
  }

  bool _isTemp(File file) => file.uri.pathSegments.last.endsWith('.tmp');

  bool _samePath(File left, File right) => left.path == right.path;

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // A source that cannot be deleted remains recoverable on the next load.
    }
  }

  Future<void> _deleteRequired(File file) async {
    if (file.existsSync()) await file.delete();
  }
}
