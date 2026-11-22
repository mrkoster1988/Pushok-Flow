/// Aggregate tunnel observations only. No configuration or native exception
/// text is retained by these presentation models.
enum TunnelStatisticsStatus { available, inactive, unavailable }

enum HandshakeStatus { observed, never, unknown }

const _maxNativeInteger = 0x7fffffffffffffff;
// Keep seconds safe for callers that use Dart's microsecond-based Duration.
const _maxDurationSeconds = _maxNativeInteger ~/ 1000000;
const _safeErrorCodes = <String>{
  'WG_CONNECT_FAILED',
  'WG_DISCONNECT_FAILED',
  'WG_STATUS_FAILED',
  'ROUTES_APPS_UNAVAILABLE',
  'ROUTES_APPS_CHECK_FAILED',
};

int? _nonNegativeInteger(Object? value, {int maximum = _maxNativeInteger}) =>
    value is int && value >= 0 && value <= maximum ? value : null;

String? _safeErrorCode(Object? value) =>
    value is String && _safeErrorCodes.contains(value) ? value : null;

class TunnelStatistics {
  const TunnelStatistics({
    required this.status,
    this.rxBytes,
    this.txBytes,
    this.latestHandshakeAgeSeconds,
    this.handshakeStatus = HandshakeStatus.unknown,
  });

  const TunnelStatistics.unavailable()
      : status = TunnelStatisticsStatus.unavailable,
        rxBytes = null,
        txBytes = null,
        latestHandshakeAgeSeconds = null,
        handshakeStatus = HandshakeStatus.unknown;

  const TunnelStatistics.inactive()
      : status = TunnelStatisticsStatus.inactive,
        rxBytes = null,
        txBytes = null,
        latestHandshakeAgeSeconds = null,
        handshakeStatus = HandshakeStatus.unknown;

  final TunnelStatisticsStatus status;
  final int? rxBytes;
  final int? txBytes;
  final int? latestHandshakeAgeSeconds;
  final HandshakeStatus handshakeStatus;

  /// Decode an active tunnel's counters. A failed or empty native read must not
  /// become a valid zero-byte measurement or a recent handshake.
  factory TunnelStatistics.fromPlatform(Object? value) {
    if (value is! Map || value['status'] != 'available') {
      return const TunnelStatistics.unavailable();
    }
    final rx = _nonNegativeInteger(value['rxBytes']);
    final tx = _nonNegativeInteger(value['txBytes']);
    if (rx == null || tx == null) {
      return const TunnelStatistics.unavailable();
    }

    final age = _nonNegativeInteger(value['latestHandshakeAgeSeconds'],
        maximum: _maxDurationSeconds);
    var handshake = HandshakeStatus.unknown;
    int? observedAge;
    if (value['handshakeStatus'] == 'observed' && age != null) {
      handshake = HandshakeStatus.observed;
      observedAge = age;
    } else if (value['handshakeStatus'] == 'never' &&
        value['latestHandshakeAgeSeconds'] == null) {
      handshake = HandshakeStatus.never;
    }
    // Unknown, missing or contradictory handshake fields do not invalidate
    // independently valid byte counters. The age is discarded in those cases.
    return TunnelStatistics(
      status: TunnelStatisticsStatus.available,
      rxBytes: rx,
      txBytes: tx,
      latestHandshakeAgeSeconds: observedAge,
      handshakeStatus: handshake,
    );
  }
}

class TunnelDiagnostics {
  const TunnelDiagnostics({
    required this.isKnown,
    required this.connected,
    this.transitioning = false,
    this.uptimeSeconds = 0,
    this.lastErrorCode,
    this.statistics = const TunnelStatistics.unavailable(),
  });

  const TunnelDiagnostics.unavailable({this.connected = false})
      : isKnown = false,
        transitioning = false,
        uptimeSeconds = 0,
        lastErrorCode = null,
        statistics = const TunnelStatistics.unavailable();

  /// Whether native state was read successfully; `connected` alone can be a
  /// retained last-known state used to keep a disconnect action available.
  final bool isKnown;
  final bool connected;
  final bool transitioning;
  final int uptimeSeconds;
  final String? lastErrorCode;
  final TunnelStatistics statistics;

  factory TunnelDiagnostics.fromPlatform(Object? value) {
    if (value is! Map) return const TunnelDiagnostics.unavailable();
    final active = value['connected'];
    final state = value['state'];
    final error = _safeErrorCode(value['lastErrorCode']);

    TunnelDiagnostics unknown() => TunnelDiagnostics(
      isKnown: false,
      connected: active is bool && active,
      lastErrorCode: error,
    );

    if (active is! bool || state is! String) return unknown();
    if (state == 'transitioning') {
      return TunnelDiagnostics(
        isKnown: true,
        connected: active,
        transitioning: true,
        lastErrorCode: error,
      );
    }
    if (state == 'disconnected' && !active) {
      return TunnelDiagnostics(
        isKnown: true,
        connected: false,
        lastErrorCode: error,
        statistics: const TunnelStatistics.inactive(),
      );
    }
    if (state != 'connected' || !active) return unknown();

    final uptime = _nonNegativeInteger(value['uptimeSeconds'],
        maximum: _maxDurationSeconds);
    if (uptime == null) return unknown();
    return TunnelDiagnostics(
      isKnown: true,
      connected: true,
      uptimeSeconds: uptime,
      lastErrorCode: error,
      statistics: TunnelStatistics.fromPlatform(value['statistics']),
    );
  }
}
