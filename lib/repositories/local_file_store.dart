import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import '../models/file_download_progress.dart';

/// 文件同步的本地二进制缓存：
/// - `clipflow_files_enc/<entryId>.enc`：下载/上传后的密文缓存
/// - `clipflow_files/<entryId>_<sanitizedName>`：解密后的可粘贴明文
/// - `clipflow_files_tmp/`：下载/加密中间文件（`.part`/临时密文）
///
/// 50MB 密文绝不进 SharedPreferences；容量上限由调用方在下载/复制完成后
/// 调用 [enforceCacheLimit] 触发。
class LocalFileStore {
  static const String encDirName = 'clipflow_files_enc';
  static const String plainDirName = 'clipflow_files';
  static const String tmpDirName = 'clipflow_files_tmp';

  final String? _overrideDirectoryPath;

  LocalFileStore({String? directoryPath}) : _overrideDirectoryPath = directoryPath;

  Future<String> _basePath() async {
    return _overrideDirectoryPath ??
        (await getApplicationSupportDirectory()).path;
  }

  Future<Directory> _directory(String name) async {
    final base = await _basePath();
    final dir = Directory('$base/$name');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> _encryptedDirectory() => _directory(encDirName);
  Future<Directory> _plaintextDirectory() => _directory(plainDirName);
  Future<Directory> _tmpDirectory() => _directory(tmpDirName);

  String encryptedPathFor(String entryId) =>
      '$encDirName/$entryId.enc';

  String plaintextPathFor(String entryId, String fileName) {
    final safeName = _sanitizeFileName(fileName);
    return '$plainDirName/${entryId}_$safeName';
  }

  Future<String> newTempPath(String suffix) async {
    final dir = await _tmpDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final nonce = Random.secure().nextInt(0x7fffffff);
    return '${dir.path}/${stamp}_$nonce$suffix';
  }

  /// 流式写入密文缓存：先写 tmp `.part`，完整接收后 rename。
  ///
  /// 传入 [cancelToken] 后可从中途取消：丢弃剩余流、删除 `.part`，
  /// 不 rename、不产生 `.enc`，并返回 null。
  Future<String?> saveEncryptedFromStream({
    required String entryId,
    required Stream<List<int>> stream,
    void Function(int received)? onProgress,
    FileTransferCancelToken? cancelToken,
  }) async {
    final encDir = await _encryptedDirectory();
    final tmpDir = await _tmpDirectory();
    final tmpFile = File(
      '${tmpDir.path}/${entryId}_${DateTime.now().microsecondsSinceEpoch}.part',
    );
    final target = File('${encDir.path}/${entryId}.enc');
    var received = 0;
    var done = false;
    final sink = tmpFile.openWrite();
    final completer = Completer<String?>();
    late StreamSubscription<List<int>> subscription;

    Future<void> abort() async {
      if (done) return;
      done = true;
      try {
        await subscription.cancel();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (tmpFile.existsSync()) await tmpFile.delete();
      } catch (_) {}
      if (!completer.isCompleted) completer.complete(null);
    }

    Future<void> fail(Object error, StackTrace stack) async {
      if (done) return;
      done = true;
      try {
        await subscription.cancel();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (tmpFile.existsSync()) await tmpFile.delete();
      } catch (_) {}
      if (!completer.isCompleted) completer.completeError(error, stack);
    }

    subscription = stream.listen(
      (chunk) {
        if (done) return;
        if (cancelToken?.isCancelled ?? false) {
          abort();
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      },
      onError: (Object error, StackTrace stack) {
        fail(error, stack);
      },
      onDone: () async {
        if (done) return;
        done = true;
        try {
          await sink.flush();
          await sink.close();
          if (target.existsSync()) {
            await target.delete();
          }
          await tmpFile.rename(target.path);
          if (!completer.isCompleted) completer.complete(target.path);
        } catch (e) {
          try {
            if (tmpFile.existsSync()) await tmpFile.delete();
          } catch (_) {}
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  /// 明文缓存路径；不存在返回 null。
  Future<String?> loadEncryptedPath(String entryId) async {
    final dir = await _encryptedDirectory();
    final file = File('${dir.path}/${entryId}.enc');
    if (await file.exists()) return file.path;
    return null;
  }

  /// 流式写入明文缓存（下载解密产物/本地粘贴副本）。
  Future<String> savePlaintextFromStream({
    required String entryId,
    required String fileName,
    required Stream<List<int>> stream,
    void Function(int received)? onProgress,
  }) async {
    final plainDir = await _plaintextDirectory();
    final tmpDir = await _tmpDirectory();
    final safeName = _sanitizeFileName(fileName);
    final tmpFile = File(
      '${tmpDir.path}/${entryId}_${DateTime.now().microsecondsSinceEpoch}.part',
    );
    final target = File('${plainDir.path}/${entryId}_$safeName');
    var received = 0;
    final sink = tmpFile.openWrite();
    try {
      await for (final chunk in stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      }
      await sink.flush();
      await sink.close();
      if (target.existsSync()) {
        await target.delete();
      }
      await tmpFile.rename(target.path);
      return target.path;
    } catch (e) {
      await sink.close();
      if (tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 把已生成的临时密文复制进密文缓存（上传成功后保留本地副本）。
  Future<String> importEncryptedFile(String entryId, String sourcePath) async {
    final dir = await _encryptedDirectory();
    final target = File('${dir.path}/${entryId}.enc');
    await File(sourcePath).copy(target.path);
    return target.path;
  }

  /// 把解密产物移入明文缓存目录（下载写回后供历史复制/懒粘贴复用）。
  Future<String> movePlaintextIntoCache(
    String entryId,
    String fileName,
    String sourcePath,
  ) async {
    final dir = await _plaintextDirectory();
    final safeName = _sanitizeFileName(fileName);
    final target = File('${dir.path}/${entryId}_$safeName');
    if (target.existsSync()) {
      await target.delete();
    }
    await File(sourcePath).rename(target.path);
    return target.path;
  }

  /// 删除条目的密文与明文缓存。
  Future<void> deleteEntry(String entryId) async {
    try {
      final encDir = await _encryptedDirectory();
      final enc = File('${encDir.path}/${entryId}.enc');
      if (await enc.exists()) {
        await enc.delete();
      }
      final plainDir = await _plaintextDirectory();
      await for (final entity in plainDir.list()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('${entryId}_')) {
            await entity.delete();
          }
        }
      }
      final tmpDir = await _tmpDirectory();
      await for (final entity in tmpDir.list()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('${entryId}_')) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      // 缓存删除失败不影响主流程
    }
  }

  /// 清理不在保留集合中的密文/明文孤儿。
  Future<void> cleanupOrphans(Set<String> keepIds) async {
    try {
      final encDir = await _encryptedDirectory();
      await _removeOrphansIn(encDir, keepIds, extension: '.enc');
      final plainDir = await _plaintextDirectory();
      await _removeOrphansIn(plainDir, keepIds);
    } catch (e) {
      // 清理失败仅降级
    }
  }

  /// 容量上限：按 mtime 从旧到新删除，正在下载/当前剪贴板路径受保护。
  Future<void> enforceCacheLimit(
    int maxBytes, {
    Set<String> protectedIds = const {},
  }) async {
    try {
      final encDir = await _encryptedDirectory();
      final plainDir = await _plaintextDirectory();
      final files = <File>[];
      await for (final entity in encDir.list()) {
        if (entity is File) files.add(entity);
      }
      await for (final entity in plainDir.list()) {
        if (entity is File) files.add(entity);
      }

      var total = 0;
      final sizes = <File, int>{};
      for (final file in files) {
        final length = await file.length();
        sizes[file] = length;
        total += length;
      }
      if (total <= maxBytes) return;

      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final file in files) {
        if (total <= maxBytes) break;
        final entryId = _entryIdFromFile(file);
        if (entryId != null && protectedIds.contains(entryId)) continue;
        final size = sizes[file] ?? 0;
        await file.delete();
        total -= size;
      }
    } catch (e) {
      // 容量清理失败仅降级
    }
  }

  Future<void> clearAll() async {
    try {
      final encDir = await _encryptedDirectory();
      await _clearDir(encDir);
      final plainDir = await _plaintextDirectory();
      await _clearDir(plainDir);
      final tmpDir = await _tmpDirectory();
      await _clearDir(tmpDir);
    } catch (e) {
      // 忽略
    }
  }

  Future<void> _clearDir(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }

  Future<void> _removeOrphansIn(
    Directory dir,
    Set<String> keepIds, {
    String? extension,
  }) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      String? entryId;
      if (extension != null && name.endsWith(extension)) {
        entryId = name.substring(0, name.length - extension.length);
      } else {
        entryId = _entryIdFromFile(entity);
      }
      if (entryId == null || !keepIds.contains(entryId)) {
        await entity.delete();
      }
    }
  }

  String? _entryIdFromFile(File file) {
    final name = file.uri.pathSegments.last;
    if (name.endsWith('.enc')) {
      return name.substring(0, name.length - 4);
    }
    final underscore = name.indexOf('_');
    if (underscore <= 0) return null;
    return name.substring(0, underscore);
  }

  String _sanitizeFileName(String name) {
    final replaced = name
        .replaceAll(RegExp(r'[\\/]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1F]'), '_');
    final trimmed = replaced.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return 'file';
    return trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed;
  }
}
