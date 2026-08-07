import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import '../core/constants.dart';
import '../core/exceptions.dart';
import '../l10n/app_strings.dart';

/// 压缩后的图片：全图字节 + 缩略图字节 + 元数据
class CompressedImage {
  final Uint8List bytes;
  final Uint8List thumbBytes;
  final int width;
  final int height;
  final String format; // 'jpeg' | 'png'
  final String stableHash; // 解码后像素内容的稳定哈希（跨重编码不变）

  const CompressedImage({
    required this.bytes,
    required this.thumbBytes,
    required this.width,
    required this.height,
    required this.format,
    required this.stableHash,
  });
}

List<int> _int32Bytes(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

/// 在 isolate 中执行的压缩入口（compute 要求顶层函数）
CompressedImage _compressInBackground(Map<String, dynamic> params) {
  final input = Uint8List.fromList(params['bytes'] as List<int>);
  final maxDimension = params['maxDimension'] as int;
  final thumbDimension = params['thumbDimension'] as int;

  final decoded = img.decodeImage(input);
  if (decoded == null) {
    throw ImageCompressionException(AppStrings.imageDecodeFailed);
  }

  final hasAlpha = decoded.numChannels == 4;
  final format = hasAlpha ? 'png' : 'jpeg';

  // 长边超过 maxDimension 才缩放，保持宽高比
  var resized = decoded;
  final longestEdge =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longestEdge > maxDimension) {
    resized = decoded.width >= decoded.height
        ? img.copyResize(
            decoded,
            width: maxDimension,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            decoded,
            height: maxDimension,
            interpolation: img.Interpolation.average,
          );
  }

  // 缩略图：长边 thumbDimension
  final resizedLongest =
      resized.width > resized.height ? resized.width : resized.height;
  img.Image thumb;
  if (resizedLongest > thumbDimension) {
    thumb = resized.width >= resized.height
        ? img.copyResize(
            resized,
            width: thumbDimension,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            resized,
            height: thumbDimension,
            interpolation: img.Interpolation.average,
          );
  } else {
    thumb = resized;
  }

  final bytes = hasAlpha
      ? Uint8List.fromList(img.encodePng(resized))
      : Uint8List.fromList(
          img.encodeJpg(resized, quality: AppConstants.jpgQuality),
        );
  final thumbBytes = Uint8List.fromList(
    img.encodeJpg(thumb, quality: AppConstants.thumbJpgQuality),
  );

  // 稳定哈希：基于压缩产物解码后的像素内容（128x128 降采样 RGBA）
  // + 宽高 + 格式，再做 4-bit 量化。
  // macOS/Android 写入剪切板时会重编码（JPEG→PNG / PNG→PNG），
  // 字节必变但解码像素一致；量化容忍 JPEG 有损重编码的轻微像素漂移，
  // 该哈希在重编码后保持稳定，用于上传去重。
  final encodedDecoded = img.decodeImage(bytes);
  if (encodedDecoded == null) {
    throw ImageCompressionException(AppStrings.imageCompressDecodeFailed);
  }
  final probe = img.copyResize(
    encodedDecoded,
    width: AppConstants.stableHashDimension,
    height: AppConstants.stableHashDimension,
    interpolation: img.Interpolation.average,
  );
  final rawProbe = probe.getBytes(order: img.ChannelOrder.rgba);
  final probeBytes = Uint8List(rawProbe.length);
  for (var i = 0; i < rawProbe.length; i++) {
    probeBytes[i] = (rawProbe[i] >> 4) << 4;
  }
  final stableHash = sha256.convert([
    ..._int32Bytes(resized.width),
    ..._int32Bytes(resized.height),
    ...utf8.encode(format),
    ...probeBytes,
  ]).toString();

  return CompressedImage(
    bytes: bytes,
    thumbBytes: thumbBytes,
    width: resized.width,
    height: resized.height,
    format: format,
    stableHash: stableHash,
  );
}

class ImageCompressionService {
  Future<CompressedImage> compress(
    Uint8List input, {
    int maxDimension = AppConstants.maxImageDimension,
    int thumbDimension = AppConstants.thumbDimension,
  }) async {
    return compute(_compressInBackground, {
      'bytes': input,
      'maxDimension': maxDimension,
      'thumbDimension': thumbDimension,
    });
  }
}
