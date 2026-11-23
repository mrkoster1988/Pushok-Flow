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
const _privateUrl = 'https://example.invalid/sub/PRIVATE_TOKEN';
const _manualConfig = '[Interface]\nPrivateKey = UI_ONLY\nAddress = 10.0.0.2/32\n'
    '[Peer]\nPublicKey = UI_ONLY_PEER\n';

class _Bridge {
  bool connected = false;
  bool imported = false;
  bool protectionAvailable = true;
  bool automaticUpdatesEnabled = true;
  bool subscriptionsBusy = false;
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
    'subscriptions': imported ? [{
      'id': _subscriptionId, 'name': 'Магазин', 'host': 'example.invalid',
      'profileCount': 1, 'updatedAt': 1795377600000,
      'expiresAt': null, 'usedBytes': null, 'totalBytes': null,
    }] : <Object?>[],
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

Future<void> _pump(WidgetTester tester, _Bridge bridge) async {
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
  addTearDown(() {
    messenger.setMockMethodCallHandler(routes, null);
    messenger.setMockMethodCallHandler(subscriptions, null);
    messenger.setMockMethodCallHandler(privacy, null);
    messenger.setMockMethodCallHandler(account, null);
  });
  await tester.pumpWidget(const PushokFlowApp(isAndroid: true, animationsEnabled: false));
  await tester.pumpAndSettle();
}

void main() {
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
