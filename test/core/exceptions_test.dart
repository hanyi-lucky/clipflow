import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/exceptions.dart';
import 'package:clipflow/l10n/app_strings.dart';

void main() {
  group('DecryptionException', () {
    test('stores message and formats toString', () {
      final e = DecryptionException('bad ciphertext');
      expect(e.message, 'bad ciphertext');
      expect(e.toString(), 'DecryptionException: bad ciphertext');
    });
  });

  group('CloudPullException', () {
    test('sameAccount 携带类型与 code', () {
      final e = CloudPullException(
        CloudPullErrorType.sameAccount,
        AppStrings.cloudPullSameAccount,
      );
      expect(e.type, CloudPullErrorType.sameAccount);
      expect(e.code, 'CLOUD_PULL_SAME_ACCOUNT');
      expect(e.message, AppStrings.cloudPullSameAccount);
    });

    test('emptyAccount 携带类型与 code', () {
      final e = CloudPullException(
        CloudPullErrorType.emptyAccount,
        AppStrings.cloudPullEmptyAccount,
      );
      expect(e.type, CloudPullErrorType.emptyAccount);
      expect(e.code, 'CLOUD_PULL_EMPTY_ACCOUNT');
      expect(e.message, AppStrings.cloudPullEmptyAccount);
    });
  });
}
