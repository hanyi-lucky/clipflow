import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 全图密文文件缓存。
///
/// 密文只落本地文件（不入 SharedPreferences），目录：
/// `getApplicationSupportDirectory()/clipflow_images/<entryId>.bin`。
class LocalImageStore {
  static const String subDirectoryName = 'clipflow_images';

  final String? _overrideDirectoryPath;

  LocalImageStore({String? directoryPath}) : _overrideDirectoryPath = directoryPath;

  Future<Directory> _imagesDirectory() async {
    final basePath = _overrideDirectoryPath ??
        (await getApplicationSupportDirectory()).path;
    final dir = Directory('$basePath/$subDirectoryName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  File _fileFor(Directory dir, String entryId) =>
      File('${dir.path}/$entryId.bin');

  /// 保存全图密文
  Future<void> save(String entryId, String base64) async {
    final dir = await _imagesDirectory();
    await _fileFor(dir, entryId).writeAsString(base64);
  }

  /// 读取全图密文，不存在或 IO 失败返回 null
  Future<String?> load(String entryId) async {
    try {
      final dir = await _imagesDirectory();
      final file = _fileFor(dir, entryId);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      return null;
    }
  }

  /// 删除单个条目的缓存
  Future<void> delete(String entryId) async {
    try {
      final dir = await _imagesDirectory();
      final file = _fileFor(dir, entryId);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // 缓存删除失败不影响主流程
    }
  }

  /// 清理不在保留集合中的孤儿缓存文件
  Future<void> cleanupOrphans(Set<String> keepIds) async {
    try {
      final dir = await _imagesDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final entryId = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last.replaceAll('.bin', '')
            : '';
        if (!keepIds.contains(entryId)) {
          await entity.delete();
        }
      }
    } catch (e) {
      // 清理失败仅降级，不影响历史列表
    }
  }

  /// 清空全部缓存
  Future<void> clearAll() async {
    try {
      final dir = await _imagesDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    } catch (e) {
      // 忽略
    }
  }
}
