import '../core/constants.dart';

/// 单 historyId 的熔断状态（纯内存）。
class FileBreakerState {
  int consecutiveFailures = 0;

  /// 冷却截止时间（null = 未冷却）。
  DateTime? cooldownUntil;

  /// 最近一次失败对应的行时间戳（pruneOlderThan「行被取代」清理用）。
  /// 与行 timestamp（服务器游标）同域比较，避免设备时钟偏差误删刚失败的条目。
  int lastRowTimestampMs = 0;
}

/// 文件重下熔断（Phase 2.3）：只拦「坏 artifact 毒行」的跨 tick 自动重下。
///
/// - 触发：`recordFailure`（坏 .enc 类失败：hash/size/decrypt）累计达到
///   [AppConstants.fileBreakerMaxFailures]（3）→ 进入
///   [AppConstants.fileBreakerCooldown]（60s）冷却；
/// - 拦截：`isBlocked`（冷却期内 `_processFileDownload` 直接 return，
///   不再每 tick Cloud 重下）；
/// - half-open：冷却过期 → 放行一次探针；再失败 → 重新冷却（计数不清零防抖）；
/// - reset 五重：成功 / retryFileDownload / cancelFileDownload /
///   pruneOlderThan（行被取代）/ clear（切账户）。
///
/// 纯客户端内存逻辑，不影响主流程；瞬态网络失败不在此列（网络可能恢复）。
class FileDownloadBreaker {
  FileDownloadBreaker({
    this.maxFailures = AppConstants.fileBreakerMaxFailures,
    this.cooldown = AppConstants.fileBreakerCooldown,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxFailures;
  final Duration cooldown;
  final DateTime Function() _now;

  final Map<String, FileBreakerState> _states = {};

  /// 冷却期内返回 true（`_processFileDownload` 入口拦截）。
  bool isBlocked(String entryId) {
    final state = _states[entryId];
    final until = state?.cooldownUntil;
    if (until == null) return false;
    return _now().isBefore(until);
  }

  /// 记录一次坏 artifact 失败；达到上限 → 进入冷却。
  ///
  /// [rowTimestampMs] 为失败行的服务器时间戳（与 `pruneOlderThan` 同域比较）；
  /// 缺省回退到本机时钟。
  void recordFailure(String entryId, {int? rowTimestampMs}) {
    final state = _states.putIfAbsent(entryId, () => FileBreakerState());
    state.consecutiveFailures++;
    state.lastRowTimestampMs = rowTimestampMs ?? _now().millisecondsSinceEpoch;
    if (state.consecutiveFailures >= maxFailures) {
      state.cooldownUntil = _now().add(cooldown);
    }
  }

  /// 成功 / 手动重试 / 取消 → 清除该条目状态。
  void reset(String entryId) {
    _states.remove(entryId);
  }

  /// 切账户 → 清空全部。
  void clear() {
    _states.clear();
  }

  /// 行被取代（时间戳游标推进）→ 清理 lastRowTimestamp 早于游标的条目，
  /// 防 Map 膨胀。刚失败的当前行 lastRowTimestamp == 游标 → 不被误删。
  void pruneOlderThan(int timestampMs) {
    _states.removeWhere((_, state) => state.lastRowTimestampMs < timestampMs);
  }
}
