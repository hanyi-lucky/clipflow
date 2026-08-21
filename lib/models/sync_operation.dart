/// The kind of content carried by a durable sync operation.
enum SyncOperationKind { text, image, file, delete, restore }

/// Lifecycle states persisted in the outbox manifest.
enum SyncOperationState { pending, sending, retryable, dead }

class SyncOperationFormatException implements FormatException {
  final String message;
  @override
  final dynamic source;
  @override
  final int? offset;

  const SyncOperationFormatException(this.message, [this.source, this.offset]);

  @override
  String toString() => 'SyncOperationFormatException: $message';
}

class SyncOperation {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String operationId;
  final String userId;
  final SyncOperationKind kind;
  final SyncOperationState state;
  final String dedupeKey;
  final int createdAtMs;
  final int updatedAtMs;
  final int attemptCount;
  final int nextAttemptAtMs;
  final Map<String, dynamic> payload;
  final String? artifactId;
  final String? lastError;

  const SyncOperation({
    this.schemaVersion = currentSchemaVersion,
    required this.operationId,
    required this.userId,
    required this.kind,
    required this.state,
    required this.dedupeKey,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.attemptCount,
    required this.nextAttemptAtMs,
    required this.payload,
    this.artifactId,
    this.lastError,
  });

  bool get isActive =>
      state == SyncOperationState.pending ||
      state == SyncOperationState.sending ||
      state == SyncOperationState.retryable;

  SyncOperation copyWith({
    int? schemaVersion,
    String? operationId,
    String? userId,
    SyncOperationKind? kind,
    SyncOperationState? state,
    String? dedupeKey,
    int? createdAtMs,
    int? updatedAtMs,
    int? attemptCount,
    int? nextAttemptAtMs,
    Map<String, dynamic>? payload,
    String? artifactId,
    String? lastError,
    bool clearArtifactId = false,
    bool clearLastError = false,
  }) {
    return SyncOperation(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      operationId: operationId ?? this.operationId,
      userId: userId ?? this.userId,
      kind: kind ?? this.kind,
      state: state ?? this.state,
      dedupeKey: dedupeKey ?? this.dedupeKey,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
      payload: payload ?? this.payload,
      artifactId: clearArtifactId ? null : (artifactId ?? this.artifactId),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'operationId': operationId,
      'userId': userId,
      'kind': kind.name,
      'state': state.name,
      'dedupeKey': dedupeKey,
      'createdAtMs': createdAtMs,
      'updatedAtMs': updatedAtMs,
      'attemptCount': attemptCount,
      'nextAttemptAtMs': nextAttemptAtMs,
      'payload': payload,
      'artifactId': artifactId,
      'lastError': lastError,
    };
  }

  factory SyncOperation.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schemaVersion');
    if (schemaVersion != currentSchemaVersion) {
      throw SyncOperationFormatException(
        'Unsupported schemaVersion: $schemaVersion',
        json,
      );
    }

    final kindName = _requiredString(json, 'kind');
    final stateName = _requiredString(json, 'state');
    final kind = _parseKind(kindName, json);
    final state = _parseState(stateName, json);
    final payload = json['payload'];
    if (payload is! Map) {
      throw SyncOperationFormatException('payload must be a map', json);
    }

    final artifactId = json['artifactId'];
    if (artifactId != null && artifactId is! String) {
      throw SyncOperationFormatException('artifactId must be a string or null', json);
    }
    final lastError = json['lastError'];
    if (lastError != null && lastError is! String) {
      throw SyncOperationFormatException('lastError must be a string or null', json);
    }

    return SyncOperation(
      schemaVersion: schemaVersion,
      operationId: _requiredString(json, 'operationId'),
      userId: _requiredString(json, 'userId'),
      kind: kind,
      state: state,
      dedupeKey: _requiredString(json, 'dedupeKey'),
      createdAtMs: _requiredInt(json, 'createdAtMs'),
      updatedAtMs: _requiredInt(json, 'updatedAtMs'),
      attemptCount: _requiredInt(json, 'attemptCount'),
      nextAttemptAtMs: _requiredInt(json, 'nextAttemptAtMs'),
      payload: Map<String, dynamic>.from(payload),
      artifactId: artifactId as String?,
      lastError: lastError as String?,
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw SyncOperationFormatException('$key must be a non-empty string', json);
    }
    return value;
  }

  static int _requiredInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! int) {
      throw SyncOperationFormatException('$key must be an integer', json);
    }
    return value;
  }

  static SyncOperationKind _parseKind(String value, Map<String, dynamic> json) {
    for (final kind in SyncOperationKind.values) {
      if (kind.name == value) return kind;
    }
    throw SyncOperationFormatException('Unknown operation kind: $value', json);
  }

  static SyncOperationState _parseState(
    String value,
    Map<String, dynamic> json,
  ) {
    for (final state in SyncOperationState.values) {
      if (state.name == value) return state;
    }
    throw SyncOperationFormatException('Unknown operation state: $value', json);
  }
}
