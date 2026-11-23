import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/subscriptions.dart';
import 'package:pushok_flow/ui/subscription_editor.dart';
import 'package:pushok_flow/ui/subscriptions_card.dart';

const _id = '10000000-0000-4000-8000-000000000001';
const _otherId = '10000000-0000-4000-8000-000000000002';
const _url = 'https://example.invalid/sub/PRIVATE_TOKEN';
SubscriptionStatus _status({int? expiresAt, bool busy = false, int? skippedProfileCount}) =>
    SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true, 'busy': busy,
      'subscriptions': [{
        'id': _id, 'name': 'Магазин', 'host': 'example.invalid',
        'profileCount': 2, 'updatedAt': 1795377600000,
        if (skippedProfileCount != null) 'skippedProfileCount': skippedProfileCount,
        'expiresAt': expiresAt, 'usedBytes': null, 'totalBytes': null,
      }],
    });

Future<void> _pump(WidgetTester tester, Widget child, {double textScale = 1}) async {
  await tester.pumpWidget(MaterialApp(theme: buildPushokTheme(),
    builder: (context, content) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: content!),
    home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Unknown expiry does not claim paid active access', (tester) async {
    await _pump(tester, SubscriptionsCard(status: _status(), mutationsEnabled: true,
      onAdd: () {}, onOpenAccount: () {}));
    expect(find.text('Сервис не передал срок подписки.'), findsOneWidget);
    expect(find.textContaining('Активна'), findsNothing);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    expect(find.text('Кабинет MTProxy'), findsOneWidget);
    expect(find.text('Управлять подпиской'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Expired metadata is attributed to provider and refresh stays possible', (tester) async {
    var refreshes = 0;
    await _pump(tester, SubscriptionsCard(status: _status(expiresAt: 1795291200000),
      now: DateTime.fromMillisecondsSinceEpoch(1795377600000), mutationsEnabled: true,
      onRefresh: (_) => refreshes++));
    expect(find.textContaining('По данным сервиса срок истёк'), findsOneWidget);
    await _tap(tester, 'refresh_subscription_$_id');
    expect(refreshes, 1);
  });

  testWidgets('Mixed subscription shows its skipped count without marking saved servers as failed',
      (tester) async {
    var refreshes = 0;
    final status = SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [
        {'id': _id, 'name': 'Магазин', 'host': 'example.invalid',
          'profileCount': 2, 'skippedProfileCount': 3, 'updatedAt': 1795377600000},
        {'id': _otherId, 'name': 'Другой магазин', 'host': 'other.invalid',
          'profileCount': 4, 'updatedAt': 1795464000000},
      ],
    });
    await _pump(tester, SubscriptionsCard(status: status, mutationsEnabled: true,
      onRefresh: (_) => refreshes++));
    final warning = find.byKey(const ValueKey('subscription_skipped_profiles_$_id'));
    expect(warning, findsOneWidget);
    expect(tester.widget<Text>(warning).data,
      'Несовместимых записей пропущено: 3. Доступные серверы добавлены.');
    expect(tester.widget<Text>(warning).style!.color, PushokPalette.orange);
    expect(find.byKey(const ValueKey('subscription_skipped_profiles_$_otherId')), findsNothing);
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsNothing);
    expect(find.text('example.invalid · Серверов: 2'), findsOneWidget);
    expect(find.text('other.invalid · Серверов: 4'), findsOneWidget);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    await _tap(tester, 'refresh_subscription_$_id');
    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Legacy and fully compatible subscriptions have no skipped-entry warning',
      (tester) async {
    for (final skipped in <int?>[null, 0]) {
      await _pump(tester, SubscriptionsCard(status: _status(skippedProfileCount: skipped)));
      expect(find.byKey(const ValueKey('subscription_skipped_profiles_$_id')), findsNothing);
      expect(find.textContaining('Несовместимых записей'), findsNothing);
      expect(find.text('example.invalid · Серверов: 2'), findsOneWidget);
    }
  });

  testWidgets('Mixed-feed guidance explains compatibility and preserving previous servers',
      (tester) async {
    await _pump(tester, SubscriptionsCard(status: _status()));
    await _tap(tester, 'subscriptions_info');
    expect(find.textContaining('Из смешанной подписки добавляются совместимые подключения VLESS'),
      findsOneWidget);
    expect(find.textContaining('Записи других протоколов и неподдерживаемых вариантов подключения'),
      findsOneWidget);
    expect(find.textContaining('Если ответ повреждён или в нём нет совместимых серверов, прежний список сохраняется.'),
      findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Skipped count remains readable on a narrow phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final status = SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [{
        'id': _id, 'name': 'Подписка с длинным названием для проверки крупного текста',
        'host': 'very-long-subscription-provider-address.example.invalid',
        'profileCount': 2, 'skippedProfileCount': 200, 'updatedAt': 1795377600000,
      }],
    });
    await _pump(tester, SubscriptionsCard(status: status), textScale: 2);
    final warning = find.byKey(const ValueKey('subscription_skipped_profiles_$_id'));
    await tester.ensureVisible(warning);
    await tester.pumpAndSettle();
    expect(warning, findsOneWidget);
    expect(tester.widget<Text>(warning).data, contains('пропущено: 200'));
    expect(tester.getSize(warning).width, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Native busy and connected states block changes but keep account access', (tester) async {
    for (final state in [(busy: true, enabled: true), (busy: false, enabled: false)]) {
      await _pump(tester, SubscriptionsCard(status: _status(busy: state.busy),
        mutationsEnabled: state.enabled, onAdd: () {}, onRefresh: (_) {}, onDelete: (_) {},
        onOpenAccount: () {}));
      for (final key in ['add_subscription', 'refresh_subscription_$_id',
        'delete_subscription_$_id']) {
        expect(tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed, isNull);
      }
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('manage_pushok_subscription'))).onPressed,
        isNotNull);
    }
  });

  testWidgets('Partial refresh keeps healthy metadata and retries only the failed subscription',
      (tester) async {
    final refreshed = <String>[];
    final status = SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [
        {'id': _id, 'name': 'Магазин', 'host': 'example.invalid',
          'profileCount': 2, 'updatedAt': 1795377600000},
        {'id': _otherId, 'name': 'Другой магазин', 'host': 'other.invalid',
          'profileCount': 4, 'updatedAt': 1795464000000},
      ],
      'refreshErrors': {_id: 'SUBSCRIPTION_NETWORK_ERROR'},
    });
    await _pump(tester, SubscriptionsCard(status: status, mutationsEnabled: true,
      onRefresh: (entry) => refreshed.add(entry.id)));
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_id')), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_otherId')), findsNothing);
    expect(find.text('other.invalid · Серверов: 4'), findsOneWidget);
    expect(find.text('Серверы обновлены: 23.11.2026'), findsOneWidget);
    expect(find.text('Повторить обновление'), findsOneWidget);
    expect(find.textContaining('SUBSCRIPTION_NETWORK_ERROR'), findsNothing);
    await _tap(tester, 'refresh_subscription_$_id');
    expect(refreshed, [_id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('All failed providers remain visible while retry respects connection guards',
      (tester) async {
    final status = SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [
        {'id': _id, 'name': 'Магазин', 'host': 'example.invalid',
          'profileCount': 2, 'updatedAt': 1795377600000},
      ],
      'refreshErrors': {_id: 'SUBSCRIPTION_AUTH_REQUIRED'},
    });
    await _pump(tester, SubscriptionsCard(status: status,
      mutationsEnabled: false, onRefresh: (_) => fail('Connected Flow cannot refresh')));
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsOneWidget);
    expect(find.textContaining('Сервис не предоставил список серверов'), findsOneWidget);
    expect(find.text('example.invalid · Серверов: 2'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(
      const ValueKey('refresh_subscription_$_id'))).onPressed, isNull);
  });

  testWidgets('TLS provider failure shows a certificate hint and preserves healthy servers',
      (tester) async {
    final refreshed = <String>[];
    final status = SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [
        {'id': _id, 'name': 'Магазин', 'host': 'example.invalid',
          'profileCount': 2, 'updatedAt': 1795377600000},
        {'id': _otherId, 'name': 'Другой магазин', 'host': 'other.invalid',
          'profileCount': 4, 'updatedAt': 1795464000000},
      ],
      'refreshErrors': {_id: 'SUBSCRIPTION_TLS_ERROR'},
    });
    await _pump(tester, SubscriptionsCard(status: status, mutationsEnabled: true,
      onRefresh: (entry) => refreshed.add(entry.id)));
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_id')), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_otherId')), findsNothing);
    expect(find.textContaining('защищённое соединение'), findsOneWidget);
    expect(find.textContaining('HTTPS-адрес'), findsOneWidget);
    expect(find.textContaining('сертификат'), findsOneWidget);
    expect(find.text('example.invalid · Серверов: 2'), findsOneWidget);
    expect(find.text('other.invalid · Серверов: 4'), findsOneWidget);
    expect(find.textContaining('SUBSCRIPTION_TLS_ERROR'), findsNothing);
    await _tap(tester, 'refresh_subscription_$_id');
    expect(refreshed, [_id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A received URL stays masked and only explicit save imports', (tester) async {
    var saves = 0;
    await _pump(tester, SubscriptionEditor(draft: const SubscriptionDraft(url: _url),
      onSave: (url, name) async {
        expect(url, _url);
        saves++;
        throw PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR', message: 'PRIVATE_FAILURE');
      }));
    expect(saves, 0);
    final field = find.byKey(const Key('subscription_url'));
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(find.text('Источник серверов: example.invalid'), findsOneWidget);
    await _tap(tester, 'save_subscription');
    expect(saves, 1);
    expect(tester.widget<TextField>(field).controller!.text, _url);
    expect(find.textContaining('Сохранённые серверы'), findsOneWidget);
    expect(find.textContaining('PRIVATE_FAILURE'), findsNothing);
  });

  testWidgets('TLS import failure keeps the masked draft and allows an explicit retry',
      (tester) async {
    var saves = 0;
    var completions = 0;
    await _pump(tester, StatefulBuilder(builder: (context, update) => completions > 0
      ? const Text('Подписка добавлена')
      : SubscriptionEditor(draft: const SubscriptionDraft(url: _url),
          onCompleted: () => update(() => completions++),
          onSave: (url, name) async {
            expect(url, _url);
            saves++;
            if (saves == 1) {
              throw PlatformException(code: 'SUBSCRIPTION_TLS_ERROR',
                message: 'PRIVATE_CERTIFICATE', details: _url);
            }
          })));
    final field = find.byKey(const Key('subscription_url'));
    expect(saves, 0);
    await _tap(tester, 'save_subscription');
    expect(saves, 1);
    expect(completions, 0);
    expect(tester.widget<TextField>(field).controller!.text, _url);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(find.textContaining('защищённое соединение'), findsOneWidget);
    expect(find.textContaining('HTTPS-адрес'), findsOneWidget);
    expect(find.textContaining('сертификат'), findsOneWidget);
    expect(find.textContaining('PRIVATE_CERTIFICATE'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('subscription_editor_error')))
      .data, isNot(contains('PRIVATE_TOKEN')));
    expect(tester.widget<FilledButton>(find.byKey(const Key('save_subscription')))
      .onPressed, isNotNull);
    await _tap(tester, 'save_subscription');
    expect(saves, 2);
    expect(completions, 1);
    expect(find.text('Подписка добавлена'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Revealed link hides again when app loses focus', (tester) async {
    await _pump(tester, SubscriptionEditor(draft: const SubscriptionDraft(url: _url),
      onSave: (_, _) async {}));
    await _tap(tester, 'toggle_subscription_url_visibility');
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isTrue);
  });
}
