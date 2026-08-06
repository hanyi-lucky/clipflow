class AppConstants {
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const Duration uploadDebounce = Duration(milliseconds: 500);
  static const int maxContentLength = 50000;
  static const int maxHistoryEntries = 100;
  static const int pbkdf2Iterations = 100000;
  static const int aesKeyLength = 32; // 256 bits
  static const int ivLength = 12;

  // 图片压缩
  static const int maxImageDimension = 2048;
  static const int thumbDimension = 256;
  static const int jpgQuality = 80;
  static const int thumbJpgQuality = 75;
  static const int maxImageBytes = 5 * 1024 * 1024;
  static const int stableHashDimension = 128; // 稳定像素哈希的降采样尺寸

  // 文件同步
  static const int maxFileBytes = 50 * 1024 * 1024; // 明文上限
  static const int fileChunkSize = 1024 * 1024; // 流式加解密/哈希 IO 块
  static const int localFileCacheMaxBytes = 1536 * 1024 * 1024; // 1.5GB
}

/// 图片文件扩展名，与 macOS/Windows 原生通道保持一致。
const Set<String> kImageFileExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'tiff', 'tif', 'bmp', 'webp', 'heic', 'heif',
};
