import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';

/// 只覆写 LAN 票据两个方法的最小 fake，验证 CloudRepository 的透传 + data 解包。
class _FakeCloudBaseService extends CloudBaseService {
  String? lastDeviceId;
  String? lastTicket;

  @override
  Future<Map<String, dynamic>> fetchLanTicket({required String deviceId}) async {
    lastDeviceId = deviceId;
    return <String, dynamic>{
      'code': 'SUCCESS',
      'data': <String, dynamic>{'ticket': 'ticket-abc', 'expiresAtMs': 123456789},
    };
  }

  @override
  Future<Map<String, dynamic>> verifyLanTicket({required String ticket}) async {
    lastTicket = ticket;
    return <String, dynamic>{
      'code': 'SUCCESS',
      'data': <String, dynamic>{
        'userId': 'user_test',
        'deviceId': 'device-x',
        'expiresAtMs': 123456789,
      },
    };
  }
}

void main() {
  late _FakeCloudBaseService cloud;
  late CloudRepository repository;

  setUp(() {
    cloud = _FakeCloudBaseService();
    repository = CloudRepository(cloud);
  });

  test('getLanTicket delegates with deviceId and unwraps data', () async {
    final result = await repository.getLanTicket(deviceId: 'device-x');
    expect(cloud.lastDeviceId, equals('device-x'));
    expect(result['ticket'], equals('ticket-abc'));
    expect(result['expiresAtMs'], equals(123456789));
  });

  test('verifyLanTicket delegates with ticket and unwraps data', () async {
    final result = await repository.verifyLanTicket(ticket: 'ticket-abc');
    expect(cloud.lastTicket, equals('ticket-abc'));
    expect(result['userId'], equals('user_test'));
    expect(result['deviceId'], equals('device-x'));
    expect(result['expiresAtMs'], equals(123456789));
  });
}
