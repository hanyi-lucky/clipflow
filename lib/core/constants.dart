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
  // 文件下载重下熔断（Phase 2.3）：坏 artifact 连续失败上限与冷却时长。
  // 只拦「永久毒行」的跨 tick 自动重下，瞬态网络失败不受影响。
  static const int fileBreakerMaxFailures = 3;
  static const Duration fileBreakerCooldown = Duration(seconds: 60);

  // OSS 直传（Phase 5.3）：直传/直下超时（与 relay 一致，大文件流式传输需要长超时）。
  static const Duration ossDirectTimeout = Duration(seconds: 300);

  /// debug 开关：强制文件走服务器 relay 中转（跳过 OSS 直传/直下）。
  /// 仅测试/故障注入用，默认 false，非 UI 功能。
  static const bool forceFileRelay = false;
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

  /// hello 能力协商：`acks: 1` 表示支持 fileAck 帧（Phase 2.3）。
  /// 旧 peer 忽略多余字段；版本仍 1，原生插件零改动。
  static const int lanCapabilityAcks = 1;

  /// hello 能力协商：`ops: 1` 表示支持 delete/restore `op` 帧（Phase 5.2）。
  /// 只对声明 ops 的 peer 发 op 帧（旧 peer 未知帧会断链自愈）。
  static const int lanCapabilityOps = 1;

  /// text/image push 后等待 fileAck 的超时（对端帧到达即回 ack）。
  static const Duration lanAckTimeoutText = Duration(milliseconds: 500);

  /// file push 后等待 fileAck 的超时（对端 `.enc` 原子落盘后才回 ack）。
  static const Duration lanAckTimeoutFile = Duration(seconds: 5);

  /// ack-wait 获取 per-session reader slot 的有界等待上限。
  /// fetchLatest 遇 busy slot 跳过不排队（否则 300ms 超时会杀死文件 ack-wait）。
  static const Duration lanAckSlotWait = Duration(milliseconds: 200);

  /// push 重试基础退避：1s/2s/4s 指数（attempts=1 起）。
  static const Duration lanPushRetryBaseDelay = Duration(seconds: 1);

  /// push 重试最大次数（超过 give-up 并删 outbox，拉取 backstop + Cloud 兜底）。
  static const int lanPushMaxAttempts = 3;

  /// 待确认表硬 TTL：超过即放弃（拉取 backstop 收敛，无需无限重试）。
  static const Duration lanPendingAckTtl = Duration(seconds: 30);

  /// 待确认表最大条目数（LRU 淘汰）。
  static const int lanPendingAckMaxEntries = 64;

  /// 重试 sweeper 周期（start 后约 1s 先 drain 一次）。
  static const Duration lanRetrySweepInterval = Duration(seconds: 1);
  static const String lanCaps = 't/i/f';
}
