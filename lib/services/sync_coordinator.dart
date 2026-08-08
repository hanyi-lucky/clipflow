import 'dart:typed_data';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:uuid/uuid.dart';

import '../models/sync_operation.dart';
import '../repositories/local_file_store.dart';
import '../repositories/outbox_store.dart';
import 'cloud_sync_transport.dart';
import 'sync_service.dart';
import 'sync_transport.dart';

class SyncCoordinator {
  final String userId;
  final SyncService _syncService;
  final SyncTransport _transport;
  final OutboxStore _outbox;
  final LocalFileStore _fileStore;
  final Duration retryBaseDelay;
  final DateTime Function() _now;
  final Uuid _uuid;
  final Future<void> Function(SyncOperation)? _onOperationSucceeded;
  bool _draining = false;
  bool _closed = false;

  SyncCoordinator({
    required this.userId,
    required SyncService syncService,
    required SyncTransport transport,
    required OutboxStore outbox,
    required LocalFileStore fileStore,
    this.retryBaseDelay = const Duration(milliseconds: 500),
    DateTime Function()? now,
    Uuid? uuid,
    Future<void> Function(SyncOperation)? onOperationSucceeded,
  })  : _syncService = syncService,
        _transport = transport,
        _outbox = outbox,
        _fileStore = fileStore,
        _now = now ?? DateTime.now,
        _uuid = uuid ?? const Uuid(),
        _onOperationSucceeded = onOperationSucceeded;

  factory SyncCoordinator.cloud({
    required String userId,
    required SyncService syncService,
    required CloudSyncTransport transport,
    required OutboxStore outbox,
    required LocalFileStore fileStore,
    Duration retryBaseDelay = const Duration(milliseconds: 500),
    Future<void> Function(SyncOperation)? onOperationSucceeded,
  }) {
    return SyncCoordinator(
      userId: userId,
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      retryBaseDelay: retryBaseDelay,
      onOperationSucceeded: onOperationSucceeded,
    );
  }

  Future<String?> uploadContent(String content) async {
    if (_closed) return null;
    final dedupeKey = sha256.convert(utf8.encode(content)).toString();
    if (_syncService.isContentHashUploaded(dedupeKey)) return null;

    final existing = await _outbox.findActiveByDedupeKey(
      userId,
      SyncOperationKind.text,
      dedupeKey,
    );
    if (existing != null) {
      await drainOnce();
      return existing.operationId;
    }

    final operationId = _uuid.v4();
    final prepared = await _syncService.prepareContent(
      content: content,
      operationId: operationId,
    );
    if (prepared == null) return null;
    await _enqueue(prepared, operationId);
    await drainOnce();
    return operationId;
  }

  Future<ImageUploadResult?> uploadImage({
    required Uint8List bytes,
    required Uint8List thumbBytes,
    required int width,
    required int height,
    required String format,
    required String stableHash,
  }) async {
    if (_closed) return null;
    if (_syncService.isContentHashUploaded(stableHash)) return null;
    final existing = await _outbox.findActiveByDedupeKey(
      userId,
      SyncOperationKind.image,
      stableHash,
    );
    if (existing != null) {
      await drainOnce();
      return ImageUploadResult(
        historyId: existing.operationId,
        encryptedBase64: existing.payload['content'] as String,
        encryptedThumbBase64: existing.payload['thumb'] as String,
      );
    }

    final operationId = _uuid.v4();
    final prepared = await _syncService.prepareImage(
      bytes: bytes,
      thumbBytes: thumbBytes,
      width: width,
      height: height,
      format: format,
      stableHash: stableHash,
      operationId: operationId,
    );
    if (prepared == null) return null;
    await _enqueue(prepared, operationId);
    await drainOnce();
    return ImageUploadResult(
      historyId: operationId,
      encryptedBase64: prepared.payload['content'] as String,
      encryptedThumbBase64: prepared.payload['thumb'] as String,
    );
  }

