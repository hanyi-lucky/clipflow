/// LAN 诊断计数（纯内存、主 isolate 单线程自增，无需锁）。
///
/// Phase 2.3 埋点消费：discovered/handshakeSuccess/handshakeRejected/
/// lanFetchHit/lanFetchMiss/pushSent/pushReceived/fallbackReason 8 类 +
/// ackSent/ackReceived。实例由 LanSyncManager 创建一份，注入
/// discovery/handshake/transport 三层，测试用同一实例断言。
///
/// 红线：计数失败不得影响主流程（只 int++/Map++，永不抛）。
class LanDiagnostics {
  /// mDNS 新发现的去重设备数。
  int discovered = 0;

  /// 双向挑战握手成功次数（initiator/responder 共用单一成功点）。
  int handshakeSuccess = 0;

  /// 握手被拒次数（wrongAccount/expiredTicket/replayNonce/ticketRejected/...）。
  int handshakeRejected = 0;

  /// LAN 拉取命中（push 缓存命中 + 网络命中）。
  int lanFetchHit = 0;

  /// LAN 拉取未命中（无 peer/超时/错误/重复）。
  int lanFetchMiss = 0;

  /// LAN push 帧发送（含重试，按 peer 计）。
  int pushSent = 0;

  /// LAN push 帧接收（text/image/file 帧到达即计）。
  int pushReceived = 0;

  /// 本端作为 responder 发出的 fileAck 帧数。
  int ackSent = 0;

  /// 本端作为 initiator 收到并匹配的 fileAck 帧数。
  int ackReceived = 0;

  /// LAN 会话被丢弃次数（initiator dropSession/_dropInitiatorSession）。
  /// Phase 25 量化「反复握手」：超时不再 drop 后，此计数应显著下降；
  /// 真断连（socket 错误/帧级读超时）仍计入。
  int sessionDropped = 0;

  final Map<LanFallbackReason, int> _fallbackReasons = {};

  /// 记录一次 Cloud 兜底原因（LAN 未命中/失败的分类）。
  void recordFallback(LanFallbackReason reason) {
    _fallbackReasons[reason] = (_fallbackReasons[reason] ?? 0) + 1;
  }

  /// 某 fallback 原因累计次数。
  int fallbackCount(LanFallbackReason reason) =>
      _fallbackReasons[reason] ?? 0;

  /// fallback 快照（不可变副本）。
  Map<LanFallbackReason, int> get fallbackSnapshot =>
      Map<LanFallbackReason, int>.unmodifiable(_fallbackReasons);

  /// 清零全部计数（LAN 启停/切账户/诊断 UI 手动清零）。
  void reset() {
    discovered = 0;
    handshakeSuccess = 0;
    handshakeRejected = 0;
    lanFetchHit = 0;
    lanFetchMiss = 0;
    pushSent = 0;
    pushReceived = 0;
    ackSent = 0;
    ackReceived = 0;
    sessionDropped = 0;
    _fallbackReasons.clear();
  }
}

/// Cloud 兜底原因分类（fallbackReason 埋点值）。
enum LanFallbackReason {
  /// LAN 未启用/未启动（纯 Cloud，非降级）。
  lanDisabled,

  /// LAN 启用但无 verified peer（无候选/全黑名单）。
  noPeer,

  /// 候选握手被拒（错账户/票据）。
  handshakeRejected,

  /// fetch 300ms 超时。
  fetchTimeout,

  /// fetch 抛网络/协议错误（会话丢弃）。
  fetchError,

  /// LAN 行已见过（`_knownHistoryIds` 去重）。
  duplicate,

  /// LAN 行解密失败（DecryptionException）。
  decodeFailed,

  /// LAN 文件行元数据已交付但本地无 `.enc`。
  localMissingEnc,

  /// artifact 明文 hash/size 与行不符（坏 .enc）。
  artifactMismatch,

  /// 文件超 LAN 上限（15MiB）只能 Cloud。
  overLimit,
}
