import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/auth_guard.dart';

void main() {
  group('AuthGuard 滑动窗口', () {
    test('未达到阈值不锁定', () {
      final guard = AuthGuard(maxFailures: 5);
      guard.recordFailure();
      guard.recordFailure();
      expect(guard.isLocked, isFalse);
      expect(guard.lockRemaining, Duration.zero);
    });

    test('达到阈值后锁定，lockRemaining 大于零', () {
      final guard = AuthGuard(maxFailures: 5);
      for (var i = 0; i < 5; i++) {
        guard.recordFailure();
      }
      expect(guard.isLocked, isTrue);
      expect(guard.lockRemaining, greaterThan(Duration.zero));
    });

    test('窗口过期后自动解锁', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final guard = AuthGuard(
        maxFailures: 3,
        window: const Duration(seconds: 60),
        lockDuration: const Duration(seconds: 60),
        now: () => now,
      );
      guard.recordFailure();
      guard.recordFailure();
      guard.recordFailure();
      expect(guard.isLocked, isTrue);

      now = now.add(const Duration(seconds: 61));
      expect(guard.isLocked, isFalse);
      expect(guard.lockRemaining, Duration.zero);
    });

    test('lockRemaining 随时间递减', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final guard = AuthGuard(
        maxFailures: 2,
        now: () => now,
      );
      guard.recordFailure();
      guard.recordFailure();
      final first = guard.lockRemaining;
      expect(first, greaterThan(Duration.zero));

      now = now.add(const Duration(seconds: 10));
      final second = guard.lockRemaining;
      expect(second, lessThan(first));
    });

    test('reset 清除失败记录并解锁', () {
      final guard = AuthGuard(maxFailures: 5);
      for (var i = 0; i < 5; i++) {
        guard.recordFailure();
      }
      expect(guard.isLocked, isTrue);
      guard.reset();
      expect(guard.isLocked, isFalse);
      expect(guard.lockRemaining, Duration.zero);
    });

    test('isPasswordMismatch：无 storedUserId（新设备首登）不判错', () {
      final guard = AuthGuard();
      expect(
        guard.isPasswordMismatch(
          attemptedUserId: 'user_abc',
          storedUserId: null,
        ),
        isFalse,
      );
    });

    test('isPasswordMismatch：不一致判错，一致不判错', () {
      final guard = AuthGuard();
      expect(
        guard.isPasswordMismatch(
          attemptedUserId: 'user_abc',
          storedUserId: 'user_def',
        ),
        isTrue,
      );
      expect(
        guard.isPasswordMismatch(
          attemptedUserId: 'user_abc',
          storedUserId: 'user_abc',
        ),
        isFalse,
      );
    });

    test('isWeakPassword 委托弱密码列表', () {
      final guard = AuthGuard();
      expect(guard.isWeakPassword('123456'), isTrue);
      expect(guard.isWeakPassword('Strong-Pass-123!'), isFalse);
    });
  });
}
