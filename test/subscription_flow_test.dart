import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';
import 'package:pushok_flow/ui/subscription_editor.dart';

const _manualId = '10000000-0000-4000-8000-000000000001';
const _managedId = '10000000-0000-4000-8000-000000000002';
const _subscriptionId = '10000000-0000-4000-8000-000000000003';
const _privateUrl = 'https://example.invalid/sub/PRIVATE_TOKEN';

class _Bridge {
  bool connected = false;
  bool imported = false;
  bool protectionAvailable = true;
  Object? subscriptionStatusError;
  Map<String, Object?>? pending = {'url': _privateUrl, 'name': 'Магазин'};
  final calls = <String>[];
  final leases = <String>{};
  Map<String, Object?> get subscriptions => {
    'automaticUpdatesEnabled': true,
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
        final value = pending;
        pending = null;
        return value;
      case 'importSubscription':
        expect(leases, isNotEmpty);
        expect(call.arguments, {'url': _privateUrl, 'name': 'Магазин'});
        imported = true;
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

Future<void> _pump(WidgetTester tester, _Bridge bridge) async {
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

  testWidgets('Privacy failure leaves a pending URL hidden and never downloads', (tester) async {
    final bridge = _Bridge()..protectionAvailable = false;
    await _pump(tester, bridge);
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(find.byKey(const Key('pending_subscription_link')), findsOneWidget);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    expect(bridge.calls, isNot(contains('importSubscription')));
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
