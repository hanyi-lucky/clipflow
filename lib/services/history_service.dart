import 'dart:convert';
import '../models/clipboard_entry.dart';

class HistoryService {
  int maxEntries;
  final List<ClipboardEntry> _entries = [];

  List<ClipboardEntry> get entries {
    final sorted = List<ClipboardEntry>.from(_entries);
    sorted.sort((a, b) {
      // 置顶条目优先
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      // 同组内按时间倒序（最新在前）
      return b.timestamp.compareTo(a.timestamp);
    });
    return List.unmodifiable(sorted);
  }

  HistoryService({required this.maxEntries});

  void addEntry(ClipboardEntry entry) {
    // 第一优先：按 ID 去重（同一张图片经上传/下载/刷新三条路径入史）
    final idIndex = _entries.indexWhere((e) => e.id == entry.id);
    if (idIndex >= 0) {
      final existing = _entries[idIndex];
      // 保留旧条目的置顶状态（新条目可能未携带 isPinned）
      final merged = entry.copyWith(isPinned: existing.isPinned || entry.isPinned);
      _entries[idIndex] = merged;
      if (idIndex != 0) {
        final moved = _entries.removeAt(idIndex);
        _entries.insert(0, moved);
      }
      return;
    }

    // 第二优先：图片按 stableHash 去重（防旧行 history_id 缺失回退 UUID 造成的重复）
    if (entry.type == ContentType.image &&
        entry.stableHash != null &&
        entry.stableHash!.isNotEmpty) {
      final hashIndex = _entries.indexWhere(
        (e) =>
            e.type == ContentType.image &&
            e.stableHash != null &&
            e.stableHash == entry.stableHash,
      );
      if (hashIndex >= 0) {
        final existing = _entries[hashIndex];
        final merged = entry.copyWith(isPinned: existing.isPinned || entry.isPinned);
        _entries[hashIndex] = merged;
        if (hashIndex != 0) {
          final moved = _entries.removeAt(hashIndex);
          _entries.insert(0, moved);
        }
        return;
      }
    }

    // 文件按 ID + fileHash 去重（不走文本 trim；文件内容哈希跨设备稳定）
    if (entry.type == ContentType.file &&
        entry.fileHash != null &&
        entry.fileHash!.isNotEmpty) {
      final fileHashIndex = _entries.indexWhere(
        (e) =>
            e.type == ContentType.file &&
            e.fileHash != null &&
            e.fileHash == entry.fileHash,
      );
      if (fileHashIndex >= 0) {
        final existing = _entries[fileHashIndex];
        final merged =
            entry.copyWith(isPinned: existing.isPinned || entry.isPinned);
        _entries[fileHashIndex] = merged;
        if (fileHashIndex != 0) {
          final moved = _entries.removeAt(fileHashIndex);
          _entries.insert(0, moved);
        }
        return;
      }
    }

    // 第三优先：文本按内容去重
    int existingIndex = -1;
    if (entry.type == ContentType.text && entry.content.isNotEmpty) {
      existingIndex = _entries.indexWhere(
        (e) =>
            e.type == ContentType.text &&
            e.content.trim() == entry.content.trim(),
      );
    }

    if (existingIndex >= 0) {
      final existing = _entries[existingIndex];
      _entries[existingIndex] = existing.copyWith(
        id: entry.id,
        timestamp: entry.timestamp,
        sourceDeviceId: entry.sourceDeviceId,
        sourceDeviceName: entry.sourceDeviceName,
      );
      if (existingIndex != 0) {
        final moved = _entries.removeAt(existingIndex);
        _entries.insert(0, moved);
      }
    } else {
      _entries.insert(0, entry);
      _trim();
    }
  }

  void removeEntry(String id) {
    _entries.removeWhere((e) => e.id == id);
  }

  void togglePin(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index >= 0) {
      _entries[index] = _entries[index].copyWith(isPinned: !_entries[index].isPinned);
    }
  }

  void updateMaxEntries(int newMax) {
    maxEntries = newMax < 0 ? 0 : newMax;
    _trim();
  }

  void _trim() {
    while (_entries.where((e) => !e.isPinned).length > maxEntries) {
      int lastIdx = -1;
      for (int i = _entries.length - 1; i >= 0; i--) {
        if (!_entries[i].isPinned) {
          lastIdx = i;
          break;
        }
      }
      if (lastIdx >= 0) {
        _entries.removeAt(lastIdx);
      } else {
        break;
      }
    }
  }

  String toJson() {
    return json.encode(_entries.map((e) => e.toMap()).toList());
  }

  void fromJson(String jsonString) {
    final list = jsonDecode(jsonString) as List;
    _entries.clear();
    for (final map in list) {
      _entries.add(ClipboardEntry.fromMap(map as Map<String, dynamic>));
    }
  }

  void clear() {
    _entries.clear();
  }
}
