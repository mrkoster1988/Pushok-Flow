import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/ui/account_card.dart';

const _accountChannel = MethodChannel('shop.pushok.flow/account');
const _subscriptionChannel = MethodChannel('shop.pushok.flow/subscriptions');

Map<String, Object?> _connectedAccount() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'state': 'connected',
    'busy': false,
    'errorCode': null,
    'pending': null,
    'recoveryAvailable': false,
    'stale': false,
    'sessionExpiresAt': now + 43200000,
    'refreshedAt': now,
    'profile': {
      'id': '10000000-0000-4000-8000-000000000001',
      'displayName': 'Test',
      'role': 'user',
      'phoneVerified': true,
      'wallet': {'RUB': 0, 'BONUS': 0, 'XTR': 0},
    },
  };
}

Map<String, Object?> _shopState(String state) => {
  'subscriptions': <Object>[],
  'automaticUpdatesEnabled': false,
  'shopAutoSyncEnabled': false,
  'shopSyncState': state,
  'busy': false,
  'errorCode': null,
  'refreshErrors': <String, String>{},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var syncCalls = 0;
  var preferenceWrites = 0;
  var unlinkCalls = 0;
  var shopOpenCalls = 0;
  var shopState = 'idle';

  setUp(() {
    syncCalls = 0;
    preferenceWrites = 0;
    unlinkCalls = 0;
    shopOpenCalls = 0;
    shopState = 'idle';
    messenger.setMockMethodCallHandler(_accountChannel, (call) async {
      if (call.method == 'status' || call.method == 'refresh') {
        return _connectedAccount();
      }
      throw MissingPluginException(call.method);
    });
    messenger.setMockMethodCallHandler(_subscriptionChannel, (call) async {
      if (call.method == 'status') return _shopState(shopState);
      if (call.method == 'syncShop') {
        expect(call.arguments, isNull,
            reason: 'Personal tickets and config URLs stay inside native Android.');
        syncCalls++;
        shopState = syncCalls == 1 ? 'pending' : 'active';
        return _shopState(shopState);
      }
      if (call.method == 'setShopAutoSync') {
        preferenceWrites++;
        throw StateError('Manual get-config cannot change a saved preference.');
      }
      if (call.method == 'openPushokShop') {
        expect(call.arguments, isNull,
            reason: 'Shop URLs and personal tokens must never leave native Android.');
        shopOpenCalls++;
        return true;
      }
      if (call.method == 'unlinkShop') {
        expect(call.arguments, isNull);
        unlinkCalls++;
        shopState = 'idle';
        return _shopState(shopState);
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_accountChannel, null);
    messenger.setMockMethodCallHandler(_subscriptionChannel, null);
  });

  testWidgets('Get config syncs immediately without opting into background sync',
      (tester) async {
    var successfulCallbacks = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: PushokAccountCard(
        isAndroid: true,
        compactHome: true,
        onShopSynced: () => successfulCallbacks++,
      ))),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final receive = find.byKey(const Key('home_get_config_button'));
    expect(receive, findsOneWidget);
    expect(tester.widget<FilledButton>(receive).onPressed, isNotNull);
    expect(syncCalls, 0);
    expect(preferenceWrites, 0);

    await tester.tap(receive);
    await tester.pump();
    await tester.pump();
    expect(syncCalls, 1, reason: 'First tap must make the native Shop request.');
    expect(preferenceWrites, 0);
    expect(find.text('Создаём подключение в Shop…'), findsOneWidget);

    // Automatic polling must remain disabled if the user opted out.
    await tester.pump(const Duration(seconds: 90));
    expect(syncCalls, 1);
    await tester.tap(receive);
    await tester.pump();
    await tester.pump();
    expect(syncCalls, 2);
    expect(preferenceWrites, 0);
    expect(successfulCallbacks, 1);
    expect(find.text('Личная подписка получена'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Account-only renewal opens Shop without changing the WireGuard tunnel',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: PushokAccountCard(
        isAndroid: true, compactHome: true,
      ))),
    ));
    for (var i = 0; i < 5; i++) await tester.pump();
    final renew = find.byKey(const Key('home_renew_subscription'));
    expect(renew, findsOneWidget);
    await tester.tap(renew);
    await tester.pump();
    expect(shopOpenCalls, 1);
    expect(syncCalls, 0);
    expect(unlinkCalls, 0);
    expect(preferenceWrites, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Local delete never revokes account and does not reimport automatically',
      (tester) async {
    shopState = 'active';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: PushokAccountCard(
        isAndroid: true, compactHome: true,
      ))),
    ));
    for (var i = 0; i < 5; i++) await tester.pump();
    final remove = find.byKey(const Key('home_delete_config'));
    expect(remove, findsOneWidget);
    await tester.tap(remove);
    await tester.pump();
    expect(find.text('Отвязать подключение?'), findsOneWidget);
    expect(unlinkCalls, 0, reason: 'Delete requires explicit confirmation.');
    await tester.tap(find.byKey(const Key('confirm_shop_unlink')));
    await tester.pump();
    await tester.pump();
    expect(unlinkCalls, 1);
    expect(preferenceWrites, 0);
    expect(syncCalls, 0);
    expect(find.byKey(const Key('home_authorize_button')), findsOneWidget,
      reason: 'Account remains signed in after local removal.');
    await tester.pump(const Duration(seconds: 90));
    expect(syncCalls, 0, reason: 'Old personal config must not be reimported.');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
