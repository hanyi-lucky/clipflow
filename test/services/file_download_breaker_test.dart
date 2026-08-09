import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/file_download_breaker.dart';

class _MutableClock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

void main() {
  test('连续失败 < 上限不进入冷却', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    breaker.recordFailure('f1');
    breaker.recordFailure('f1');
    expect(breaker.isBlocked('f1'), isFalse);
  });

  test('连续失败达到上限（3 次）→ 进入 60s 冷却', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('f1');
    }
    expect(breaker.isBlocked('f1'), isTrue);
    // 59s 后仍冷却
    clock.now = clock.now.add(const Duration(seconds: 59));
    expect(breaker.isBlocked('f1'), isTrue);
  });

  test('冷却过期 → half-open 探针放行（isBlocked false）', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('f1');
    }
    clock.now = clock.now.add(const Duration(seconds: 61));
    expect(breaker.isBlocked('f1'), isFalse);
  });

  test('冷却过期后再失败 → 重新冷却（计数不清零，防抖）', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('f1');
    }
    clock.now = clock.now.add(const Duration(seconds: 61));
    expect(breaker.isBlocked('f1'), isFalse);
    breaker.recordFailure('f1'); // 探针失败
    expect(breaker.isBlocked('f1'), isTrue); // 重新冷却
  });

  test('成功 reset 清除该条目（五重 reset 之一）', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('f1');
    }
    expect(breaker.isBlocked('f1'), isTrue);
    breaker.reset('f1');
    expect(breaker.isBlocked('f1'), isFalse);
    expect(breaker.isBlocked('f1'), isFalse);
  });

  test('clear 清空全部条目（切账户）', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('f1');
    }
    breaker.recordFailure('f2');
    breaker.clear();
    expect(breaker.isBlocked('f1'), isFalse);
    expect(breaker.isBlocked('f2'), isFalse);
  });

  test('pruneOlderThan 只清 lastAttempt 早于游标的条目（行被取代）', () {
    final clock = _MutableClock();
    final breaker = FileDownloadBreaker(now: () => clock.now);
    // old 在 t0 达到冷却
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('old');
    }
    clock.now = clock.now.add(const Duration(seconds: 30));
    // new 在 t0+30 达到冷却
    for (var i = 0; i < 3; i++) {
      breaker.recordFailure('new');
    }
    // 游标推进到 t0+25：old（lastAttempt=t0）被取代清除，new（t0+30）保留
    breaker.pruneOlderThan(clock.now.millisecondsSinceEpoch - 5000);
    expect(breaker.isBlocked('old'), isFalse);
    expect(breaker.isBlocked('new'), isTrue);
  });
}
