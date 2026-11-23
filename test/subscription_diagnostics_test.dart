import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/models/app_version.dart';
import 'package:pushok_flow/platform/subscription_diagnostics.dart';

const _privateUrl = 'https://private.example.invalid/sub/SECRET_TOKEN';
const _privateName = 'PRIVATE_SUBSCRIPTION_NAME';
const _privateId = '20000000-0000-4000-8000-000000000002';
const _privateConfig = '[Interface]\nPrivateKey = PRIVATE_WIREGUARD_KEY';

SubscriptionDiagnostic _report(Object? error) =>
    SubscriptionDiagnostic.fromError(
      error,
      operation: SubscriptionDiagnosticOperation.manualRefresh,
      source: SubscriptionDiagnosticSource.savedSubscription,
    );

class _UnreadablePlatformException extends PlatformException {
  _UnreadablePlatformException() : super(code: 'SUBSCRIPTION_AUTH_REQUIRED');

  @override
  String? get message => throw StateError('Native messages must not be read');
  @override
  Object? get details => throw StateError('Native details must not be read');
  @override
  String? get stacktrace => throw StateError('Native stacks must not be read');
  @override
  String toString() => throw StateError('Native errors must not be formatted');
}

class _UnprintableFailure implements Exception {
  @override
  String toString() => throw StateError('Unknown errors must not be formatted');
}

