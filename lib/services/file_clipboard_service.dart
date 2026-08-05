import 'package:flutter/services.dart';
import '../core/clipboard_channel_constants.dart';
import '../models/clipboard_file.dart';

/// 文件剪切板原生通道封装（与图片通道同模式）。
///
/// 通道不可用/抛错时：hasFiles 返回 false、getFiles 返回 null、
/// setFiles 返回 false，调用方安全降级，不抛未捕获异常。
class FileClipboardService {
  static const MethodChannel _channel = MethodChannel(AppChannelNames.clipboard);

  Future<bool> hasFiles() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        AppChannelMethods.hasFiles,
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<List<ClipboardFile>?> getFiles() async {
    try {
      final result = await _channel.invokeMethod<dynamic>(
        AppChannelMethods.getFiles,
      );
      if (result is! List) return null;
      final files = <ClipboardFile>[];
      for (final raw in result) {
        if (raw is Map) {
          files.add(ClipboardFile.fromMap(
            raw.map((k, v) => MapEntry('$k', v)),
          ));
        }
      }
      return files;
    } catch (e) {
      return null;
    }
  }

  Future<bool> setFiles(List<String> paths) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        AppChannelMethods.setFiles,
        {'paths': paths},
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
