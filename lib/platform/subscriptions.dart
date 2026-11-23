import 'package:flutter/services.dart';

import 'wireguard_profiles.dart';

/// Public subscription metadata. The personal URL is deliberately absent.
class FlowSubscription {
  const FlowSubscription({
    required this.id,
    required this.name,
    required this.host,
    required this.profileCount,
    required this.updatedAt,
    this.expiresAt,
    this.usedBytes,
    this.totalBytes,
  });

  final String id;
  final String name;
  final String host;
  final int profileCount;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final int? usedBytes;
  final int? totalBytes;
}

class SubscriptionStatus {
  const SubscriptionStatus.empty()
      : subscriptions = const [], automaticUpdatesEnabled = true,
        busy = false, errorCode = null, refreshErrors = const {};

  SubscriptionStatus._(List<FlowSubscription> values,
      this.automaticUpdatesEnabled, this.busy, this.errorCode,
      Map<String, String> refreshErrors)
      : subscriptions = List.unmodifiable(values),
        refreshErrors = Map.unmodifiable(refreshErrors);

  static const maxSubscriptions = 5;
  static const _refreshErrorCodes = {
    'SUBSCRIPTION_URL_INVALID', 'SUBSCRIPTION_INVALID', 'SUBSCRIPTION_TOO_LARGE',
    'SUBSCRIPTION_EMPTY', 'SUBSCRIPTION_UNSUPPORTED',
    'SUBSCRIPTION_NETWORK_ERROR', 'SUBSCRIPTION_TLS_ERROR', 'SUBSCRIPTION_AUTH_REQUIRED',
  };
  static final _id = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  final List<FlowSubscription> subscriptions;
  final bool automaticUpdatesEnabled;
  final bool busy;
  final String? errorCode;
  /// Last provider failures for current subscriptions; never contains URLs or messages.
  final Map<String, String> refreshErrors;

  factory SubscriptionStatus.fromPlatform(Object? raw) {
    const invalid = FormatException('Invalid subscription status');
    if (raw is! Map || raw.keys.any((key) => !const {
          'subscriptions', 'automaticUpdatesEnabled', 'busy', 'errorCode',
          'refreshErrors',
        }.contains(key)) ||
        raw['subscriptions'] is! List ||
        raw['automaticUpdatesEnabled'] is! bool) throw invalid;
    final busy = raw['busy'] ?? false;
    final errorCode = raw['errorCode'];
    if (busy is! bool || (errorCode != null &&
        (errorCode is! String || !RegExp(r'^[A-Z_]{1,64}$').hasMatch(errorCode)))) throw invalid;
    final entries = raw['subscriptions'] as List;
    if (entries.length > maxSubscriptions) throw invalid;
    final seen = <String>{};
    final subscriptions = <FlowSubscription>[];
    DateTime? date(Object? value, {bool mandatory = false}) {
      if (value == null && !mandatory) return null;
      if (value is! int || value < 0 || value > 8640000000000000) throw invalid;
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    int? bytes(Object? value) {
      if (value == null) return null;
      if (value is! int || value < 0) throw invalid;
      return value;
    }
    const keys = {'id', 'name', 'host', 'profileCount', 'updatedAt',
      'expiresAt', 'usedBytes', 'totalBytes'};
    for (final entry in entries) {
      if (entry is! Map || entry.keys.any((key) => !keys.contains(key))) throw invalid;
      final id = entry['id'];
      final name = entry['name'];
      final host = entry['host'];
      final count = entry['profileCount'];
      if (id is! String || !_id.hasMatch(id) || !seen.add(id) ||
          name is! String || !WireGuardProfiles.isValidName(name) ||
          host is! String || host.isEmpty || host.length > 253 ||
          RegExp(r'[\s/@?#\u0000-\u001f\u007f]').hasMatch(host) ||
          count is! int || count < 0 || count > WireGuardProfiles.maxProfiles) {
        throw invalid;
      }
      subscriptions.add(FlowSubscription(id: id, name: name, host: host,
        profileCount: count, updatedAt: date(entry['updatedAt'], mandatory: true)!,
        expiresAt: date(entry['expiresAt']), usedBytes: bytes(entry['usedBytes']),
        totalBytes: bytes(entry['totalBytes'])));
    }
    final errors = <String, String>{};
    if (raw.containsKey('refreshErrors')) {
      final failures = raw['refreshErrors'];
      if (failures is! Map || failures.length > maxSubscriptions) throw invalid;
      for (final entry in failures.entries) {
        final id = entry.key;
        final code = entry.value;
        if (id is! String || !seen.contains(id) || code is! String ||
            !_refreshErrorCodes.contains(code)) throw invalid;
        errors[id] = code;
      }
    }
    return SubscriptionStatus._(subscriptions, raw['automaticUpdatesEnabled'] as bool,
      busy, errorCode as String?, errors);
  }
}

/// Only a protected confirmation form may display or edit this transient draft.
class SubscriptionDraft {
  const SubscriptionDraft({required this.url, this.name = 'Моя подписка'});
  final String url;
  final String name;

