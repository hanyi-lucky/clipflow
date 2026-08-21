/// 单条同步操作（durable op log 里的一个条目）。
class SyncChange {
  final int seq;
  final String operationId;
  final String kind; // 'delete' | 'restore'
  final String entryId;
  final Map<String, dynamic>? row;

  const SyncChange({
    required this.seq,
    required this.operationId,
    required this.kind,
    required this.entryId,
    this.row,
  });

  bool get isDelete => kind == 'delete';
  bool get isRestore => kind == 'restore';

  factory SyncChange.fromJson(Map<String, dynamic> json) {
    final row = json['row'];
    return SyncChange(
      seq: (json['seq'] as num).toInt(),
      operationId: json['operationId'] as String,
      kind: json['kind'] as String,
      entryId: json['entryId'] as String,
      row: row is Map ? Map<String, dynamic>.from(row) : null,
    );
  }
}

/// /api/sync/changes 的一页：单调游标 + 增量操作列表。
class SyncChangesPage {
  final int cursor;
  final bool hasMore;
  final List<SyncChange> changes;

  const SyncChangesPage({
    required this.cursor,
    required this.hasMore,
    required this.changes,
  });

  factory SyncChangesPage.empty() =>
      const SyncChangesPage(cursor: 0, hasMore: false, changes: []);

  factory SyncChangesPage.fromJson(Map<String, dynamic> json) {
    final rawChanges = json['changes'] as List? ?? [];
    return SyncChangesPage(
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
      hasMore: json['hasMore'] as bool? ?? false,
      changes: rawChanges
          .whereType<Map>()
          .map((c) => SyncChange.fromJson(Map<String, dynamic>.from(c)))
          .toList(),
    );
  }
}
