import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/lan_diagnostics.dart';

void main() {
  test('全部计数初始为 0，fallback 快照为空', () {
    final d = LanDiagnostics();
    expect(d.discovered, 0);
    expect(d.handshakeSuccess, 0);
    expect(d.handshakeRejected, 0);
    expect(d.lanFetchHit, 0);
    expect(d.lanFetchMiss, 0);
    expect(d.pushSent, 0);
    expect(d.pushReceived, 0);
    expect(d.ackSent, 0);
    expect(d.ackReceived, 0);
    expect(d.sessionDropped, 0);
    expect(d.fallbackSnapshot, isEmpty);
  });

  test('计数自增与 fallback 分类累计', () {
    final d = LanDiagnostics();
    d.discovered++;
    d.handshakeSuccess++;
    d.pushSent++;
    d.ackSent++;
    d.sessionDropped++;
    d.recordFallback(LanFallbackReason.noPeer);
    d.recordFallback(LanFallbackReason.noPeer);
    d.recordFallback(LanFallbackReason.fetchTimeout);

    expect(d.discovered, 1);
    expect(d.handshakeSuccess, 1);
    expect(d.pushSent, 1);
    expect(d.ackSent, 1);
    expect(d.sessionDropped, 1);
    expect(d.fallbackCount(LanFallbackReason.noPeer), 2);
    expect(d.fallbackCount(LanFallbackReason.fetchTimeout), 1);
    expect(d.fallbackCount(LanFallbackReason.duplicate), 0);
    expect(d.fallbackSnapshot, hasLength(2));
  });

  test('snapshot 不可变：外部修改不影响内部状态', () {
    final d = LanDiagnostics();
    d.recordFallback(LanFallbackReason.decodeFailed);
    final snapshot = d.fallbackSnapshot;
    // Map.unmodifiable 的 put 会抛 UnsupportedError
    expect(() => snapshot[LanFallbackReason.decodeFailed] = 99,
        throwsUnsupportedError);
    expect(d.fallbackCount(LanFallbackReason.decodeFailed), 1);
  });

  test('reset 清空全部计数与 fallback', () {
    final d = LanDiagnostics();
    d.discovered = 5;
    d.handshakeSuccess = 3;
    d.handshakeRejected = 2;
    d.lanFetchHit = 4;
    d.lanFetchMiss = 7;
    d.pushSent = 6;
    d.pushReceived = 1;
    d.ackSent = 2;
    d.ackReceived = 3;
    d.sessionDropped = 4;
    d.recordFallback(LanFallbackReason.artifactMismatch);

    d.reset();

    expect(d.discovered, 0);
    expect(d.handshakeSuccess, 0);
    expect(d.handshakeRejected, 0);
    expect(d.lanFetchHit, 0);
    expect(d.lanFetchMiss, 0);
    expect(d.pushSent, 0);
    expect(d.pushReceived, 0);
    expect(d.ackSent, 0);
    expect(d.ackReceived, 0);
    expect(d.sessionDropped, 0);
    expect(d.fallbackSnapshot, isEmpty);
  });
}
