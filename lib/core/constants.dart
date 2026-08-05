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
}
