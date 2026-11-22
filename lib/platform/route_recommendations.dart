import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const _errorCodes = <String>{
  'RECOMMENDATIONS_NETWORK_ERROR',
  'RECOMMENDATIONS_INVALID',
  'RECOMMENDATIONS_STALE',
  'RECOMMENDATIONS_STORAGE_ERROR',
  'RECOMMENDATIONS_BUSY',
  'RECOMMENDATIONS_UNAVAILABLE',
  'RECOMMENDATIONS_INTERRUPTED',
};

class RecommendationFailure implements Exception {
  const RecommendationFailure(this.code);
  final String code;
}

/// A verified native catalogue. It is advisory and never a saved route list.
class RecommendationStatus {
  const RecommendationStatus._({
    required this.rulesVersion,
    required this.packages,
    required this.busy,
    this.checkedAtMillis,
    this.errorCode,
  });

  const RecommendationStatus.empty()
      : rulesVersion = 0,
        packages = const {},
        checkedAtMillis = null,
        busy = false,
        errorCode = null;

  final int rulesVersion;
  final Set<String> packages;
  final int? checkedAtMillis;
  final bool busy;
  final String? errorCode;

  factory RecommendationStatus.fromPlatform(Object? raw) {
    if (raw is! Map || raw.length != 5 ||
        !const {'rulesVersion', 'packages', 'checkedAtMillis', 'busy', 'errorCode'}
            .every(raw.containsKey)) {
      throw const FormatException('Invalid recommendation status.');
    }
    final version = raw['rulesVersion'];
    final values = raw['packages'];
    final busy = raw['busy'];
    final checkedAt = raw['checkedAtMillis'];
    final error = raw['errorCode'];
    if (version is! int || version < 0 || version > 2147483647 ||
        values is! List || values.length > 256 || busy is! bool ||
        (checkedAt != null && (checkedAt is! int || checkedAt <= 0 ||
            checkedAt > 8640000000000000)) ||
        (error != null && (error is! String || !_errorCodes.contains(error)))) {
      throw const FormatException('Invalid recommendation status.');
    }
    final packages = <String>{};
    final pattern = RegExp(r'^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$');
    for (final value in values) {
      if (value is! String || value.length > 255 ||
          pattern.stringMatch(value) != value || !packages.add(value)) {
        throw const FormatException('Invalid recommendation packages.');
      }
    }
    if (version == 0 && packages.isNotEmpty) {
      throw const FormatException('Invalid recommendation fallback.');
    }
    return RecommendationStatus._(
      rulesVersion: version,
      packages: Set.unmodifiable(packages),
      busy: busy,
      checkedAtMillis: checkedAt as int?,
      errorCode: error as String?,
    );
  }

  /// Transport errors preserve the last accepted catalogue and check time.
  RecommendationStatus withError(String code) => RecommendationStatus._(
    rulesVersion: rulesVersion,
    packages: packages,
    busy: false,
    checkedAtMillis: checkedAtMillis,
    errorCode: _errorCodes.contains(code) ? code : 'RECOMMENDATIONS_INVALID',
  );
}

/// Reading status is local; only refreshRecommendations starts a network check.
/// Neither method changes selected applications or opens Android's installer.
class RouteRecommendations {
  RouteRecommendations({bool? isAndroid})
      : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _channel = MethodChannel('shop.pushok.flow/route_recommendations');
  final bool _isAndroid;

  Future<RecommendationStatus> recommendationStatus() =>
      _invoke('recommendationStatus', const Duration(seconds: 10));

  Future<RecommendationStatus> refreshRecommendations() =>
      _invoke('refreshRecommendations', const Duration(seconds: 50));

  Future<RecommendationStatus> _invoke(String method, Duration timeout) async {
    if (!_isAndroid) {
      throw const RecommendationFailure('RECOMMENDATIONS_UNAVAILABLE');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>(method).timeout(timeout);
      return RecommendationStatus.fromPlatform(raw);
    } on MissingPluginException {
      throw const RecommendationFailure('RECOMMENDATIONS_UNAVAILABLE');
    } on PlatformException catch (error) {
      throw RecommendationFailure(_errorCodes.contains(error.code)
          ? error.code : 'RECOMMENDATIONS_INVALID');
    } on TimeoutException {
      throw const RecommendationFailure('RECOMMENDATIONS_NETWORK_ERROR');
    } catch (_) {
      throw const RecommendationFailure('RECOMMENDATIONS_INVALID');
    }
  }
}
