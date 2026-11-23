import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';
import 'package:pushok_flow/ui/subscription_editor.dart';
import 'package:pushok_flow/ui/wireguard_profile_editor.dart';

const _manualId = '10000000-0000-4000-8000-000000000001';
const _managedId = '10000000-0000-4000-8000-000000000002';
const _subscriptionId = '10000000-0000-4000-8000-000000000003';
const _otherSubscriptionId = '10000000-0000-4000-8000-000000000004';
const _privateUrl = 'https://example.invalid/sub/PRIVATE_TOKEN';
const _manualConfig = '[Interface]\nPrivateKey = UI_ONLY\nAddress = 10.0.0.2/32\n'
    '[Peer]\nPublicKey = UI_ONLY_PEER\n';

class _Bridge {
  bool connected = false;
  bool imported = false;
  bool protectionAvailable = true;
  bool automaticUpdatesEnabled = true;
  bool subscriptionsBusy = false;
  bool secondImported = false;
  int secondProfileCount = 1;
  int secondUpdatedAt = 1795377600000;
  String? subscriptionErrorCode;
  String? manualRefreshFailureCode;
  bool rememberManualRefreshFailure = true;
  Object? importFailure;
  final refreshErrors = <String, String>{};
  final refreshedIds = <String>[];
  Object? subscriptionStatusError;
  Completer<Object?>? pendingReply;
  Completer<Object?>? refreshReply;
  Completer<Object?>? automaticUpdatesReply;
  Map<String, Object?>? pending = {'url': _privateUrl, 'name': 'Магазин'};
  final calls = <String>[];
  final leases = <String>{};
  Map<String, Object?> get subscriptions => {
    'automaticUpdatesEnabled': automaticUpdatesEnabled,
    'busy': subscriptionsBusy,
    'errorCode': subscriptionErrorCode,
    'refreshErrors': {...refreshErrors},
    'subscriptions': [
      if (imported) {
        'id': _subscriptionId, 'name': 'Магазин', 'host': 'example.invalid',
        'profileCount': 1, 'updatedAt': 1795377600000,
        'expiresAt': null, 'usedBytes': null, 'totalBytes': null,
      },
      if (secondImported) {
        'id': _otherSubscriptionId, 'name': 'Другой магазин', 'host': 'other.invalid',
        'profileCount': secondProfileCount, 'updatedAt': secondUpdatedAt,
        'expiresAt': null, 'usedBytes': null, 'totalBytes': null,
      },
    ],
  };

