enum FileTransferStatus {
  pending,
  downloading,
  processing,
  completed,
  failed,
  cancelled,
}

/// 可取消的文件传输令牌：置位后，流式写入会在下一个数据块处中止。
class FileTransferCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}

/// 单文件下载任务的进度与状态，供 UI 展示下载进度条。
class FileDownloadProgress {
  final String entryId;
  String fileName;
  int? totalBytes;
  int receivedBytes;
  FileTransferStatus status;
  String? error;
  int retryCount;
  String? decryptedHash;
  FileTransferCancelToken? cancelToken;

  FileDownloadProgress({
    required this.entryId,
    required this.fileName,
    this.totalBytes,
    this.receivedBytes = 0,
    this.status = FileTransferStatus.pending,
    this.error,
    this.retryCount = 0,
    this.decryptedHash,
    this.cancelToken,
  });
}
