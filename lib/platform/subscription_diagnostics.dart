import 'package:flutter/services.dart';

import '../models/app_version.dart';
import 'subscriptions.dart';

enum SubscriptionDiagnosticOperation {
  addSubscription,

  /// A restored failure does not establish whether the refresh was automatic.
  refreshServers,
  manualRefresh,
  automaticRefresh,
  readStatus,
  deleteSubscription,
  setAutomaticUpdates,
}

enum SubscriptionDiagnosticSource {
  manualInput,
  clipboard,
  cameraQr,
  imageQr,
  externalLink,
  savedSubscription,
  file,
}

/// An immutable, explicitly shareable failure snapshot with no private input.
///
/// Native messages, details, subscription metadata and configuration are never
/// retained. Codes must match the allowlist exactly; even a well-formed unknown
/// code can contain private information. Time and counts are omitted because a
/// restored failure does not establish when it happened or what was downloaded.
/// Constructing or reading a report performs no clipboard, logging or I/O work.
final class SubscriptionDiagnostic {
  SubscriptionDiagnostic._(this.code, this.operation, this.source)
    : message = _message(code, source);

  factory SubscriptionDiagnostic.fromCode(
    String? code, {
    required SubscriptionDiagnosticOperation operation,
    required SubscriptionDiagnosticSource source,
  }) {
    final safeCode = _safeCodes.contains(code)
        ? code!
        : 'SUBSCRIPTION_UNAVAILABLE';
    return SubscriptionDiagnostic._(safeCode, operation, source);
  }

  /// Only the public platform code is inspected, never the exception text.
  factory SubscriptionDiagnostic.fromError(
    Object? error, {
    required SubscriptionDiagnosticOperation operation,
    required SubscriptionDiagnosticSource source,
  }) => SubscriptionDiagnostic.fromCode(
    error is PlatformException ? error.code : null,
    operation: operation,
    source: source,
  );

  final String code;
  final String message;
  final SubscriptionDiagnosticOperation operation;
  final SubscriptionDiagnosticSource source;

  String get clipboardText =>
      'Pushok Flow — ошибка подписки\n'
      'Версия: $appVersionName (сборка $appVersionCode)\n'
      'Действие: $_operationLabel\n'
      'Источник: $_sourceLabel\n'
      'Код: $code\n$message';

  String get _operationLabel => switch (operation) {
    SubscriptionDiagnosticOperation.addSubscription => 'Добавление подписки',
    SubscriptionDiagnosticOperation.refreshServers => 'Обновление серверов',
    SubscriptionDiagnosticOperation.manualRefresh =>
      'Обновление серверов вручную',
    SubscriptionDiagnosticOperation.automaticRefresh =>
      'Автоматическое обновление серверов',
    SubscriptionDiagnosticOperation.readStatus => 'Чтение подписок',
    SubscriptionDiagnosticOperation.deleteSubscription => 'Удаление подписки',
    SubscriptionDiagnosticOperation.setAutomaticUpdates =>
      'Настройка автообновления',
  };

  String get _sourceLabel => switch (source) {
    SubscriptionDiagnosticSource.manualInput => 'Ввод вручную',
    SubscriptionDiagnosticSource.clipboard => 'Буфер обмена',
    SubscriptionDiagnosticSource.cameraQr => 'Камера QR',
    SubscriptionDiagnosticSource.imageQr => 'QR из фото',
    SubscriptionDiagnosticSource.externalLink => 'Внешняя ссылка',
    SubscriptionDiagnosticSource.savedSubscription => 'Сохранённая подписка',
    SubscriptionDiagnosticSource.file => 'Файл',
  };