  Future<Object?> routes(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'installedApps': return <Object?>[];
      case 'getBypassStatus': return {'packages': <String>[], 'unavailablePackages': <String>[]};
      case 'aiFeedbackSummary': return <String, int>{};
      case 'listWireGuardProfiles': return {
        'profiles': [
          {'id': _manualId, 'name': 'Мой сервер'},
          if (imported) {'id': _managedId, 'name': 'Из магазина',
            'subscriptionId': _subscriptionId, 'subscriptionName': 'Магазин'},
        ],
        'activeProfileId': _manualId,
      };
      case 'vpnStatus': return {
        'connected': connected, 'state': connected ? 'connected' : 'disconnected',
        'uptimeSeconds': connected ? 12 : 0, 'lastErrorCode': null,
        'statistics': connected ? {'status': 'unavailable'} : {'status': 'inactive'},
      };
      case 'disconnectWireGuard': connected = false; return null;
      case 'loadWireGuardProfile': return _manualConfig;
      case 'scanWireGuardProfileQr':
      case 'importWireGuardProfileQrImage':
        return {'kind': 'subscription', 'url': _privateUrl};
      case 'saveWireGuardProfile': fail('Adding a subscription must not overwrite a profile');
      case 'connectWireGuard': fail('A subscription must not connect automatically');
      default: return null;
    }
  }

  Future<Object?> subscription(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'status':
        if (subscriptionStatusError != null) throw subscriptionStatusError!;
        return subscriptions;
      case 'takePendingLink':
        final reply = pendingReply;
        pendingReply = null;
        if (reply != null) return reply.future;
        final value = pending;
        pending = null;
        return value;
      case 'importSubscription':
        expect(leases, isNotEmpty);
        expect(call.arguments, {'url': _privateUrl, 'name': 'Магазин'});
        if (importFailure != null) throw importFailure!;
        imported = true;
        return subscriptions;
      case 'refreshDue':
        final reply = refreshReply;
        if (reply == null) return subscriptions;
        subscriptionsBusy = true;
        try { return await reply.future; }
        finally { subscriptionsBusy = false; }
      case 'setAutomaticUpdates':
        automaticUpdatesEnabled = (call.arguments as Map)['enabled'] as bool;
        return automaticUpdatesReply?.future ?? subscriptions;
      case 'refreshSubscription':
        final id = (call.arguments as Map)['id'] as String;
        refreshedIds.add(id);
        final failure = manualRefreshFailureCode;
        if (failure != null) {
          if (rememberManualRefreshFailure) {
            refreshErrors[id] = failure;
            subscriptionErrorCode = failure;
          }
          throw PlatformException(code: failure, message: 'PRIVATE_PROVIDER_DETAILS',
            details: {'url': _privateUrl, 'configuration': _manualConfig});
        }
        refreshErrors.remove(id);
        subscriptionErrorCode = null;
        return subscriptions;
      case 'openPushokAccount':
      case 'openPushokHub':
        expect(call.arguments, isNull);
        return true;
      default: return subscriptions;
    }
  }

  Future<Object?> privacy(MethodCall call) async {
    calls.add('privacy:${call.method}');
    if (call.method == 'acquire') {
      if (!protectionAvailable) throw PlatformException(code: 'PROFILE_PROTECTION_UNAVAILABLE');
      leases.add('subscription-lease');
      return 'subscription-lease';
    }
    leases.remove('subscription-lease');
    return true;
  }
}