  static bool validUrl(String raw) {
    if (raw.length > 4096 || raw != raw.trim() ||
        RegExp(r'[\s\u0000-\u001f\u007f]').hasMatch(raw)) return false;
    final uri = Uri.tryParse(raw);
    return uri != null && uri.scheme.toLowerCase() == 'https' &&
        uri.host.isNotEmpty && uri.userInfo.isEmpty && !uri.hasFragment;
  }

  static SubscriptionDraft? fromPlatform(Object? raw) {
    if (raw == null) return null;
    const invalid = FormatException('Invalid subscription link');
    if (raw is! Map || raw.keys.any((key) => key != 'url' && key != 'name')) {
      throw invalid;
    }
    final url = raw['url'];
    final name = raw['name'];
    if (url is! String || !validUrl(url) ||
        (name != null && (name is! String || !WireGuardProfiles.isValidName(name)))) {
      throw invalid;
    }
    return SubscriptionDraft(url: url, name: name as String? ?? 'Моя подписка');
  }
}

class FlowSubscriptions {
  FlowSubscriptions({required this.isAndroid});
  static const botUsername = '@mtproxy_pushok_bot';
  static const hubUsername = '@pushok_app';
  static const _channel = MethodChannel('shop.pushok.flow/subscriptions');
  final bool isAndroid;

  void listenForPendingLinks(void Function() listener) {
    if (!isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingLinkAvailable') listener();
    });
  }

  void dispose() {
    if (isAndroid) _channel.setMethodCallHandler(null);
  }

  Future<SubscriptionStatus> _status(String method, [Object? arguments]) async {
    if (!isAndroid) throw MissingPluginException();
    return SubscriptionStatus.fromPlatform(
      await _channel.invokeMethod<Object?>(method, arguments));
  }

  Future<SubscriptionStatus> status() => _status('status');
  Future<SubscriptionStatus> refreshDue() => _status('refreshDue');
  Future<SubscriptionStatus> importSubscription(String url, String name) =>
      _status('importSubscription', {'url': url, 'name': name});
  Future<SubscriptionStatus> refreshSubscription(String id) =>
      _status('refreshSubscription', {'id': id});
  Future<SubscriptionStatus> deleteSubscription(String id) =>
      _status('deleteSubscription', {'id': id});
  Future<SubscriptionStatus> setAutomaticUpdates(bool enabled) =>
      _status('setAutomaticUpdates', {'enabled': enabled});
  Future<SubscriptionDraft?> takePendingLink() async {
    if (!isAndroid) return null;
    return SubscriptionDraft.fromPlatform(
      await _channel.invokeMethod<Object?>('takePendingLink'));
  }
  Future<void> openPushokAccount() async {
    if (!isAndroid) throw MissingPluginException();
    await _channel.invokeMethod<void>('openPushokAccount');
  }