  Future<FileUploadResult?> uploadFile({
    required String encryptedPath,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String plaintextHash,
    required int timestamp,
  }) async {
    if (_closed) return null;
    final dedupeKey = 'file:$plaintextHash';
    if (_syncService.isFileHashUploaded(plaintextHash)) return null;
    final existing = await _outbox.findActiveByDedupeKey(
      userId,
      SyncOperationKind.file,
      dedupeKey,
    );
    if (existing != null) {
      await drainOnce();
      return FileUploadResult(historyId: existing.operationId);
    }

    final operationId = _uuid.v4();
    final prepared = await _syncService.prepareFile(
      plaintextHash: plaintextHash,
      operationId: operationId,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      timestamp: timestamp,
    );
    if (prepared == null) return null;

    await _fileStore.importEncryptedFile(operationId, encryptedPath);
    await _enqueue(prepared, operationId, artifactId: operationId);
    await drainOnce();
    return FileUploadResult(historyId: operationId);
  }

  Future<DownloadResult?> downloadLatestContent() async {
    if (_closed) return null;
    final current = await _transport.fetchCurrentClipboardWithDeletions();
    return _syncService.decodeCurrentClipboard(current);
  }

  Future<void> drainOnce() async {
    if (_closed || _draining) return;
    _draining = true;
    try {
      final operations = await _outbox.loadActive(userId);
      for (final operation in operations) {
        if (operation.state == SyncOperationState.retryable &&
            operation.nextAttemptAtMs > _now().millisecondsSinceEpoch) {
          continue;
        }
        await _send(operation);
        break;
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> discardAccountOutbox() async {
    final artifacts = await _outbox.clearUser(userId);
    for (final artifactId in artifacts) {
      await _fileStore.deleteEntry(artifactId);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }

  Future<void> _enqueue(
    PreparedSyncOperation prepared,
    String operationId, {
    String? artifactId,
  }) async {
    final now = _now().millisecondsSinceEpoch;
    await _outbox.put(
      SyncOperation(
        operationId: operationId,
        userId: userId,
        kind: prepared.kind,
        state: SyncOperationState.pending,
        dedupeKey: prepared.dedupeKey,
        createdAtMs: now,
        updatedAtMs: now,
        attemptCount: 0,
        nextAttemptAtMs: now,
        payload: prepared.payload,
        artifactId: artifactId,
      ),
    );
  }

  Future<void> _send(SyncOperation operation) async {
    final sending = operation.copyWith(
      state: SyncOperationState.sending,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    await _outbox.update(sending);
    try {
      await _transport.send(sending);
      _syncService.markUploadSucceeded(sending.dedupeKey);
      await _outbox.remove(userId, sending.operationId);
      // 回执挂在 durable success 点之后：send 已返回、去重状态已写、
      // manifest 已删。任何路径（direct upload* 内 drain、_syncTick
      // 后台 drain 重试、dedupe 路径 drain、401 重放成功）的发送成功都
      // 收敛到这里；回调异常绝不 rethrow，否则会把已删除 manifest 的
      // 已成功操作重新写回 outbox → 下次 drain 重复上传。
      await _notifySuccess(sending);
    } catch (error) {
      final attemptCount = sending.attemptCount + 1;
      final dead = _isDead(error);
      final updated = sending.copyWith(
        state: dead ? SyncOperationState.dead : SyncOperationState.retryable,
        attemptCount: attemptCount,
        nextAttemptAtMs: dead
            ? sending.nextAttemptAtMs
            : _nextRetryAt(attemptCount),
        updatedAtMs: _now().millisecondsSinceEpoch,
        lastError: _sanitizeError(error),
      );
      await _outbox.update(updated);
      if (dead && updated.artifactId != null) {
        await _fileStore.deleteEntry(updated.artifactId!);
      }
      rethrow;
    }
  }

  Future<void> _notifySuccess(SyncOperation operation) async {
    final callback = _onOperationSucceeded;
    if (callback == null) return;
    try {
      await callback(operation);
    } catch (error) {
      debugPrint('[SYNC-COORDINATOR] Success callback failed: $error');
    }
  }

  int _nextRetryAt(int attemptCount) {
    final exponent = (attemptCount - 1).clamp(0, 6).toInt();
    final delay = retryBaseDelay.inMilliseconds * (1 << exponent);
    return _now().millisecondsSinceEpoch + delay.clamp(0, 30000).toInt();
  }

  bool _isDead(Object error) {
    if (error is ArgumentError || error is FormatException || error is StateError) {
      return true;
    }
    return RegExp(r'HTTP 4\d\d').hasMatch(error.toString());
  }

  String _sanitizeError(Object error) {
    final value = error.toString();
    if (value.length <= 240) return value;
    return value.substring(0, 240);
  }
}
