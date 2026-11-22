import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/platform/tunnel_diagnostics.dart';

Map<String, Object?> _statistics({
  Object? rx = 2048,
  Object? tx = 1024,
  Object? age = 12,
  Object? handshake = 'observed',
  Object? status = 'available',
}) => {
  'status': status,
  'rxBytes': rx,
  'txBytes': tx,
  'latestHandshakeAgeSeconds': age,
  'handshakeStatus': handshake,
};

Map<String, Object?> _status({Object? statistics}) => {
  'connected': true,
  'state': 'connected',
  'uptimeSeconds': 120,
  'lastErrorCode': null,
  'statistics': statistics ?? _statistics(),
};

void _expectNoMeasurements(TunnelDiagnostics value) {
  expect(value.uptimeSeconds, 0);
  expect(value.statistics.status, isNot(TunnelStatisticsStatus.available));
  expect(value.statistics.rxBytes, isNull);
  expect(value.statistics.txBytes, isNull);
  expect(value.statistics.latestHandshakeAgeSeconds, isNull);
  expect(value.statistics.handshakeStatus, HandshakeStatus.unknown);
}

void main() {
  test('Protocol decoding keeps VLESS separate from legacy WireGuard and discards alien handshakes', () {
    expect(TunnelDiagnostics.fromPlatform(_status()).protocol, TunnelProtocol.wireguard);
    final vless = TunnelDiagnostics.fromPlatform({..._status(), 'protocol': 'vless'});
    expect(vless.protocol, TunnelProtocol.vless);
    expect(vless.isKnown, isTrue);
    expect(vless.connected, isTrue);
    expect(vless.statistics.rxBytes, 2048);
    expect(vless.statistics.handshakeStatus, HandshakeStatus.unknown);
    expect(vless.statistics.latestHandshakeAgeSeconds, isNull);
    final unavailable = TunnelDiagnostics.fromPlatform({
      ..._status(), 'protocol': 'vless', 'statistics': {'status': 'unavailable'},
    });
    expect(unavailable.statistics.rxBytes, isNull);
    expect(unavailable.statistics.txBytes, isNull);
    expect(unavailable.statistics.status, TunnelStatisticsStatus.unavailable);
  });

  test('An explicit unknown protocol cannot become a WireGuard sample or retain secret text', () {
    for (final protocol in <Object?>[null, 1, true, 'SECRET_PROTOCOL', 'vmess']) {
      final value = TunnelDiagnostics.fromPlatform({..._status(), 'protocol': protocol});
      expect(value.protocol, TunnelProtocol.unknown);
      expect(value.isKnown, isFalse);
      expect(value.connected, isTrue);
      _expectNoMeasurements(value);
      expect(value.toString(), isNot(contains('SECRET_PROTOCOL')));
    }
  });

  test('Valid local state and aggregate counters remain distinct observations', () {
    final value = TunnelDiagnostics.fromPlatform(_status());
    expect(value.isKnown, isTrue);
    expect(value.connected, isTrue);
    expect(value.transitioning, isFalse);
    expect(value.uptimeSeconds, 120);
    expect(value.statistics.status, TunnelStatisticsStatus.available);
    expect(value.statistics.rxBytes, 2048);
    expect(value.statistics.txBytes, 1024);
    expect(value.statistics.latestHandshakeAgeSeconds, 12);
    expect(value.statistics.handshakeStatus, HandshakeStatus.observed);
  });

  test('A real zero sample differs from unavailable statistics and no handshake', () {
    final zero = TunnelDiagnostics.fromPlatform(_status(
      statistics: _statistics(rx: 0, tx: 0, age: null, handshake: 'never'),
    ));
    expect(zero.statistics.status, TunnelStatisticsStatus.available);
    expect(zero.statistics.rxBytes, 0);
    expect(zero.statistics.txBytes, 0);
    expect(zero.statistics.handshakeStatus, HandshakeStatus.never);
    expect(zero.statistics.latestHandshakeAgeSeconds, isNull);

    final unavailable = TunnelDiagnostics.fromPlatform(_status(
      statistics: _statistics(status: 'unavailable'),
    ));
    expect(unavailable.isKnown, isTrue);
    expect(unavailable.connected, isTrue);
    expect(unavailable.statistics.status, TunnelStatisticsStatus.unavailable);
    expect(unavailable.statistics.rxBytes, isNull);
    expect(unavailable.statistics.txBytes, isNull);
    expect(unavailable.statistics.latestHandshakeAgeSeconds, isNull);
  });

  test('Old native payload without statistics does not invent a zero reading', () {
    final data = _status()..remove('statistics');
    final value = TunnelDiagnostics.fromPlatform(data);
    expect(value.isKnown, isTrue);
    expect(value.connected, isTrue);
    expect(value.uptimeSeconds, 120);
    expect(value.statistics.status, TunnelStatisticsStatus.unavailable);
    expect(value.statistics.rxBytes, isNull);
    expect(value.statistics.txBytes, isNull);
  });

  test('Unknown or contradictory states keep only explicit last-known activation', () {
    for (final payload in <Object?>[
      null, false, 'SECRET_NATIVE_DETAIL', <Object?>[],
      {..._status(), 'connected': 'true'},
      {..._status(), 'connected': 1},
      {..._status(), 'connected': false},
      {..._status(), 'state': null},
      {..._status(), 'state': 'unknown'},
      {..._status(), 'state': 'disconnected'},
      {..._status(), 'state': 'SECRET_STATE'},
    ]) {
      final value = TunnelDiagnostics.fromPlatform(payload);
      expect(value.isKnown, isFalse);
      expect(value.connected,
          payload is Map && payload['connected'] == true);
      _expectNoMeasurements(value);
    }
  });

  test('Inactive and transitioning snapshots discard measurements from a prior session', () {
    for (final payload in [
      {..._status(), 'connected': false, 'state': 'disconnected'},
      {..._status(), 'connected': false, 'state': 'transitioning'},
      {..._status(), 'connected': true, 'state': 'transitioning'},
    ]) {
      final value = TunnelDiagnostics.fromPlatform(payload);
      expect(value.isKnown, isTrue);
      expect(value.transitioning, payload['state'] == 'transitioning');
      expect(value.connected, payload['connected']);
      _expectNoMeasurements(value);
      expect(value.statistics.status, payload['state'] == 'disconnected'
          ? TunnelStatisticsStatus.inactive : TunnelStatisticsStatus.unavailable);
    }
  });

  test('Malformed byte counters cannot become rounded or zero measurements', () {
    final invalid = <Object?>[
      null, true, false, -1, 1.0, double.nan, double.infinity,
      '2048', '9223372036854775808', BigInt.one << 63,
    ];
    for (final number in invalid) {
      for (final field in ['rxBytes', 'txBytes']) {
        final stats = {..._statistics(), field: number};
        final value = TunnelDiagnostics.fromPlatform(_status(statistics: stats));
        expect(value.isKnown, isTrue);
        expect(value.statistics.status, TunnelStatisticsStatus.unavailable);
        expect(value.statistics.rxBytes, isNull);
        expect(value.statistics.txBytes, isNull);
        expect(value.statistics.handshakeStatus, HandshakeStatus.unknown);
      }
    }
    const largestNativeCounter = 0x7fffffffffffffff;
    final largest = TunnelDiagnostics.fromPlatform(_status(
      statistics: _statistics(rx: largestNativeCounter, tx: largestNativeCounter),
    ));
    expect(largest.statistics.rxBytes, largestNativeCounter);
    expect(largest.statistics.txBytes, largestNativeCounter);
  });

  test('Malformed uptime cannot render as a successful current observation', () {
    for (final uptime in <Object?>[
      null, true, -1, 1.0, double.nan, '120', 0x7fffffffffffffff,
    ]) {
      final value = TunnelDiagnostics.fromPlatform({..._status(), 'uptimeSeconds': uptime});
      expect(value.isKnown, isFalse);
      expect(value.connected, isTrue);
      _expectNoMeasurements(value);
    }
  });

  test('Invalid or contradictory handshake ages preserve bytes without suggesting recent contact', () {
    for (final stats in [
      for (final age in <Object?>[null, -1, true, 1.0, double.nan, '12', 0x7fffffffffffffff])
        _statistics(age: age),
      _statistics(age: 0, handshake: 'never'),
      _statistics(age: 12, handshake: 'unknown'),
      _statistics(age: 12, handshake: 'SECRET_HANDSHAKE'),
      _statistics(age: 12, handshake: null),
    ]) {
      final value = TunnelDiagnostics.fromPlatform(_status(statistics: stats));
      expect(value.statistics.status, TunnelStatisticsStatus.available);
      expect(value.statistics.rxBytes, 2048);
      expect(value.statistics.txBytes, 1024);
      expect(value.statistics.handshakeStatus, HandshakeStatus.unknown);
      expect(value.statistics.latestHandshakeAgeSeconds, isNull);
    }
  });

  test('A valid old handshake is reported without inventing a network failure', () {
    final value = TunnelDiagnostics.fromPlatform(_status(
      statistics: _statistics(age: 60 * 60 * 24 * 30),
    ));
    expect(value.isKnown, isTrue);
    expect(value.connected, isTrue);
    expect(value.lastErrorCode, isNull);
    expect(value.statistics.handshakeStatus, HandshakeStatus.observed);
    expect(value.statistics.latestHandshakeAgeSeconds, 60 * 60 * 24 * 30);
    final justNow = TunnelDiagnostics.fromPlatform(_status(
      statistics: _statistics(age: 0),
    ));
    expect(justNow.statistics.handshakeStatus, HandshakeStatus.observed);
    expect(justNow.statistics.latestHandshakeAgeSeconds, 0);
  });

  test('Unrecognized statistics shapes cannot leak stale aggregate values', () {
    for (final stats in <Object?>[
      false, 'SECRET_STATISTICS', <Object?>[], <String, Object?>{},
      _statistics(status: 'inactive'), _statistics(status: 'SECRET_STATUS'),
    ]) {
      final value = TunnelDiagnostics.fromPlatform(_status(statistics: stats));
      expect(value.isKnown, isTrue);
      expect(value.statistics.status, TunnelStatisticsStatus.unavailable);
      expect(value.statistics.rxBytes, isNull);
      expect(value.statistics.txBytes, isNull);
      expect(value.statistics.latestHandshakeAgeSeconds, isNull);
    }
  });

  test('Only recognized error codes survive and decoded values do not retain the input maps', () {
    for (final code in ['WG_CONNECT_FAILED', 'WG_DISCONNECT_FAILED', 'WG_STATUS_FAILED',
      'XRAY_CONNECT_FAILED', 'XRAY_DISCONNECT_FAILED', 'XRAY_STATUS_FAILED',
      'ROUTES_APPS_UNAVAILABLE', 'ROUTES_APPS_CHECK_FAILED']) {
      final value = TunnelDiagnostics.fromPlatform({..._status(), 'lastErrorCode': code});
      expect(value.lastErrorCode, code);
    }
    for (final code in <Object?>[null, 42, true, 'SECRET_NATIVE_DETAIL', {'key': 'SECRET'}]) {
      final value = TunnelDiagnostics.fromPlatform({..._status(), 'lastErrorCode': code});
      expect(value.lastErrorCode, isNull);
    }

    final stats = _statistics();
    final input = _status(statistics: stats)
      ..['privateKey'] = 'SECRET'
      ..['endpoint'] = 'SECRET'
      ..['message'] = 'SECRET'
      ..['details'] = {'privateKey': 'SECRET'};
    final value = TunnelDiagnostics.fromPlatform(input);
    input['connected'] = false;
    stats['rxBytes'] = 999999;
    stats['latestHandshakeAgeSeconds'] = 0;
    expect(value.connected, isTrue);
    expect(value.statistics.rxBytes, 2048);
    expect(value.statistics.latestHandshakeAgeSeconds, 12);
    expect(value.lastErrorCode, isNull);
    expect(value.toString(), isNot(contains('SECRET')));
    expect(value.statistics.toString(), isNot(contains('SECRET')));
  });
}
