import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/exceptions.dart';

void main() {
  group('DecryptionException', () {
    test('stores message and formats toString', () {
      final e = DecryptionException('bad ciphertext');
      expect(e.message, 'bad ciphertext');
      expect(e.toString(), 'DecryptionException: bad ciphertext');
    });
  });
}