  Future<void> openPushokHub() async {
    if (!isAndroid) throw MissingPluginException();
    await _channel.invokeMethod<void>('openPushokHub');
  }
}

String subscriptionErrorMessage(Object error) {
  final code = error is PlatformException ? error.code : null;
  return switch (code) {
    'SUBSCRIPTION_URL_INVALID' =>
      'Нужна полная HTTPS-ссылка подписки, полученная в магазине или панели.',
    'SUBSCRIPTION_EMPTY' =>
      'В подписке нет подключений. Уточните срок доступа в магазине.',
    'SUBSCRIPTION_UNSUPPORTED' || 'UNSUPPORTED_TRANSPORT' ||
    'UNSUPPORTED_SECURITY' || 'UNSUPPORTED_PROFILE_OPTION' =>
      'Подписка содержит неподдерживаемые подключения. Нужны ссылки VLESS: TCP с TLS или REALITY, WebSocket или gRPC с TLS.',
    'SUBSCRIPTION_INVALID' || 'INVALID_VLESS_CONFIG' =>
      'Не удалось прочитать список серверов. Проверьте ссылку подписки.',
    'SUBSCRIPTION_TOO_LARGE' => 'Список серверов слишком большой.',
    'SUBSCRIPTION_EXISTS' => 'Эта подписка уже добавлена. Обновите её серверы.',
    'SUBSCRIPTION_NOT_FOUND' || 'SUBSCRIPTION_CHANGED' =>
      'Подписка изменилась. Обновите список и повторите действие.',
    'SUBSCRIPTION_LIMIT_REACHED' => 'Можно добавить до пяти подписок.',
    'PROFILE_LIMIT_REACHED' =>
      'Для серверов подписки не хватает места: можно хранить до 20 профилей.',
    'PROFILE_NAME_INVALID' => 'Укажите название: от 1 до 64 символов.',
    'PROFILE_STORE_UNAVAILABLE' =>
      'Не удалось записать настройки. Перезапустите приложение перед повторной попыткой.',
    'VPN_ACTIVE' => 'Для обновления серверов отключите подключение Flow.',
    'VPN_BUSY' || 'SUBSCRIPTION_BUSY' =>
      'Операция уже выполняется. Дождитесь завершения и повторите действие.',
    'VPN_STATE_UNAVAILABLE' =>
      'Состояние подключения неизвестно. Обновите диагностику и повторите действие.',
    'SUBSCRIPTION_NETWORK_ERROR' || 'SUBSCRIPTION_TIMEOUT' || 'SUBSCRIPTION_DOWNLOAD_FAILED' =>
      'Не удалось загрузить подписку. Сохранённые серверы остаются на устройстве.',
    'SUBSCRIPTION_TLS_ERROR' =>
      'Не удалось проверить защищённое соединение с сервером подписки. Уточните у поставщика HTTPS-адрес и сертификат.',
    'SUBSCRIPTION_HTTP_ERROR' || 'SUBSCRIPTION_ACCESS_DENIED' ||
    'SUBSCRIPTION_AUTH_REQUIRED' || 'SUBSCRIPTION_EXPIRED' =>
      'Сервис не предоставил список серверов. Проверьте подписку в магазине.',
    'SUBSCRIPTION_REDIRECT_BLOCKED' =>
      'Сервис перенаправил ссылку на неподдерживаемый адрес. Получите актуальную HTTPS-ссылку.',
    'SUBSCRIPTION_CANCELLED' || 'SUBSCRIPTION_INTERRUPTED' =>
      'Обновление подписки прервано. Повторите его, когда Flow открыт.',
    'SUBSCRIPTION_STATE_UNAVAILABLE' || 'SUBSCRIPTION_STORE_FAILED' =>
      'Не удалось прочитать или сохранить подписку. Перезапустите приложение и повторите действие.',
    _ => 'Не удалось выполнить действие с подпиской. Сохранённые серверы остаются на устройстве.',
  };
}