Future<void> _pump(WidgetTester tester, _Bridge bridge, {List<String>? copied}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const routes = MethodChannel('shop.pushok.flow/app_routes');
  const subscriptions = MethodChannel('shop.pushok.flow/subscriptions');
  const privacy = MethodChannel('shop.pushok.flow/profile_privacy');
  const account = MethodChannel('shop.pushok.flow/account');
  messenger.setMockMethodCallHandler(routes, bridge.routes);
  messenger.setMockMethodCallHandler(subscriptions, bridge.subscription);
  messenger.setMockMethodCallHandler(privacy, bridge.privacy);
  messenger.setMockMethodCallHandler(account, (call) async => {
    'state': 'signed_out', 'busy': false, 'errorCode': null, 'pending': null,
    'profile': null, 'refreshedAt': null, 'sessionExpiresAt': null, 'stale': false,
  });
  if (copied != null) {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  }
  addTearDown(() {
    messenger.setMockMethodCallHandler(routes, null);
    messenger.setMockMethodCallHandler(subscriptions, null);
    messenger.setMockMethodCallHandler(privacy, null);
    messenger.setMockMethodCallHandler(account, null);
    if (copied != null) messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  await tester.pumpWidget(const PushokFlowApp(isAndroid: true, animationsEnabled: false));
  await tester.pumpAndSettle();
}

void main() {
  Future<void> openServers(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
  }

  Future<void> copyReport(WidgetTester tester, String key) async {
    final button = find.byKey(ValueKey(key));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  void expectPrivateFieldsAbsent(String report) {
    for (final secret in [_privateUrl, 'PRIVATE_TOKEN', 'PRIVATE_PROVIDER_DETAILS',
      'UI_ONLY', 'example.invalid', 'other.invalid', 'Магазин', 'Другой магазин',
      _subscriptionId, _otherSubscriptionId, _managedId]) {
      expect(report, isNot(contains(secret)));
    }
  }

  testWidgets('External-link failure exports its origin without the protected draft', (tester) async {
    final copied = <String>[];
    final bridge = _Bridge()..importFailure = PlatformException(
      code: 'SUBSCRIPTION_AUTH_REQUIRED', message: _privateUrl, details: _manualConfig);
    await _pump(tester, bridge, copied: copied);
    final save = find.byKey(const Key('save_subscription'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionEditor), findsOneWidget);
    expect(copied, isEmpty);
    await copyReport(tester, 'copy_subscription_error');
    expect(copied.single, contains('Действие: Добавление подписки'));
    expect(copied.single, contains('Источник: Внешняя ссылка'));
    expect(copied.single, contains('Код: SUBSCRIPTION_AUTH_REQUIRED'));
    expect(copied.single, contains('Версия: 0.55.0 (сборка 55)'));
    expectPrivateFieldsAbsent(copied.single);
    expect(bridge.imported, isFalse);
    expect(bridge.leases, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Manual refresh report stays correctly scoped after status reread and clears on success', (tester) async {
    final copied = <String>[];
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..automaticUpdatesEnabled = false
      ..manualRefreshFailureCode = 'SUBSCRIPTION_TLS_ERROR';
    await _pump(tester, bridge, copied: copied);
    await openServers(tester);
    final retry = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(copied, isEmpty);
    await copyReport(tester, 'copy_subscription_refresh_error_$_subscriptionId');
    expect(copied.single, contains('Действие: Обновление серверов вручную'));
    expect(copied.single, contains('Источник: Сохранённая подписка'));
    expect(copied.single, contains('Код: SUBSCRIPTION_TLS_ERROR'));
    expectPrivateFieldsAbsent(copied.single);
    bridge.manualRefreshFailureCode = null;
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('copy_subscription_refresh_error_$_subscriptionId')), findsNothing);
    expect(find.byKey(const Key('copy_subscriptions_error')), findsNothing);
    expect(copied, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('New automatic provider failures keep their origin when another provider is retried', (tester) async {
    final copied = <String>[];
    final reply = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..secondImported = true
      ..refreshReply = reply;
    await _pump(tester, bridge, copied: copied);
    bridge.refreshErrors.addAll({
      _subscriptionId: 'SUBSCRIPTION_NETWORK_ERROR',
      _otherSubscriptionId: 'SUBSCRIPTION_AUTH_REQUIRED',
    });
    bridge.subscriptionsBusy = false;
    reply.complete(bridge.subscriptions);
    await tester.pumpAndSettle();
    await openServers(tester);
    await copyReport(tester, 'copy_subscription_refresh_error_$_otherSubscriptionId');
    expect(copied.single, contains('Действие: Автоматическое обновление серверов'));
    expectPrivateFieldsAbsent(copied.single);
    final retry = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await copyReport(tester, 'copy_subscription_refresh_error_$_otherSubscriptionId');
    expect(copied, hasLength(2));
    expect(copied.last, copied.first);
    expect(find.byKey(const ValueKey('copy_subscription_refresh_error_$_subscriptionId')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Restored errors do not claim an automatic download that was not observed', (tester) async {
    final copied = <String>[];
    final bridge = _Bridge()..pending = null..imported = true;
    bridge.refreshErrors[_subscriptionId] = 'SUBSCRIPTION_NETWORK_ERROR';
    await _pump(tester, bridge, copied: copied);
    await openServers(tester);
    expect(bridge.calls, contains('refreshDue'));
    await copyReport(tester, 'copy_subscription_refresh_error_$_subscriptionId');
    expect(copied.single, contains('Действие: Обновление серверов\n'));
    expect(copied.single, isNot(contains('Автоматическое')));
    expect(copied.single, isNot(contains('вручную')));
    expectPrivateFieldsAbsent(copied.single);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A blocked manual retry does not relabel an older automatic provider failure', (tester) async {
    final copied = <String>[];
    final reply = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..refreshReply = reply;
    await _pump(tester, bridge, copied: copied);
    bridge.refreshErrors[_subscriptionId] = 'SUBSCRIPTION_NETWORK_ERROR';
    bridge.subscriptionErrorCode = 'SUBSCRIPTION_NETWORK_ERROR';
    bridge.subscriptionsBusy = false;
    reply.complete(bridge.subscriptions);
    await tester.pumpAndSettle();
    await openServers(tester);
    await copyReport(tester, 'copy_subscription_refresh_error_$_subscriptionId');
    expect(copied.single, contains('Действие: Автоматическое обновление серверов'));
    bridge.manualRefreshFailureCode = 'VPN_BUSY';
    bridge.rememberManualRefreshFailure = false;
    final retry = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await copyReport(tester, 'copy_subscriptions_error');
    expect(copied.last, contains('Код: VPN_BUSY'));
    expect(copied.last, contains('Действие: Обновление серверов вручную'));
    await copyReport(tester, 'copy_subscription_refresh_error_$_subscriptionId');
    expect(copied.last, copied.first);
    expectPrivateFieldsAbsent(copied.last);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Successful automatic-update OFF does not report an interrupted refresh as a settings failure',
      (tester) async {
    final copied = <String>[];
    final reply = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..refreshReply = reply;
    await _pump(tester, bridge, copied: copied);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pump(); // The in-flight refresh intentionally keeps its progress indicator active.
    bridge.subscriptionErrorCode = 'SUBSCRIPTION_INTERRUPTED';
    final automatic = find.byKey(const Key('automatic_subscription_updates'));
    await tester.ensureVisible(automatic);
    await tester.tap(automatic);
    await tester.pump();
    bridge.subscriptionsBusy = false;
    reply.complete(bridge.subscriptions);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    await copyReport(tester, 'copy_subscriptions_error');
    expect(copied.single, contains('Код: SUBSCRIPTION_INTERRUPTED'));
    expect(copied.single, contains('Действие: Чтение подписок'));
    expect(copied.single, isNot(contains('Действие: Настройка автообновления')));
    expectPrivateFieldsAbsent(copied.single);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('An actual action failure remains copyable when native status does not retain it', (tester) async {
    final copied = <String>[];
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..automaticUpdatesEnabled = false
      ..manualRefreshFailureCode = 'SUBSCRIPTION_NETWORK_ERROR'
      ..rememberManualRefreshFailure = false;
    await _pump(tester, bridge, copied: copied);
    await openServers(tester);
    final retry = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(bridge.subscriptionErrorCode, isNull);
    expect(bridge.refreshErrors, isEmpty);
    await copyReport(tester, 'copy_subscriptions_error');
    expect(copied.single, contains('Действие: Обновление серверов вручную'));
    expect(copied.single, contains('Код: SUBSCRIPTION_NETWORK_ERROR'));
    expectPrivateFieldsAbsent(copied.single);
    bridge.manualRefreshFailureCode = null;
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy_subscriptions_error')), findsNothing);
    expect(copied, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('An older refresh cleanup cannot erase a newer automatic-update preference failure', (tester) async {
    final copied = <String>[];
    final refresh = Completer<Object?>();
    final setting = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..refreshReply = refresh
      ..automaticUpdatesReply = setting;
    await _pump(tester, bridge, copied: copied);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pump();
    final automatic = find.byKey(const Key('automatic_subscription_updates'));
    await tester.ensureVisible(automatic);
    await tester.tap(automatic);
    await tester.pump();
    bridge.automaticUpdatesEnabled = true;
    setting.completeError(PlatformException(code: 'SUBSCRIPTION_STORE_FAILED',
      message: _privateUrl, details: _manualConfig));
    await tester.pump();
    bridge.subscriptionsBusy = false;
    refresh.complete(bridge.subscriptions);
    await tester.pumpAndSettle();
    await copyReport(tester, 'copy_subscriptions_error');
    expect(copied.single, contains('Код: SUBSCRIPTION_STORE_FAILED'));
    expect(copied.single, contains('Действие: Настройка автообновления'));
    expectPrivateFieldsAbsent(copied.single);
    bridge.automaticUpdatesReply = null;
    await tester.ensureVisible(automatic);
    await tester.tap(automatic);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(find.byKey(const Key('copy_subscriptions_error')), findsNothing);
    expect(copied, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Unknown global native failures copy only the safe generic code', (tester) async {
    final copied = <String>[];
    final bridge = _Bridge()
      ..pending = null
      ..subscriptionStatusError = PlatformException(code: 'PRIVATE_PROVIDER_TOKEN',
        message: _privateUrl, details: _manualConfig);
    await _pump(tester, bridge, copied: copied);
    await openServers(tester);
    await copyReport(tester, 'copy_subscriptions_error');
    expect(copied.single, contains('Действие: Чтение подписок'));
    expect(copied.single, contains('Код: SUBSCRIPTION_UNAVAILABLE'));
    expect(copied.single, isNot(contains('PRIVATE_PROVIDER_TOKEN')));
    expectPrivateFieldsAbsent(copied.single);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final source in [
    ('camera', 'scan_subscription_qr', 'scanWireGuardProfileQr'),
    ('photo', 'import_subscription_qr_image', 'importWireGuardProfileQrImage'),
  ]) {
    testWidgets('Direct ${source.$1} subscription import uses the protected subscription form and explicit confirmation',
        (tester) async {
      final bridge = _Bridge()..pending = null;
      await _pump(tester, bridge);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
      await tester.pumpAndSettle();
      final add = find.byKey(const Key('add_subscription'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionEditor), findsOneWidget);
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(bridge.leases, isNotEmpty);
      expect(bridge.calls.where((call) => call == 'privacy:acquire').length, 1);
      final scan = find.byKey(Key(source.$2));
      expect(scan, findsOneWidget);
      await tester.ensureVisible(scan);
      await tester.tap(scan);
      await tester.pumpAndSettle();
      expect(bridge.calls.where((call) => call == source.$3).length, 1);
      expect(bridge.calls, isNot(contains('importSubscription')));
      expect(bridge.calls, isNot(contains('loadWireGuardProfile')));
      expect(bridge.calls, isNot(contains('privacy:release')));
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      final url = tester.widget<TextField>(find.byKey(const Key('subscription_url')));
      expect(url.controller!.text, _privateUrl);
      expect(url.obscureText, isTrue);
      expect(url.readOnly, isTrue);
      expect(url.enableInteractiveSelection, isFalse);
      expect(find.byWidgetPredicate((widget) => widget is Text &&
        (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains('PRIVATE_TOKEN')),
        findsNothing);
      final name = find.byKey(const Key('subscription_name'));
      await tester.ensureVisible(name);
      await tester.enterText(name, 'Магазин');
      final save = find.byKey(const Key('save_subscription'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(bridge.calls.where((call) => call == 'importSubscription').length, 1);
      expect(bridge.calls.where((call) => call == 'privacy:release').length, 1);
      expect(bridge.leases, isEmpty);
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(find.byKey(const ValueKey('active_wireguard_profile_$_manualId')), findsOneWidget);
      expect(bridge.calls, isNot(contains('saveWireGuardProfile')));
      expect(bridge.calls, isNot(contains('connectWireGuard')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final source in [
    ('camera', 'scan_wireguard_profile_qr'),
    ('photo', 'import_wireguard_profile_qr_image'),
  ]) {
    testWidgets('Typed ${source.$1} subscription keeps privacy through confirmation and preserves the active server',
        (tester) async {
      final bridge = _Bridge()..pending = null;
      await _pump(tester, bridge);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
      await tester.pumpAndSettle();
      final edit = find.byKey(const ValueKey('edit_wireguard_profile_$_manualId'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(bridge.leases, isNotEmpty);
      final scan = find.byKey(Key(source.$2));
      await tester.ensureVisible(scan);
      await tester.tap(scan);
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(bridge.calls, isNot(contains('importSubscription')));
      expect(tester.widget<TextField>(find.byKey(const Key('wireguard_profile_field')))
          .controller!.text, _manualConfig);
      expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
      final offer = find.byKey(const Key('open_imported_subscription'));
      await tester.ensureVisible(offer);
      await tester.tap(offer);
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionEditor), findsOneWidget);
      expect(bridge.calls.where((call) => call == 'privacy:acquire').length, 1);
      expect(bridge.calls, isNot(contains('privacy:release')));
      expect(bridge.calls, isNot(contains('importSubscription')));
      final name = find.byKey(const Key('subscription_name'));
      await tester.ensureVisible(name);
      await tester.enterText(name, 'Магазин');
      final save = find.byKey(const Key('save_subscription'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(bridge.calls.where((call) => call == 'importSubscription').length, 1);
      expect(bridge.calls.where((call) => call == 'privacy:release').length, 1);
      expect(bridge.leases, isEmpty);
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(find.byKey(const ValueKey('active_wireguard_profile_$_manualId')), findsOneWidget);
      expect(find.byKey(const ValueKey('edit_wireguard_profile_$_managedId')), findsNothing);
      expect(bridge.calls, isNot(contains('saveWireGuardProfile')));
      expect(bridge.calls, isNot(contains('connectWireGuard')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Back from QR subscription and closing the editor performs no import or connection',
      (tester) async {
    final bridge = _Bridge()..pending = null;
    await _pump(tester, bridge);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    final edit = find.byKey(const ValueKey('edit_wireguard_profile_$_manualId'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    for (final key in ['import_wireguard_profile_qr_image', 'open_imported_subscription']) {
      final button = find.byKey(Key(key));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(bridge.leases, isNotEmpty);
    expect(tester.widget<TextField>(find.byKey(const Key('wireguard_profile_field')))
        .controller!.text, _manualConfig);
    final close = find.byKey(const Key('close_wireguard_profile'));
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(bridge.leases, isEmpty);
    expect(bridge.calls, isNot(contains('importSubscription')));
    expect(bridge.calls, isNot(contains('saveWireGuardProfile')));
    expect(bridge.calls, isNot(contains('connectWireGuard')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('External link opens a protected draft and imports only after confirmation', (tester) async {
    final bridge = _Bridge();
    await _pump(tester, bridge);
    expect(find.byType(SubscriptionEditor), findsOneWidget);
    expect(bridge.leases, isNotEmpty);
    expect(bridge.calls, isNot(contains('importSubscription')));
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isTrue);
    final save = find.byKey(const Key('save_subscription'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(bridge.imported, isTrue);
    expect(bridge.leases, isEmpty);
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(find.text('Мой сервер'), findsOneWidget);
    expect(find.byKey(const ValueKey('active_wireguard_profile_$_manualId')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit_wireguard_profile_$_managedId')), findsNothing);
    expect(bridge.calls, isNot(contains('connectWireGuard')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A pending link waits while Flow is connected and does not fetch', (tester) async {
    final bridge = _Bridge()..connected = true;
    await _pump(tester, bridge);
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(find.byKey(const Key('pending_subscription_link')), findsOneWidget);
    expect(bridge.calls, isNot(contains('importSubscription')));
    expect(bridge.calls, isNot(contains('refreshDue')));
    expect(bridge.leases, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A link reply from before app switching stays pending without navigating or opening',
      (tester) async {
    final reply = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..pendingReply = reply;
    await _pump(tester, bridge);
    expect(bridge.calls.where((call) => call == 'takePendingLink').length, 1);
    expect(find.byType(SubscriptionEditor), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    reply.complete({'url': _privateUrl, 'name': 'Магазин'});
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(bridge.leases, isEmpty);
    expect(bridge.calls, isNot(contains('importSubscription')));
    expect(bridge.calls, isNot(contains('refreshDue')));
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pending_subscription_link')), findsOneWidget);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    final offer = find.byKey(const Key('open_pending_subscription_link'));
    await tester.ensureVisible(offer);
    await tester.tap(offer);
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionEditor), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url')))
        .controller!.text, _privateUrl);
    expect(bridge.calls, isNot(contains('importSubscription')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final newerFirst in [false, true]) {
    testWidgets('A fresh resume link wins when the ${newerFirst ? 'newer' : 'older'} reply arrives first',
        (tester) async {
      const newerUrl = 'https://example.invalid/sub/NEW_PRIVATE_TOKEN';
      final older = Completer<Object?>();
      final newer = Completer<Object?>();
      final bridge = _Bridge()
        ..pending = null
        ..pendingReply = older;
      await _pump(tester, bridge);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      bridge.pendingReply = newer;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.calls.where((call) => call == 'takePendingLink').length, 2);

      if (newerFirst) {
        newer.complete({'url': newerUrl, 'name': 'Новая подписка'});
        await tester.pumpAndSettle();
        older.complete({'url': _privateUrl, 'name': 'Старая подписка'});
      } else {
        older.complete({'url': _privateUrl, 'name': 'Старая подписка'});
        await tester.pumpAndSettle();
        expect(find.byType(SubscriptionEditor), findsNothing);
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
        await tester.pumpAndSettle();
        // Finishing an old request must not release the newer request's read guard.
        expect(bridge.calls.where((call) => call == 'takePendingLink').length, 2);
        expect(find.byType(SubscriptionEditor), findsNothing);
        newer.complete({'url': newerUrl, 'name': 'Новая подписка'});
      }
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionEditor), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('subscription_url')))
          .controller!.text, newerUrl);
      expect(tester.widget<TextField>(find.byKey(const Key('subscription_name')))
          .controller!.text, 'Новая подписка');
      expect(find.byKey(const Key('pending_subscription_link')), findsNothing);
      expect(bridge.calls.where((call) => call == 'privacy:acquire').length, 1);
      expect(bridge.calls, isNot(contains('importSubscription')));
      expect(bridge.calls, isNot(contains('connectWireGuard')));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Privacy failure leaves a pending URL hidden and never downloads', (tester) async {
    final bridge = _Bridge()..protectionAvailable = false;
    await _pump(tester, bridge);
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(find.byKey(const Key('pending_subscription_link')), findsOneWidget);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    expect(bridge.calls, isNot(contains('importSubscription')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Automatic refresh can be switched off without releasing its mutation guard',
      (tester) async {
    final refresh = Completer<Object?>();
    final setting = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..refreshReply = refresh
      ..automaticUpdatesReply = setting;
    final oldStatus = bridge.subscriptions;
    await _pump(tester, bridge);
    expect(bridge.calls.where((call) => call == 'refreshDue').length, 1);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pump();
    final control = find.byKey(const Key('automatic_subscription_updates'));
    expect(tester.widget<SwitchListTile>(control).onChanged, isNotNull);
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pump();
    expect(bridge.automaticUpdatesEnabled, isFalse);
    expect(bridge.calls.where((call) => call == 'setAutomaticUpdates').length, 1);
    expect(tester.widget<SwitchListTile>(control).onChanged, isNull);
    setting.complete(bridge.subscriptions);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(control).value, isFalse);
    for (final key in ['add_subscription', 'refresh_subscription_$_subscriptionId',
      'delete_subscription_$_subscriptionId']) {
      expect(tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed, isNull);
    }
    expect(tester.widget<SwitchListTile>(control).onChanged, isNull);
    // A queued refresh snapshot from before OFF must not turn the setting back on.
    refresh.complete(oldStatus);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(control).value, isFalse);
    expect(tester.widget<SwitchListTile>(control).onChanged, isNotNull);
    expect(bridge.calls.where((call) => call == 'refreshDue').length, 1);
    expect(bridge.calls, isNot(contains('importSubscription')));
    expect(bridge.calls, isNot(contains('saveWireGuardProfile')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Partial automatic refresh preserves successful provider metadata and scoped retry',
      (tester) async {
    final refresh = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..secondImported = true
      ..refreshReply = refresh;
    await _pump(tester, bridge);
    expect(bridge.calls.where((call) => call == 'refreshDue').length, 1);
    bridge.refreshErrors[_subscriptionId] = 'SUBSCRIPTION_NETWORK_ERROR';
    bridge.secondProfileCount = 4;
    bridge.secondUpdatedAt = 1795464000000;
    bridge.subscriptionsBusy = false;
    refresh.complete(bridge.subscriptions);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_subscriptionId')), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_otherSubscriptionId')), findsNothing);
    expect(find.text('other.invalid · Серверов: 4'), findsOneWidget);
    expect(find.text('Серверы обновлены: 23.11.2026'), findsOneWidget);
    expect(find.text('Список серверов обновлён.'), findsNothing);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    final retry = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(bridge.refreshedIds, [_subscriptionId]);
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsNothing);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_subscriptionId')), findsNothing);
    expect(find.text('other.invalid · Серверов: 4'), findsOneWidget);
    expect(bridge.calls, isNot(contains('connectWireGuard')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A later fatal automatic refresh error still rereads completed provider changes',
      (tester) async {
    final refresh = Completer<Object?>();
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..secondImported = true
      ..refreshReply = refresh;
    await _pump(tester, bridge);
    // A provider committed successfully before a later global stop.
    bridge.secondProfileCount = 3;
    bridge.secondUpdatedAt = 1795464000000;
    bridge.subscriptionErrorCode = 'VPN_ACTIVE';
    refresh.completeError(PlatformException(code: 'VPN_ACTIVE', message: 'PRIVATE_DETAILS'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscriptions_error')), findsOneWidget);
    expect(find.text('Для обновления серверов отключите подключение Flow.'), findsOneWidget);
    expect(find.text('other.invalid · Серверов: 3'), findsOneWidget);
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsNothing);
    expect(find.text('Список серверов обновлён.'), findsNothing);
    expect(find.textContaining('PRIVATE_DETAILS'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Manual success clears only that provider and never announces all errors resolved',
      (tester) async {
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..secondImported = true
      ..automaticUpdatesEnabled = false;
    bridge.refreshErrors.addAll({
      _subscriptionId: 'SUBSCRIPTION_NETWORK_ERROR',
      _otherSubscriptionId: 'SUBSCRIPTION_AUTH_REQUIRED',
    });
    await _pump(tester, bridge);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    final retry = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(bridge.refreshedIds, [_subscriptionId]);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_subscriptionId')), findsNothing);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_otherSubscriptionId')), findsOneWidget);
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsOneWidget);
    expect(find.text('Список серверов обновлён.'), findsNothing);
    expect(bridge.calls, isNot(contains('refreshDue')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Manual provider failure rereads its row warning without exposing native details',
      (tester) async {
    final bridge = _Bridge()
      ..pending = null
      ..imported = true
      ..automaticUpdatesEnabled = false
      ..manualRefreshFailureCode = 'SUBSCRIPTION_AUTH_REQUIRED';
    await _pump(tester, bridge);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsNothing);
    final refresh = find.byKey(const ValueKey('refresh_subscription_$_subscriptionId'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(bridge.refreshedIds, [_subscriptionId]);
    expect(find.byKey(const ValueKey('subscription_refresh_error_$_subscriptionId')), findsOneWidget);
    expect(find.byKey(const Key('subscriptions_refresh_warning')), findsOneWidget);
    expect(find.text('Повторить обновление'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(refresh).onPressed, isNotNull);
    expect(find.text('example.invalid · Серверов: 1'), findsOneWidget);
    expect(find.text('Список серверов обновлён.'), findsNothing);
    expect(find.textContaining('PRIVATE_PROVIDER_DETAILS'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Profile opens the existing MTProxy account and Pushok hub as distinct destinations', (tester) async {
    final bridge = _Bridge()..pending = null;
    await _pump(tester, bridge);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Профиль')));
    await tester.pumpAndSettle();
    expect(find.textContaining('@pushok_app'), findsOneWidget);
    expect(find.text('Открыть кабинет MTProxy'), findsOneWidget);
    expect(find.textContaining('Регистрация, оплата и подписки'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('open_pushok_account')));
    await tester.tap(find.byKey(const Key('open_pushok_account')));
    await tester.pumpAndSettle();
    expect(bridge.calls.where((call) => call == 'openPushokAccount').length, 1);
    expect(bridge.calls, isNot(contains('openPushokHub')));
    await tester.ensureVisible(find.byKey(const Key('open_pushok_hub')));
    await tester.tap(find.byKey(const Key('open_pushok_hub')));
    await tester.pumpAndSettle();
    expect(bridge.calls.where((call) => call == 'openPushokHub').length, 1);
    expect(bridge.calls.where((call) => call == 'openPushokAccount').length, 1);
    expect(bridge.calls, isNot(contains('importSubscription')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Unavailable subscriptions leave manual server controls usable', (tester) async {
    final bridge = _Bridge()
      ..pending = null
      ..subscriptionStatusError = MissingPluginException('PRIVATE_NATIVE_DETAILS');
    await _pump(tester, bridge);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Серверы')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscriptions_error')), findsOneWidget);
    expect(find.textContaining('PRIVATE_NATIVE_DETAILS'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final edit = find.byKey(const ValueKey('edit_wireguard_profile_$_manualId'));
    await tester.ensureVisible(edit);
    expect(tester.widget<OutlinedButton>(edit).onPressed, isNotNull);
    expect(bridge.calls, isNot(contains('importSubscription')));
    expect(bridge.calls, isNot(contains('refreshDue')));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
