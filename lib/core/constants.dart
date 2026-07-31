class AppConstants {
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const Duration uploadDebounce = Duration(milliseconds: 500);
  static const int maxContentLength = 50000;
  static const int maxHistoryEntries = 100;
  static const int pbkdf2Iterations = 100000;
  static const int aesKeyLength = 32; // 256 bits
  static const int ivLength = 12;
}
