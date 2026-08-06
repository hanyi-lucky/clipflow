import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/weak_password_list.dart';

void main() {
  group('weak_password_list', () {
    test('常见弱密码命中（数字/字母/组合）', () {
      const weak = [
        '123', '123456', '12345678', 'password', 'passw0rd', 'password123',
        '111111', '666666', '888888', 'qwerty', 'abc123', 'admin', 'root',
        'welcome', '1q2w3e4r', '1qaz2wsx', 'zxcvbnm', 'iloveyou', 'letmein',
        'woaini', '5201314',
      ];
      for (final p in weak) {
        expect(isWeakPassword(p), isTrue, reason: '$p 应判定为弱密码');
      }
    });

    test('长度小于 6 的密码判定为弱', () {
      expect(isWeakPassword('abc'), isTrue);
      expect(isWeakPassword('12345'), isTrue);
      expect(isWeakPassword('a1b2c'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isWeakPassword('Password'), isTrue);
      expect(isWeakPassword('QWERTY'), isTrue);
    });

    test('强密码不判定为弱', () {
      expect(isWeakPassword('Tr0ub4dor&3!xK'), isFalse);
      expect(isWeakPassword('correct-horse-battery-staple'), isFalse);
      expect(isWeakPassword('k8#mP2\$vL9!'), isFalse);
    });

    test('空字符串判定为弱', () {
      expect(isWeakPassword(''), isTrue);
    });
  });
}
