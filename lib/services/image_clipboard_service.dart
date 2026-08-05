import 'package:flutter/services.dart';
import '../core/clipboard_channel_constants.dart';
import '../models/clipboard_image.dart';

/// 图片剪切板原生通道封装（无状态，方法级调用）
///
/// Windows / 未注册平台：hasImage 返回 false、setImage 返回 false，
/// 文本路径照常，不抛未捕获异常。
class ImageClipboardService {
  static const MethodChannel _channel = MethodChannel(AppChannelNames.clipboard);

  /// 系统剪切板是否包含图片
  Future<bool> hasImage() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        AppChannelMethods.hasImage,
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 读取系统剪切板图片（原生归一为 PNG 字节）
  Future<ClipboardImage?> getImage() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        AppChannelMethods.getImage,
      );
      if (result == null) return null;

      final rawBytes = result['bytes'];
      // 防御式类型转换：MethodChannel 返回值类型不确定，
      // 可能是 Uint8List，也可能是普通 List<int>
      final Uint8List bytes = rawBytes is Uint8List
          ? rawBytes
          : Uint8List.fromList((rawBytes as List).cast<int>());
      final format = result['format'] as String? ?? 'png';
      final width = result['width'] as int? ?? 0;
      final height = result['height'] as int? ?? 0;

      return ClipboardImage(
        bytes: bytes,
        format: format,
        width: width,
        height: height,
      );
    } catch (e) {
      return null;
    }
  }

  /// 将图片字节写入系统剪切板（走原生 setImage，Flutter SDK 不支持图片）
  Future<bool> setImage(Uint8List bytes, {String format = 'png'}) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        AppChannelMethods.setImage,
        {'bytes': bytes, 'format': format},
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
