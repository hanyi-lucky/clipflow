import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// LAN 待确认推送的一条持久化操作（每 (userId, peerId, historyId) 一条）。
///
/// 最小持久化集：只存重建一次重试所需的字段——server-shape 密文行（不含
/// 明文文件名等敏感字段）、文件 artifact 引用（artifactId/encSize）。
/// ACK 后即 remove；give-up / 缺 artifact 的文件条目删除。
class LanOutboxEntry {
  LanOutboxEntry({
    required this.userId,
    required this.peerId,
    required this.historyId,
    required this.kind,
    required this.row,
    required this.enqueuedAtMs,
    this.artifactId,
    this.encSize,
    this.attempts = 0,
  });

  final String userId;
  final String peerId;
  final String historyId;

  /// 'text' | 'image' | 'file'。
  final String kind;

  /// server-shape 密文行（与 Cloud/`_toServerRow` 同构，无明文文件名）。
  final Map<String, dynamic> row;

  /// 文件条目：密文 artifact 引用（缺 artifact → 恢复时丢弃）。
  final String? artifactId;
  final int? encSize;

  final int enqueuedAtMs;

  /// 已失败（重试）次数。
  int attempts;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'userId': userId,
      'peerId': peerId,
      'historyId': historyId,
      'kind': kind,
      'row': row,
      'artifactId': artifactId,
      'encSize': encSize,
      'enqueuedAtMs': enqueuedAtMs,
      'attempts': attempts,
    };
  }

  factory LanOutboxEntry.fromJson(Map<String, dynamic> json) {
    final userId = json['userId'];
    final peerId = json['peerId'];
    final historyId = json['historyId'];
    final kind = json['kind'];
    final row = json['row'];
    final enqueuedAtMs = json['enqueuedAtMs'];
    if (userId is! String ||
        peerId is! String ||
        historyId is! String ||
        historyId.isEmpty ||
        kind is! String ||
        row is! Map ||
        enqueuedAtMs is! int) {
      throw const FormatException('malformed LAN outbox entry');
    }
    return LanOutboxEntry(
      userId: userId,
      peerId: peerId,
      historyId: historyId,
      kind: kind,
      row: Map<String, dynamic>.from(row),
      artifactId: json['artifactId'] as String?,
      encSize: json['encSize'] as int?,
      enqueuedAtMs: enqueuedAtMs,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// LAN outbox 持久化存储：独立顶层目录
/// **`clipflow_lan_outbox/<userId>/<peerId>/<historyId>.json`**。
///
/// 与云 outbox `clipflow_outbox/<userId>`（`local_outbox_store.dart`）完全
/// 不冲突；原子写（tmp + rename）；损坏条目跳过；账户切换 `clearPersistedOutbox`
/// 递归删除本用户目录（LAN 开关关闭保留，只有账户切换才清理）。
class LanOutboxStore {
  static const String dirName = 'clipflow_lan_outbox';

  final String? _overrideDirectoryPath;

  LanOutboxStore({String? directoryPath}) : _overrideDirectoryPath = directoryPath;

  Future<String> _basePath() async {
    return _overrideDirectoryPath ??
        (await getApplicationSupportDirectory()).path;
  }

  Future<Directory> _peerDirectory(
    String userId,
    String peerId, {
    bool create = true,
  }) async {
    final base = await _basePath();
    final dir = Directory('$base/$dirName/$userId/$peerId');
    if (create && !dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 加载某用户的全部待确认条目（跨 peer，损坏 JSON 跳过）。
  Future<List<LanOutboxEntry>> loadActive(String userId) async {
    final base = await _basePath();
    final userDir = Directory('$base/$dirName/$userId');
    if (!userDir.existsSync()) return [];

    final entries = <LanOutboxEntry>[];
    await for (final peerEntity in userDir.list()) {
      if (peerEntity is! Directory) continue;
      await for (final entity in peerEntity.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final decoded = jsonDecode(await entity.readAsString());
          if (decoded is! Map) {
            throw const FormatException('entry must be a JSON object');
          }
          final entry = LanOutboxEntry.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          if (entry.userId != userId) continue;
          entries.add(entry);
        } catch (_) {
          // 损坏条目跳过，不阻断其他条目加载。
        }
      }
    }
    return entries;
  }

  /// 写入一条待推送操作（先持久化、后 push——crash-safe）。
  Future<void> put(LanOutboxEntry entry) async {
    final dir = await _peerDirectory(entry.userId, entry.peerId);
    final target = File('${dir.path}/${entry.historyId}.json');
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(entry.toJson()), flush: true);
    if (target.existsSync()) await target.delete();
    await temp.rename(target.path);
  }

  /// ACK / give-up 后删除条目。
  Future<void> remove(String userId, String peerId, String historyId) async {
    final base = await _basePath();
    final file = File('$base/$dirName/$userId/$peerId/$historyId.json');
    if (file.existsSync()) await file.delete();
  }

  /// 账户切换：递归删除该用户的整个 LAN outbox 目录。
  Future<void> clearPersistedOutbox(String userId) async {
    final base = await _basePath();
    final dir = Directory('$base/$dirName/$userId');
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}
