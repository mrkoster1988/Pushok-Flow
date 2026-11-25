import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/subscription_diagnostics.dart';
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

SubscriptionStatus _failureStatus({String code = 'SUBSCRIPTION_NETWORK_ERROR'}) =>
    SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [{
        'id': _id, 'name': 'PRIVATE_PROVIDER_NAME', 'host': 'example.invalid',
        'profileCount': 2, 'updatedAt': 1795377600000,
      }],
      'refreshErrors': {_id: code},
    });

SubscriptionStatus _wireGuardStatus({String state = 'active',
    int expiresAt = 1795464000000, bool busy = false}) =>
    SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true, 'busy': busy,
      'subscriptions': [{
        'id': _id, 'name': 'Мой WireGuard', 'host': 'example.invalid',
        'format': 'wireguard-v1', 'state': state,
        'profileCount': state == 'active' ? 2 : 0,
        'updatedAt': 1795377600000, 'expiresAt': expiresAt,
        'skippedProfileCount': 0, 'usedBytes': null, 'totalBytes': null,
      }],
    });

void _clipboard(Future<Object?> Function(MethodCall call) handler) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

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
  for (final state in ['active', 'expired', 'revoked']) {
    testWidgets('WireGuard $state is visible metadata with refresh and delete, not a failed refresh',
        (tester) async {
      var refreshes = 0;
      var deletes = 0;
      await _pump(tester, SubscriptionsCard(status: _wireGuardStatus(state: state),
        now: DateTime.fromMillisecondsSinceEpoch(1795377600000),
        mutationsEnabled: true,
        onRefresh: (_) { refreshes++; }, onDelete: (_) { deletes++; }));
      final access = tester.widget<Text>(find.byKey(const ValueKey('subscription_access_state_$_id')));
      expect(access.data, contains(switch (state) {
        'active' => 'Доступ активен.',
        'expired' => 'Срок доступа истёк.',
        _ => 'Доступ отозван сервисом.',
      }));
      expect(access.style!.color, state == 'active' ? PushokPalette.mint : PushokPalette.orange);
      expect(find.text('example.invalid · Сохранено серверов: ${state == 'active' ? 2 : 0}'),
        findsOneWidget);
      final expiry = tester.widget<Text>(find.byKey(const ValueKey('subscription_expiry_$_id'))).data!;
      expect(expiry, startsWith('Срок доступа: до '));
      expect(expiry, matches(RegExp(r'\d{2}:\d{2}')));
      expect(find.textContaining('Подписка проверена:'), findsOneWidget);
      expect(find.byKey(const Key('subscriptions_refresh_warning')), findsNothing);
      expect(find.byKey(const ValueKey('subscription_refresh_error_$_id')), findsNothing);
      expect(find.text('Скопировать ошибку'), findsNothing);
      expect(refreshes, 0);
      expect(deletes, 0);
      await _tap(tester, 'refresh_subscription_$_id');
      await _tap(tester, 'delete_subscription_$_id');
      expect(refreshes, 1);
      expect(deletes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Locally expired WireGuard keeps the stored count without advertising available access',
      (tester) async {
    final status = _wireGuardStatus(expiresAt: 1795291200000);
    await _pump(tester, SubscriptionsCard(status: status,
      now: DateTime.fromMillisecondsSinceEpoch(1795377600000)));
    expect(status.subscriptions.single.state, SubscriptionAccessState.active);
    expect(status.subscriptions.single.profileCount, 2);
    expect(find.text('example.invalid · Сохранено серверов: 2'), findsOneWidget);
    expect(find.text('Срок доступа истёк. Новые подключения недоступны.'), findsOneWidget);
    expect(find.text('Доступ активен.'), findsNothing);
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsNothing);
    expect(find.textContaining('туннель отключён'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WireGuard deadline changes the open card without downloading or changing its cached metadata',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var now = DateTime.fromMillisecondsSinceEpoch(1795377600000);
    final expiry = now.add(const Duration(seconds: 2));
    final status = _wireGuardStatus(expiresAt: expiry.millisecondsSinceEpoch);
    var refreshes = 0;
    await _pump(tester, SubscriptionsCard(status: status, clock: () => now,
      mutationsEnabled: true, onRefresh: (_) { refreshes++; }));
    expect(find.text('Доступ активен.'), findsOneWidget);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Доступ активен.'), findsOneWidget);
    now = expiry;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Срок доступа истёк. Новые подключения недоступны.'), findsOneWidget);
    expect(status.subscriptions.single.state, SubscriptionAccessState.active);
    expect(status.subscriptions.single.profileCount, 2);
    expect(refreshes, 0);
    await tester.pump(const Duration(hours: 1));
    expect(refreshes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WireGuard deadlines pause in background and resume from the current clock',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    var now = DateTime.fromMillisecondsSinceEpoch(1795377600000);
    final expiry = now.add(const Duration(seconds: 10));
    var refreshes = 0;
    await _pump(tester, SubscriptionsCard(
      status: _wireGuardStatus(expiresAt: expiry.millisecondsSinceEpoch), clock: () => now,
      onRefresh: (_) { refreshes++; }));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    now = expiry.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 11));
    expect(refreshes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Срок доступа истёк. Новые подключения недоступны.'), findsOneWidget);
    expect(refreshes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A replaced or disposed WireGuard deadline cannot override the new provider state',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var now = DateTime.fromMillisecondsSinceEpoch(1795377600000);
    final expiry = now.add(const Duration(seconds: 10));
    await _pump(tester, SubscriptionsCard(
      status: _wireGuardStatus(expiresAt: expiry.millisecondsSinceEpoch), clock: () => now));
    await _pump(tester, SubscriptionsCard(
      status: _wireGuardStatus(state: 'revoked', expiresAt: expiry.millisecondsSinceEpoch),
      clock: () => now));
    now = expiry;
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Доступ отозван сервисом. Новые подключения недоступны.'), findsOneWidget);
    expect(find.textContaining('Срок доступа истёк.'), findsNothing);
    await _pump(tester, SubscriptionsCard(status: _wireGuardStatus(
      expiresAt: now.add(const Duration(seconds: 10)).millisecondsSinceEpoch), clock: () => now));
    await tester.pumpWidget(const SizedBox.shrink());
    now = now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('WireGuard inactive access respects the unchanged tunnel and busy mutation gates',
      (tester) async {
    for (final gate in [(busy: true, enabled: true), (busy: false, enabled: false)]) {
      await _pump(tester, SubscriptionsCard(status: _wireGuardStatus(state: 'revoked', busy: gate.busy),
        mutationsEnabled: gate.enabled, onRefresh: (_) {}, onDelete: (_) {},
        onOpenAccount: () {}));
      for (final key in ['refresh_subscription_$_id', 'delete_subscription_$_id']) {
        expect(tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed, isNull);
      }
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('manage_pushok_subscription'))).onPressed,
        isNotNull);
    }
  });

  testWidgets('WireGuard status and its actions fit a narrow phone with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var refreshes = 0;
    await _pump(tester, SubscriptionsCard(status: _wireGuardStatus(state: 'expired'),
      mutationsEnabled: true, onRefresh: (_) { refreshes++; }), textScale: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('subscription_access_state_$_id')));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('subscription_access_state_$_id'))).width,
      lessThanOrEqualTo(360));
    await _tap(tester, 'refresh_subscription_$_id');
    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('Subscription diagnostics appear only with their current error', (tester) async {
    final diagnostic = SubscriptionDiagnostic.fromCode('SUBSCRIPTION_NETWORK_ERROR',
      operation: SubscriptionDiagnosticOperation.manualRefresh,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await _pump(tester, SubscriptionsCard(status: _status(), errorDiagnostic: diagnostic,
      refreshDiagnostics: {_id: diagnostic}));
    expect(find.text('Скопировать ошибку'), findsNothing);
    await _pump(tester, SubscriptionsCard(status: _status(), error: 'Безопасная ошибка.'));
    expect(find.byKey(const Key('copy_subscriptions_error')), findsNothing);
    expect(writes, isEmpty);
  });

  testWidgets('Each failed subscription copies its own provided operation without provider details',
      (tester) async {
    final manual = SubscriptionDiagnostic.fromCode('SUBSCRIPTION_TLS_ERROR',
      operation: SubscriptionDiagnosticOperation.manualRefresh,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final automatic = SubscriptionDiagnostic.fromCode('SUBSCRIPTION_AUTH_REQUIRED',
      operation: SubscriptionDiagnosticOperation.automaticRefresh,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    final status = SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true,
      'subscriptions': [
        {'id': _id, 'name': 'PRIVATE_FIRST_NAME', 'host': 'first.invalid',
          'profileCount': 2, 'updatedAt': 1795377600000},
        {'id': _otherId, 'name': 'PRIVATE_SECOND_NAME', 'host': 'second.invalid',
          'profileCount': 3, 'updatedAt': 1795377600000},
      ],
      'refreshErrors': {_id: manual.code, _otherId: automatic.code},
    });
    // Copying an error is read-only and remains possible while connection changes are blocked.
    await _pump(tester, SubscriptionsCard(status: status, mutationsEnabled: false,
      refreshDiagnostics: {_id: manual, _otherId: automatic}));
    expect(writes, isEmpty);
    await _tap(tester, 'copy_subscription_refresh_error_$_id');
    await _tap(tester, 'copy_subscription_refresh_error_$_otherId');
    expect(writes, [manual.clipboardText, automatic.clipboardText]);
    for (final report in writes) {
      for (final value in ['PRIVATE_', '.invalid', _id, _otherId]) {
        expect(report, isNot(contains(value)));
      }
    }
    expect(find.text('Отчёт скопирован.'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Restored or mismatched refresh diagnostics use the current code and generic operation',
      (tester) async {
    final stale = SubscriptionDiagnostic.fromCode('SUBSCRIPTION_AUTH_REQUIRED',
      operation: SubscriptionDiagnosticOperation.automaticRefresh,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final expected = SubscriptionDiagnostic.fromCode('SUBSCRIPTION_NETWORK_ERROR',
      operation: SubscriptionDiagnosticOperation.refreshServers,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    for (final diagnostics in [<String, SubscriptionDiagnostic>{}, {_id: stale}]) {
      await _pump(tester, SubscriptionsCard(status: _failureStatus(), refreshDiagnostics: diagnostics));
      await _tap(tester, 'copy_subscription_refresh_error_$_id');
      expect(writes.last, expected.clipboardText);
    }
  });

  testWidgets('An aggregate error exports only its supplied safe diagnostic', (tester) async {
    final diagnostic = SubscriptionDiagnostic.fromError(
      PlatformException(code: 'PRIVATE_UNKNOWN_CODE', message: _url, details: 'PRIVATE_DETAILS'),
      operation: SubscriptionDiagnosticOperation.readStatus,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await _pump(tester, SubscriptionsCard(error: 'Не удалось прочитать подписки.',
      errorDiagnostic: diagnostic));
    expect(writes, isEmpty);
    await _tap(tester, 'copy_subscriptions_error');
    expect(writes.single, diagnostic.clipboardText);
    expect(writes.single, isNot(contains('PRIVATE_')));
    expect(writes.single, isNot(contains('example.invalid')));
    expect(find.byKey(const Key('subscriptions_error_copy_notice')), findsOneWidget);
  });

  testWidgets('Live subscription guards reject queued copy actions before the next rebuild',
      (tester) async {
    final diagnostic = SubscriptionDiagnostic.fromCode('SUBSCRIPTION_NETWORK_ERROR',
      operation: SubscriptionDiagnosticOperation.manualRefresh,
      source: SubscriptionDiagnosticSource.savedSubscription);
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    var current = true;
    await _pump(tester, SubscriptionsCard(status: _failureStatus(),
      error: 'Не удалось обновить подписку.', errorDiagnostic: diagnostic,
      refreshDiagnostics: {_id: diagnostic},
      isCurrentErrorDiagnostic: (value) => current && identical(value, diagnostic),
      isCurrentRefreshDiagnostic: (id, value) => current && id == _id && identical(value, diagnostic)));
    final globalCopy = tester.widget<TextButton>(find.byKey(
      const Key('copy_subscriptions_error'))).onPressed!;
    final providerCopy = tester.widget<TextButton>(find.byKey(
      const ValueKey('copy_subscription_refresh_error_$_id'))).onPressed!;
    // A parent starts a new operation synchronously, before Flutter rebuilds this card.
    current = false;
    globalCopy();
    providerCopy();
    await tester.pump();
    expect(writes, isEmpty);
    expect(find.text('Отчёт скопирован.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Refreshing removes stale copy feedback and late clipboard completion cannot restore it',
      (tester) async {
    final pendingCopy = Completer<void>();
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add((call.arguments as Map)['text'] as String);
        await pendingCopy.future;
      }
      return null;
    });
    late StateSetter update;
    var status = _failureStatus();
    var busy = false;
    await _pump(tester, StatefulBuilder(builder: (context, state) {
      update = state;
      return SubscriptionsCard(status: status, busy: busy);
    }));
    final copyKey = const ValueKey('copy_subscription_refresh_error_$_id');
    final oldCopy = tester.widget<TextButton>(find.byKey(copyKey)).onPressed!;
    await tester.ensureVisible(find.byKey(copyKey));
    await tester.tap(find.byKey(copyKey));
    await tester.pump();
    expect(writes.length, 1);
    update(() => busy = true);
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(copyKey)).onPressed, isNull);
    oldCopy();
    expect(writes.length, 1);
    update(() { busy = false; status = _status(); });
    await tester.pump();
    pendingCopy.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(copyKey), findsNothing);
    expect(find.text('Отчёт скопирован.'), findsNothing);
    update(() => status = _failureStatus());
    await tester.pumpAndSettle();
    oldCopy();
    expect(writes.length, 1);
    expect(tester.widget<TextButton>(find.byKey(copyKey)).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A covered subscription card cannot copy from a queued action', (tester) async {
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await _pump(tester, SubscriptionsCard(status: _failureStatus()));
    final oldCopy = tester.widget<TextButton>(find.byKey(
      const ValueKey('copy_subscription_refresh_error_$_id'))).onPressed!;
    await _tap(tester, 'subscriptions_info');
    oldCopy();
    await tester.pump();
    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Subscription error copy fits a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final writes = <String>[];
    _clipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await _pump(tester, SubscriptionsCard(status: _failureStatus()), textScale: 2);
    await _tap(tester, 'copy_subscription_refresh_error_$_id');
    expect(writes.length, 1);
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
    expect(find.textContaining('Для подписки откройте HTTPS-ссылку вашего провайдера'), findsOneWidget);
    expect(find.textContaining('Для управления доступом нужна подписка в формате Flow'), findsOneWidget);
    expect(find.textContaining('Flow не отключает уже работающий туннель автоматически'), findsOneWidget);

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
