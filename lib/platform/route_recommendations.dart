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
  /// Offline starter recommendations. These are a display fallback, not
  /// automatically applied when an online catalogue is refreshed.
  static const Set<String> bundledPackages = {
    'com.idamob.tinkoff.android',
    'com.octopod.russianpost.client.android',
    'com.vk.im',
    'com.vkontakte.android',
    'com.wildberries.ru',
    'ru.alfabank.mobile.android',
    'ru.dublgis.dgismobile',
    'ru.oneme.app',
    'ru.ozon.app.android',
    'ru.rostel',
    'ru.rzd.pass',
    'ru.sberbankmobile',
    'ru.vtb24.mobilebanking.android',
    'ru.yandex.taxi',
    'ru.yandex.yandexmaps',
  };

  const RecommendationStatus._({
    required this.rulesVersion,
    required this.packages,
    required this.busy,
    required this.autoUpdateEnabled,
    this.checkedAtMillis,
    this.errorCode,
  });

  const RecommendationStatus.empty()
      : rulesVersion = 0,
        packages = const {},
        checkedAtMillis = null,
        busy = false,
        autoUpdateEnabled = true,
        errorCode = null;

  final int rulesVersion;
  final Set<String> packages;
  final int? checkedAtMillis;
  final bool busy;
  final bool autoUpdateEnabled;
  final String? errorCode;

  factory RecommendationStatus.fromPlatform(Object? raw) {
    if (raw is! Map || raw.length != 6 ||
        !const {'rulesVersion', 'packages', 'checkedAtMillis', 'busy', 'errorCode',
          'autoUpdateEnabled'}
            .every(raw.containsKey)) {
      throw const FormatException('Invalid recommendation status.');
    }
    final version = raw['rulesVersion'];
    final values = raw['packages'];
    final busy = raw['busy'];
    final autoUpdateEnabled = raw['autoUpdateEnabled'];
    final checkedAt = raw['checkedAtMillis'];
    final error = raw['errorCode'];
    if (version is! int || version < 0 || version > 2147483647 ||
        values is! List || values.length > 256 || busy is! bool ||
        autoUpdateEnabled is! bool ||
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
      autoUpdateEnabled: autoUpdateEnabled,
      checkedAtMillis: checkedAt as int?,
      errorCode: error as String?,
    );
  }

  /// Transport errors preserve the last accepted catalogue and check time.
  RecommendationStatus withError(String code) => RecommendationStatus._(
    rulesVersion: rulesVersion,
    packages: packages,
    busy: false,
    autoUpdateEnabled: autoUpdateEnabled,
    checkedAtMillis: checkedAtMillis,
    errorCode: _errorCodes.contains(code) ? code : 'RECOMMENDATIONS_INVALID',
  );
}

/// Status and settings are local. Automatic refresh is gated by native consent
/// and persisted timing; manual refresh remains explicit. No method changes
/// selected applications or opens Android's installer.
class RouteRecommendations {
  RouteRecommendations({bool? isAndroid})
      : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _channel = MethodChannel('shop.pushok.flow/route_recommendations');
  final bool _isAndroid;

  Future<RecommendationStatus> recommendationStatus() =>
      _invoke('recommendationStatus', const Duration(seconds: 10));

  Future<RecommendationStatus> refreshRecommendations() =>
      _invoke('refreshRecommendations', const Duration(seconds: 50));

  Future<RecommendationStatus> refreshRecommendationsIfDue() =>
      _invoke('refreshRecommendationsIfDue', const Duration(seconds: 50));

  Future<RecommendationStatus> setAutoUpdateEnabled(bool enabled) =>
      _invoke('setAutoUpdateEnabled', const Duration(seconds: 50),
          arguments: {'enabled': enabled});

  Future<RecommendationStatus> _invoke(String method, Duration timeout,
      {Map<String, Object?>? arguments}) async {
    if (!_isAndroid) {
      throw const RecommendationFailure('RECOMMENDATIONS_UNAVAILABLE');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>(method, arguments).timeout(timeout);
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
