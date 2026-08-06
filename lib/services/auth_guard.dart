import 'dart:collection';
import '../core/weak_password_list.dart' as weak_password;

/// 本地登录防暴力尝试守卫（内存滑动窗口，App 重启清零=更宽松，明确接受）。
///
/// 服务端负责 API 层尝试速率限流；本守卫负责「用户连续输错密码」体验：
/// 窗口内失败次数达到 [maxFailures] 后本地锁定 [lockDuration]，UI 显示倒计时。
class AuthGuard {
  final int maxFailures;
  final Duration window;
  final Duration lockDuration;
  final DateTime Function() _now;
  final Queue<DateTime> _failures = Queue<DateTime>();

  AuthGuard({
    this.maxFailures = 5,
    this.window = const Duration(seconds: 60),
    this.lockDuration = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  bool get isLocked => lockRemaining > Duration.zero;

  Duration get lockRemaining {
    final now = _now();
    _prune(now);
    if (_failures.length < maxFailures) return Duration.zero;
    final lockUntil = _failures.first.add(lockDuration);
    final remaining = lockUntil.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 本地密码错误判定：已有 storedUserId（非新设备首登）且派生的 userId 不一致 → 密码错误。
  bool isPasswordMismatch({
    required String attemptedUserId,
    String? storedUserId,
  }) {
    return storedUserId != null && attemptedUserId != storedUserId;
  }

  /// 弱密码判定（委托 [weak_password.isWeakPassword]）。
  bool isWeakPassword(String password) => weak_password.isWeakPassword(password);

  /// 记录一次失败（窗口内超出阈值的旧失败会被清理）。
  void recordFailure() {
    final now = _now();
    _prune(now);
    _failures.addLast(now);
  }

  /// 解锁成功后清除失败记录。
  void reset() {
    _failures.clear();
  }

  void _prune(DateTime now) {
    while (_failures.isNotEmpty && now.difference(_failures.first) >= window) {
      _failures.removeFirst();
    }
  }
}
