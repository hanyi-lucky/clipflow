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

/// LAN 加速相关常量（Phase 2.1 基础层）。
///
/// 帧上限预留 16MiB：图片全图 base64 上限约 6.7MB；2.2 起文件交付
/// 走 1MiB 分块帧（fileStart/fileChunk），单文件体积与帧上限解耦——
/// 文件体积只受 [lanMaxFileChunks] 约束，将来提上限只需增加帧数。
class LanConstants {
  /// LAN 协议版本（Hello/帧中的 `v` 字段）。
  static const int lanProtoVersion = 1;

  /// mDNS 服务类型（macOS NSNetService / Android NsdManager）。
  static const String lanServiceType = '_clipflow._tcp';

  /// 单帧最大字节数（含 4 字节长度头）。
  static const int lanMaxFrameBytes = 16 * 1024 * 1024;

  /// 握手总超时。
  static const Duration lanHandshakeTimeout = Duration(seconds: 5);

  /// 单帧读写超时。
  static const Duration lanFrameTimeout = Duration(seconds: 5);

  /// 服务端票据有效期（与 server/index.js LAN_TICKET_TTL_MS 默认一致）。
  static const Duration lanTicketTtl = Duration(minutes: 5);

  /// 最多维护的 verified peer 数（fetch round-robin 上限）。
  static const int maxVerifiedPeers = 4;

  /// 最大并发会话数。
  static const int maxConcurrentSessions = 4;

  /// 发现结果过期时间。
  static const Duration lanDiscoveryExpiry = Duration(seconds: 30);

  /// 握手失败 peer 的黑名单冷却时长。
  static const Duration lanBlacklistCooldown = Duration(seconds: 60);

  /// 会话空闲超时：超过该时长无任何帧则断开，需重新握手。
  static const Duration lanSessionIdleTimeout = Duration(minutes: 5);

  /// 单次 LAN fetch 的 peer 级超时（round-robin 内每个 peer 的上限）。
  static const Duration lanFetchTimeout = Duration(milliseconds: 300);

  /// 发起方连接（TLS 建连）超时。
  static const Duration lanConnectTimeout = Duration(seconds: 2);

  /// LAN 文件明文上限（Phase 2.2）：明文 > 15MiB 不走 LAN（Cloud-only）。
  static const int lanMaxFileBytes = 15 * 1024 * 1024;

  /// LAN 文件密文分块大小：单 chunk 密文 ≤ 1MiB，base64 后 ≈1.4MiB/帧。
  static const int lanFileChunkBytes = 1024 * 1024;

  /// 单文件最大 chunk 数（DoS/资源上限）：128 × 1MiB ≈ 128MiB 密文，
  /// 远超 50MiB 明文全局上限；将来提文件上限只需增加帧数，零协议改动。
  static const int lanMaxFileChunks = 128;

  /// mDNS 能力位：t=文本 / i=图片 / f=文件。仅展示/未来分流用，不参与认证。
  static const String lanCaps = 't/i/f';
}
