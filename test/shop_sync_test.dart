import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/platform/subscriptions.dart';

Map<String, Object?> _snapshot({bool enabled = false, String state = 'idle'}) => {
  'subscriptions': <Object?>[],
  'automaticUpdatesEnabled': true,
  'shopAutoSyncEnabled': enabled,
  'shopSyncState': state,
  'busy': false,
  'errorCode': null,
  'refreshErrors': <String, String>{},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/subscriptions');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var auto = false;
  var state = 'idle';
  setUp(() {
    auto = false;
    state = 'idle';
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'status': return _snapshot(enabled: auto, state: state);
        case 'setShopAutoSync':
          final args = call.arguments as Map;
          expect(args.keys, ['enabled']);
          auto = args['enabled'] as bool;
          return _snapshot(enabled: auto, state: state);
        case 'syncShop':
          expect(call.arguments, isNull);
          state = 'active';
          return _snapshot(enabled: auto, state: state);
        case 'unlinkShop':
          expect(call.arguments, isNull);
          state = 'idle';
          return _snapshot(enabled: auto, state: state);
        default: throw MissingPluginException();
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Shop exchange carries no identity, ticket or URL across Flutter', () async {
    final bridge = FlowSubscriptions(isAndroid: true);
    expect((await bridge.status()).shopAutoSyncEnabled, isFalse);
    expect((await bridge.setShopAutoSync(true)).shopAutoSyncEnabled, isTrue);
    expect((await bridge.syncShop()).shopSyncState, 'active');
    expect((await bridge.unlinkShop()).shopSyncState, 'idle');
    for (final call in calls) {
      expect(call.method, isIn(['status', 'setShopAutoSync', 'syncShop', 'unlinkShop']));
      if (call.arguments != null) expect(call.arguments, {'enabled': true});
      expect(call.toString(), isNot(contains('private-token')));
    }
  });

  test('Legacy metadata is compatible but invalid Shop states cannot cross', () {
    final legacy = _snapshot()..remove('shopAutoSyncEnabled')..remove('shopSyncState');
    expect(SubscriptionStatus.fromPlatform(legacy).shopAutoSyncEnabled, isFalse);
    expect(SubscriptionStatus.fromPlatform(legacy).shopSyncState, 'idle');
    for (final invalid in <Map<String, Object?>>[
      {..._snapshot(), 'shopAutoSyncEnabled': 'true'},
      {..._snapshot(), 'shopAutoSyncEnabled': null},
      {..._snapshot(), 'shopSyncState': null},
      {..._snapshot(), 'shopSyncState': 'token=PRIVATE'},
      {..._snapshot(), 'subscription_url': 'https://provider/private'},
      {..._snapshot(), 'ticket': 'psb1.PRIVATE'},
    ]) {
      expect(() => SubscriptionStatus.fromPlatform(invalid), throwsFormatException);
    }
  });

  test('The user sees bounded statuses and generic errors', () {
    for (final state in ['idle', 'active', 'pending', 'expired', 'revoked',
        'disabled', 'unavailable', 'link_disabled']) {
      expect(SubscriptionStatus.fromPlatform(_snapshot(state: state)).shopSyncState, state);
    }
    expect(subscriptionErrorMessage(PlatformException(code: 'SHOP_DEVICE_BOUND')),
      contains('другому устройству'));
    expect(subscriptionErrorMessage(PlatformException(code: 'SHOP_PROOF_REPLAY')),
      contains('уже использовано'));
    expect(subscriptionErrorMessage(PlatformException(code: 'SHOP_IDENTITY_CONFLICT')),
      contains('конфликт привязки аккаунтов'));
    expect(subscriptionErrorMessage(PlatformException(code: 'SHOP_CONFLICT')),
      isNot(contains('другому устройству')));
    expect(subscriptionErrorMessage(PlatformException(code: 'SHOP_ACCOUNT_CHANGED')),
      contains('другим аккаунтом'));
    expect(subscriptionErrorMessage(PlatformException(code: 'SHOP_NETWORK_ERROR')),
      contains('интернет'));
    expect(subscriptionErrorMessage(PlatformException(code: 'PRIVATE_SERVER_TOKEN')),
      isNot(contains('PRIVATE_SERVER_TOKEN')));
  });
}
