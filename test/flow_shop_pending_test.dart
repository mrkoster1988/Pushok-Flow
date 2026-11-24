import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/ui/account_card.dart';

const _accountChannel = MethodChannel('shop.pushok.flow/account');
const _subscriptionChannel = MethodChannel('shop.pushok.flow/subscriptions');

Map<String, Object?> _account() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'state': 'connected', 'busy': false, 'errorCode': null,
    'pending': null, 'recoveryAvailable': false, 'stale': false,
    'sessionExpiresAt': now + 43200000, 'refreshedAt': now,
    'profile': {
      'id': '10000000-0000-4000-8000-000000000001',
      'displayName': 'Test', 'role': 'user', 'phoneVerified': true,
      'wallet': {'RUB': 0, 'BONUS': 0, 'XTR': 0}
    },
  };
}

Map<String, Object?> _subscriptions(String state) => {
  'subscriptions': <Object>[], 'automaticUpdatesEnabled': false,
  'shopAutoSyncEnabled': true, 'shopSyncState': state,
  'busy': false, 'errorCode': null, 'refreshErrors': <String, String>{},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  int syncs = 0;
  String shopState = 'idle';

  setUp(() {
    syncs = 0;
    shopState = 'idle';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_accountChannel, (call) async {
      if (call.method == 'status' || call.method == 'refresh') return _account();
      throw MissingPluginException();
    });
    messenger.setMockMethodCallHandler(_subscriptionChannel, (call) async {
      if (call.method == 'status') return _subscriptions(shopState);
      if (call.method == 'syncShop') {
        syncs++;
        shopState = syncs == 1 ? 'pending' : 'active';
        return _subscriptions(shopState);
      }
      throw MissingPluginException();
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_accountChannel, null);
    messenger.setMockMethodCallHandler(_subscriptionChannel, null);
  });

  testWidgets('A pending 30-day WireGuard grant refreshes without reopening Flow',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(
        child: PushokAccountCard(isAndroid: true))),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(syncs, 1);
    expect(shopState, 'pending');

    await tester.pump(const Duration(seconds: 45));
    await tester.pump();
    await tester.pump();
    expect(syncs, 2);
    expect(shopState, 'active');

    await tester.pump(const Duration(seconds: 90));
    expect(syncs, 2, reason: 'Polling stops once the connection is ready.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Pending auto-poll is cancelled when account screen closes',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(
        child: PushokAccountCard(isAndroid: true))),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(syncs, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 90));
    expect(syncs, 1);
  });
}
