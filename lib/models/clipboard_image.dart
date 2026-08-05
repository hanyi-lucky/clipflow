import 'dart:typed_data';

/// 原生通道传入的原始剪切板图片
class ClipboardImage {
  final Uint8List bytes;
  final String format;
  final int width;
  final int height;

  const ClipboardImage({
    required this.bytes,
    required this.format,
    required this.width,
    required this.height,
  });
}
