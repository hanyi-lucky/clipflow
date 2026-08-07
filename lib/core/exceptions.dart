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

/// 云拉取前置校验失败类型。
enum CloudPullErrorType { sameAccount, emptyAccount }

/// 云拉取前置校验异常（同账户 / 空账户），UI 据此映射明确文案。
class CloudPullException extends ClipboardException {
  final CloudPullErrorType type;
  CloudPullException(this.type, String message)
      : super(
          message,
          code: type == CloudPullErrorType.sameAccount
              ? 'CLOUD_PULL_SAME_ACCOUNT'
              : 'CLOUD_PULL_EMPTY_ACCOUNT',
        );
}