void main() {
  test('Known failures export a fixed snapshot and never native private context', () {
    final details = <String, Object?>{
      'url': _privateUrl,
      'name': _privateName,
      'host': 'private.example.invalid',
      'id': _privateId,
      'configuration': _privateConfig,
      'nestedError': _UnprintableFailure(),
    };
    final report = _report(
      PlatformException(
        code: 'SUBSCRIPTION_NETWORK_ERROR',
        message: _privateUrl,
        details: details,
        stacktrace: _privateConfig,
      ),
    );
    final expected =
        'Pushok Flow — ошибка подписки\n'
        'Версия: $appVersionName (сборка $appVersionCode)\n'
        'Действие: Обновление серверов вручную\n'
        'Источник: Сохранённая подписка\n'
        'Код: SUBSCRIPTION_NETWORK_ERROR\n'
        'Не удалось загрузить подписку. Сохранённые серверы остаются на устройстве.';
    expect(report.clipboardText, expected);
    details.clear();
    details['message'] = 'REPLACEMENT_PRIVATE_DATA';
    expect(report.clipboardText, expected);
    expect(report.operation, SubscriptionDiagnosticOperation.manualRefresh);
    expect(report.source, SubscriptionDiagnosticSource.savedSubscription);
  });

  test(
    'Only exact allowlisted codes survive, including well-formed hostile codes',
    () {
      final generic = _report(null).clipboardText;
      for (final code in <String?>[
        null,
        '',
        'SECRET_TOKEN',
        _privateUrl,
        'subscription_network_error',
        ' SUBSCRIPTION_NETWORK_ERROR',
        'SUBSCRIPTION_NETWORK_ERROR ',
        'SUBSCRIPTION_NETWORK_ERROR\n$_privateUrl',
        'SUBSCRIPTION_NETWORK_ERROR\u0000',
        'SUBSCRIPTION_NETWORK_ERROR\u200b',
        '\u202eSUBSCRIPTION_NETWORK_ERROR',
        'SUBSCRIPTION_NETWORK_ERROR?token=SECRET_TOKEN',
        'SUBSCRIPTION_FUTURE_FAILURE',
      ]) {
        final report = SubscriptionDiagnostic.fromCode(
          code,
          operation: SubscriptionDiagnosticOperation.manualRefresh,
          source: SubscriptionDiagnosticSource.savedSubscription,
        );
        expect(report.code, 'SUBSCRIPTION_UNAVAILABLE');
        expect(report.clipboardText, generic);
      }
    },
  );

  test(
    'Platform message, details, stack trace and formatting are never inspected',
    () {
      final report = _report(_UnreadablePlatformException());
      expect(report.code, 'SUBSCRIPTION_AUTH_REQUIRED');
      expect(
        report.message,
        'Сервис не предоставил список серверов. Проверьте подписку в магазине.',
      );
      expect(
        report.clipboardText,
        contains('Код: SUBSCRIPTION_AUTH_REQUIRED\n'),
      );
    },
  );

  test('Unknown exceptions are generic without formatting or reading their payload', () {
    final generic = _report(null).clipboardText;
    for (final error in <Object?>[
      _UnprintableFailure(),
      FormatException(_privateUrl, _privateConfig),
      StateError(_privateName),
      MissingPluginException(_privateUrl),
      _privateConfig,
      {'code': 'SUBSCRIPTION_NETWORK_ERROR', 'url': _privateUrl},
    ]) {
      expect(_report(error).clipboardText, generic);
    }
  });

  test(
    'Source provenance uses fixed labels for every supported input route',
    () {
      const sources = {
        SubscriptionDiagnosticSource.manualInput: 'Ввод вручную',
        SubscriptionDiagnosticSource.clipboard: 'Буфер обмена',
        SubscriptionDiagnosticSource.cameraQr: 'Камера QR',
        SubscriptionDiagnosticSource.imageQr: 'QR из фото',
        SubscriptionDiagnosticSource.externalLink: 'Внешняя ссылка',
        SubscriptionDiagnosticSource.savedSubscription: 'Сохранённая подписка',
        SubscriptionDiagnosticSource.file: 'Файл',
      };
      expect(
        sources.keys,
        unorderedEquals(SubscriptionDiagnosticSource.values),
      );
      for (final entry in sources.entries) {
        final report = SubscriptionDiagnostic.fromCode(
          'SUBSCRIPTION_URL_INVALID',
          operation: SubscriptionDiagnosticOperation.addSubscription,
          source: entry.key,
        );
        expect(report.clipboardText, contains('\nИсточник: ${entry.value}\n'));
        expect(report.clipboardText.split('\n'), hasLength(6));
        expect(report.code, 'SUBSCRIPTION_URL_INVALID');
      }
    },
  );

  test(
    'Restored failures do not invent a manual or automatic refresh origin',
    () {
      const operations = {
        SubscriptionDiagnosticOperation.addSubscription: 'Добавление подписки',
        SubscriptionDiagnosticOperation.refreshServers: 'Обновление серверов',
        SubscriptionDiagnosticOperation.manualRefresh:
            'Обновление серверов вручную',
        SubscriptionDiagnosticOperation.automaticRefresh:
            'Автоматическое обновление серверов',
        SubscriptionDiagnosticOperation.readStatus: 'Чтение подписок',
        SubscriptionDiagnosticOperation.deleteSubscription: 'Удаление подписки',
        SubscriptionDiagnosticOperation.setAutomaticUpdates:
            'Настройка автообновления',
      };
      expect(
        operations.keys,
        unorderedEquals(SubscriptionDiagnosticOperation.values),
      );
      for (final entry in operations.entries) {
        final report = SubscriptionDiagnostic.fromCode(
          'SUBSCRIPTION_STATE_UNAVAILABLE',
          operation: entry.key,
          source: SubscriptionDiagnosticSource.savedSubscription,
        );
        expect(report.clipboardText, contains('\nДействие: ${entry.value}\n'));
      }
      final restored = SubscriptionDiagnostic.fromCode(
        'SUBSCRIPTION_NETWORK_ERROR',
        operation: SubscriptionDiagnosticOperation.refreshServers,
        source: SubscriptionDiagnosticSource.savedSubscription,
      );
      expect(restored.clipboardText, isNot(contains('вручную')));
      expect(restored.clipboardText, isNot(contains('Автоматическое')));
    },
  );

  test('QR and clipboard failures stay useful without imported payloads', () {
    final image = SubscriptionDiagnostic.fromError(
      PlatformException(
        code: 'PROFILE_QR_NOT_FOUND',
        message: _privateUrl,
        details: _privateConfig,
      ),
      operation: SubscriptionDiagnosticOperation.addSubscription,
      source: SubscriptionDiagnosticSource.imageQr,
    );
    final camera = SubscriptionDiagnostic.fromError(
      PlatformException(
        code: 'PROFILE_QR_NOT_FOUND',
        message: _privateUrl,
        details: _privateConfig,
      ),
      operation: SubscriptionDiagnosticOperation.addSubscription,
      source: SubscriptionDiagnosticSource.cameraQr,
    );
    expect(
      image.message,
      'На изображении не найден QR-код. Выберите другое фото.',
    );
    expect(
      camera.message,
      'QR-код не найден. Повторите сканирование или выберите фото.',
    );
    for (final code in [
      'SUBSCRIPTION_CLIPBOARD_EMPTY',
      'SUBSCRIPTION_CLIPBOARD_UNAVAILABLE',
    ]) {
      final report = SubscriptionDiagnostic.fromCode(
        code,
        operation: SubscriptionDiagnosticOperation.addSubscription,
        source: SubscriptionDiagnosticSource.clipboard,
      );
      expect(report.code, code);
      expect(report.message.toLowerCase(), contains('буфер обмена'));
      expect(report.message, contains('HTTPS-ссылку подписки'));
    }
  });

  test('Equivalent failures have deterministic text but distinct snapshot identities', () {
    final first = _report(
      PlatformException(
        code: 'SUBSCRIPTION_TLS_ERROR',
        message: _privateUrl,
        details: _privateConfig,
      ),
    );
    final second = _report(
      PlatformException(
        code: 'SUBSCRIPTION_TLS_ERROR',
        message: _privateName,
        details: _privateId,
      ),
    );
    expect(first.clipboardText, second.clipboardText);
    expect(identical(first, second), isFalse);
    expect(first.clipboardText.split('\n'), hasLength(6));
    expect(first.clipboardText, isNot(contains(_privateUrl)));
    expect(first.clipboardText, isNot(contains(_privateName)));
    expect(first.clipboardText, isNot(contains(_privateId)));
    expect(first.clipboardText, isNot(contains(_privateConfig)));
  });
}
