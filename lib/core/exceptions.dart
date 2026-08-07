import '../l10n/app_strings.dart';

class ClipboardException implements Exception {
  final String? code;
  final String message;
  ClipboardException(this.message, {this.code});

  @override
  String toString() => 'ClipboardException: $message (code: $code)';
}

class EncryptionException extends ClipboardException {
  EncryptionException(super.message) : super(code: 'ENCRYPT_ERROR');
}

class SyncException extends ClipboardException {
  SyncException(super.message) : super(code: 'SYNC_ERROR');
}

class AuthException extends ClipboardException {
  AuthException(super.message) : super(code: 'AUTH_ERROR');
}

/// 服务端 429 限流响应。retryAfterMs 为服务端建议的重试等待时间。
class RateLimitedException extends ClipboardException {
  final int retryAfterMs;
  RateLimitedException(this.retryAfterMs)
      : super(AppStrings.rateLimitedMessage, code: 'RATE_LIMITED');

  @override
  String toString() => 'RateLimitedException: $message (code: $code, retryAfterMs: $retryAfterMs)';
}

class DecryptionException implements Exception {
  final String message;
  DecryptionException(this.message);
  @override
  String toString() => 'DecryptionException: $message';
}

class ImageCompressionException extends ClipboardException {
  ImageCompressionException(super.message) : super(code: 'IMAGE_COMPRESS_ERROR');
}