  static const _safeCodes = {
    'SUBSCRIPTION_URL_INVALID',
    'SUBSCRIPTION_INVALID',
    'SUBSCRIPTION_TOO_LARGE',
    'SUBSCRIPTION_EMPTY',
    'SUBSCRIPTION_UNSUPPORTED',
    'SUBSCRIPTION_EXISTS',
    'SUBSCRIPTION_NOT_FOUND',
    'SUBSCRIPTION_CHANGED',
    'SUBSCRIPTION_LIMIT_REACHED',
    'SUBSCRIPTION_NETWORK_ERROR',
    'SUBSCRIPTION_TLS_ERROR',
    'SUBSCRIPTION_TIMEOUT',
    'SUBSCRIPTION_HTTP_ERROR',
    'SUBSCRIPTION_AUTH_REQUIRED',
    'SUBSCRIPTION_EXPIRED',
    'SUBSCRIPTION_REVOKED',
    'SUBSCRIPTION_REDIRECT_BLOCKED',
    'SUBSCRIPTION_BUSY',
    'SUBSCRIPTION_CANCELLED',
    'SUBSCRIPTION_STATE_UNAVAILABLE',
    'SUBSCRIPTION_INTERRUPTED',
    'SUBSCRIPTION_STORE_FAILED',
    'SUBSCRIPTION_UNAVAILABLE',
    // Legacy bridge aliases already have fixed subscription UI messages.
    'SUBSCRIPTION_DOWNLOAD_FAILED',
    'SUBSCRIPTION_ACCESS_DENIED',
    'PROFILE_NAME_INVALID',
    'PROFILE_LIMIT_REACHED',
    'PROFILE_STORE_UNAVAILABLE',
    'PROFILE_MANAGED',
    'VPN_ACTIVE',
    'VPN_BUSY',
    'VPN_STATE_UNAVAILABLE',
    'UNSUPPORTED_PROFILE',
    'UNSUPPORTED_TRANSPORT',
    'UNSUPPORTED_SECURITY',
    'UNSUPPORTED_PROFILE_OPTION',
    'INVALID_VLESS_CONFIG',
    'PROFILE_IMPORT_TOO_LARGE',
    'PROFILE_IMPORT_INVALID',
    'PROFILE_IMPORT_BUSY',
    'PROFILE_IMPORT_SOURCE_BUSY',
    'PROFILE_IMPORT_INTERRUPTED',
    'PROFILE_IMPORT_TIMEOUT',
    'PROFILE_IMPORT_UNAVAILABLE',
    'PROFILE_IMPORT_FAILED',
    'PROFILE_QR_CAMERA_DENIED',
    'PROFILE_QR_UNAVAILABLE',
    'PROFILE_QR_NOT_FOUND',
    'PROFILE_QR_MULTIPLE',
    'PROFILE_QR_IMAGE_TOO_LARGE',
    'PROFILE_TELEGRAM_LINK',
    'PROFILE_VMESS_LINK',
    'PROFILE_TROJAN_LINK',
    'PROFILE_SHADOWSOCKS_LINK',
    'SUBSCRIPTION_CLIPBOARD_EMPTY',
    'SUBSCRIPTION_CLIPBOARD_UNAVAILABLE',
  };

  static String _message(
    String code,
    SubscriptionDiagnosticSource source,
  ) => switch (code) {
    'SUBSCRIPTION_CLIPBOARD_EMPTY' => 'Буфер обмена пуст. Скопируйте HTTPS-ссылку подписки и повторите вставку.',
    'SUBSCRIPTION_CLIPBOARD_UNAVAILABLE' => 'Не удалось прочитать буфер обмена. Повторите вставку или введите HTTPS-ссылку подписки вручную.',
    'PROFILE_QR_CAMERA_DENIED' =>
      'Для сканирования нужен доступ к камере. Можно выбрать фото с QR-кодом.',
    'PROFILE_QR_UNAVAILABLE' =>
      'Импорт QR сейчас недоступен. Вставьте HTTPS-ссылку подписки.',
    'PROFILE_QR_NOT_FOUND' =>
      source == SubscriptionDiagnosticSource.imageQr
          ? 'На изображении не найден QR-код. Выберите другое фото.'
          : 'QR-код не найден. Повторите сканирование или выберите фото.',
    'PROFILE_QR_MULTIPLE' => 'Нужен один полный QR-код. Части составного кода и несколько кодов одновременно не поддерживаются.',
    'PROFILE_QR_IMAGE_TOO_LARGE' => 'Изображение слишком большое. Выберите уменьшенную копию или вставьте ссылку подписки.',
    'PROFILE_IMPORT_TOO_LARGE' =>
      'Данных слишком много. Для подписки нужна одна полная HTTPS-ссылка.',
    'PROFILE_IMPORT_INVALID' || 'UNSUPPORTED_PROFILE' => 'В импортированных данных не найдена HTTPS-ссылка подписки. Выберите ссылку подписки в панели или у провайдера.',
    'PROFILE_IMPORT_BUSY' =>
      'Импорт уже открыт. Завершите его и попробуйте ещё раз.',
    'PROFILE_IMPORT_SOURCE_BUSY' => 'Источник импорта пока занят. Попробуйте другой источник или вставьте HTTPS-ссылку подписки.',
    'PROFILE_IMPORT_INTERRUPTED' =>
      'Импорт прерван. Повторите его, когда Flow открыт.',
    'PROFILE_IMPORT_TIMEOUT' => 'Источник импорта не ответил вовремя. Повторите импорт или вставьте HTTPS-ссылку подписки.',
    'PROFILE_IMPORT_UNAVAILABLE' =>
      'Импорт сейчас недоступен. Вставьте HTTPS-ссылку подписки.',
    'PROFILE_IMPORT_FAILED' => 'Не удалось прочитать данные для подписки. Повторите импорт или вставьте HTTPS-ссылку.',
    'PROFILE_TELEGRAM_LINK' => 'Это ссылка прокси Telegram. Для подписки Flow нужна полная HTTPS-ссылка подписки.',
    'PROFILE_VMESS_LINK' ||
    'PROFILE_TROJAN_LINK' ||
    'PROFILE_SHADOWSOCKS_LINK' => 'Вместо ссылки подписки получена ссылка отдельного подключения. Нужна полная HTTPS-ссылка подписки.',
    // Build a new exception from the allowlisted code only. This preserves the
    // existing fixed subscription messages without exposing a caller's error.
    _ => subscriptionErrorMessage(PlatformException(code: code)),
  };
}
