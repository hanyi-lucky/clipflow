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

class DecryptionException implements Exception {
  final String message;
  DecryptionException(this.message);
  @override
  String toString() => 'DecryptionException: $message';
}

class ImageCompressionException extends ClipboardException {
  ImageCompressionException(super.message) : super(code: 'IMAGE_COMPRESS_ERROR');
}
