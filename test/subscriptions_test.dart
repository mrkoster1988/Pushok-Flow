import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/platform/subscriptions.dart';

const _id = '10000000-0000-4000-8000-000000000001';
const _otherId = '10000000-0000-4000-8000-000000000002';
Map<String, Object?> _entry() => {
  'id': _id, 'name': 'Моя подписка', 'host': 'example.invalid',
  'profileCount': 2, 'updatedAt': 1795377600000,
  'expiresAt': null, 'usedBytes': null, 'totalBytes': null,
};
Map<String, Object?> _status() => {
  'subscriptions': [_entry()], 'automaticUpdatesEnabled': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Subscription metadata preserves unknown expiry and is immutable', () {
    final source = _status();
    final status = SubscriptionStatus.fromPlatform(source);
    expect(status.subscriptions.single.expiresAt, isNull);
    expect(status.subscriptions.single.host, 'example.invalid');
    expect(status.busy, isFalse);
    expect(status.errorCode, isNull);
    expect(status.refreshErrors, isEmpty);
    expect(status.automaticUpdatesEnabled, isTrue);
    expect(() => status.subscriptions.clear(), throwsUnsupportedError);
    (source['subscriptions']! as List).clear();
    expect(status.subscriptions.length, 1);
  });

  test('Provider failures stay scoped to existing subscriptions and immutable', () {
    final errors = <String, String>{_id: 'SUBSCRIPTION_NETWORK_ERROR'};
    final status = SubscriptionStatus.fromPlatform({
      ..._status(),
      'subscriptions': [_entry(), {..._entry(), 'id': _otherId, 'profileCount': 3}],
      'refreshErrors': errors,
    });
    expect(status.refreshErrors, {_id: 'SUBSCRIPTION_NETWORK_ERROR'});
    expect(status.errorCode, isNull);
    expect(status.subscriptions.last.profileCount, 3);
    expect(() => status.refreshErrors.clear(), throwsUnsupportedError);
    errors.clear();
    expect(status.refreshErrors.length, 1);
  });

  test('Provider error metadata rejects unknown IDs, secrets and global failures', () {
    for (final errors in <Object?>[
      null,
      <Object?>[],
      {_otherId: 'SUBSCRIPTION_NETWORK_ERROR'},
      {'https://example.invalid/PRIVATE_TOKEN': 'SUBSCRIPTION_NETWORK_ERROR'},
      {_id: 'SUBSCRIPTION_NETWORK_ERROR https://example.invalid/PRIVATE_TOKEN'},
      {_id: {'code': 'SUBSCRIPTION_NETWORK_ERROR', 'message': 'PRIVATE_TOKEN'}},
      {_id: null},
      {_id: 'SUBSCRIPTION_INTERRUPTED'},
      {_id: 'SUBSCRIPTION_STORE_FAILED'},
      {_id: 'VPN_ACTIVE'},
      {_id: 'SUBSCRIPTION_UNKNOWN'},
      {_id: 'SUBSCRIPTION_TIMEOUT'},
      {1: 'SUBSCRIPTION_NETWORK_ERROR'},
    ]) {
      try {
        SubscriptionStatus.fromPlatform({..._status(), 'refreshErrors': errors});
        fail('Invalid provider error metadata was accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString(), isNot(contains('PRIVATE_TOKEN')));
      }
    }
  });

  test('TLS failures remain provider-scoped with safe actionable diagnostics', () {
    final status = SubscriptionStatus.fromPlatform({
      ..._status(),
      'subscriptions': [_entry(), {..._entry(), 'id': _otherId, 'profileCount': 3}],
      'refreshErrors': {_id: 'SUBSCRIPTION_TLS_ERROR'},
    });
    expect(status.refreshErrors, {_id: 'SUBSCRIPTION_TLS_ERROR'});
    expect(status.errorCode, isNull);
    expect(status.subscriptions.last.profileCount, 3);
    final message = subscriptionErrorMessage(PlatformException(
      code: 'SUBSCRIPTION_TLS_ERROR', message: 'PRIVATE_CERTIFICATE',
      details: 'https://example.invalid/PRIVATE_TOKEN'));
    expect(message, contains('защищённое соединение'));
    expect(message, contains('HTTPS-адрес'));
    expect(message, contains('сертификат'));
    expect(message, contains('поставщика'));
    expect(message, isNot(contains('PRIVATE_')));
    expect(message, isNot(contains('example.invalid')));
  });

  test('Status rejects leaked URLs, contradictory entries and invalid dates', () {
    for (final raw in <Object?>[
      null,
      {..._status(), 'url': 'https://example.invalid/PRIVATE_TOKEN'},
      {..._status(), 'subscriptions': [{..._entry(), 'url': 'PRIVATE_TOKEN'}]},
      {..._status(), 'subscriptions': [_entry(), _entry()]},
      {..._status(), 'subscriptions': [{..._entry(), 'expiresAt': -1}]},
      {..._status(), 'subscriptions': [{..._entry(), 'expiresAt': 9000000000000001}]},
      {..._status(), 'subscriptions': [{..._entry(), 'profileCount': 21}]},
      {..._status(), 'subscriptions': [{..._entry(), 'host': 'example.invalid/PRIVATE_TOKEN'}]},
      {..._status(), 'subscriptions': [{..._entry(), 'usedBytes': -1}]},
      {..._status(), 'busy': 'true'},
      {..._status(), 'errorCode': 'PRIVATE_TOKEN https://example.invalid'},
    ]) {
      try {
        SubscriptionStatus.fromPlatform(raw);
        fail('Invalid metadata was accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString(), isNot(contains('PRIVATE_TOKEN')));
      }
    }
  });

  test('Pending links contain only a valid HTTPS URL and an optional safe name', () {
    expect(SubscriptionDraft.fromPlatform(null), isNull);
    final draft = SubscriptionDraft.fromPlatform({
      'url': 'https://example.invalid/sub/PRIVATE_TOKEN', 'name': 'Моя подписка',
    })!;
    expect(draft.name, 'Моя подписка');
    expect(draft.toString(), isNot(contains('PRIVATE_TOKEN')));
    for (final url in ['http://example.invalid/sub', 'vless://example.invalid',
      'https://name:password@example.invalid/sub',
      'https://example.invalid/sub#PRIVATE_TOKEN',
      'https://example.invalid/sub\nPRIVATE_TOKEN', '', ' https://example.invalid']) {
      expect(SubscriptionDraft.validUrl(url), isFalse);
      expect(() => SubscriptionDraft.fromPlatform({'url': url}), throwsFormatException);
    }
  });

  test('Native errors never expose provider or configuration details', () {
    final error = PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR',
      message: 'https://example.invalid/PRIVATE_TOKEN', details: 'PRIVATE_CONFIG');
    expect(subscriptionErrorMessage(error), contains('Сохранённые серверы'));
    expect(subscriptionErrorMessage(error), isNot(contains('PRIVATE_')));
    expect(subscriptionErrorMessage(PlatformException(code: 'PRIVATE_UNKNOWN_CODE',
      message: 'PRIVATE_ERROR')), isNot(contains('PRIVATE_')));
  });

  test('Bridge keeps account opening, URL drafts and confirmed import separate', () async {
    const channel = MethodChannel('shop.pushok.flow/subscriptions');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'takePendingLink') {
        return {'url': 'https://example.invalid/sub/PRIVATE_TOKEN'};
      }
      if (call.method == 'openPushokAccount' || call.method == 'openPushokHub') return true;
      return _status();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final bridge = FlowSubscriptions(isAndroid: true);
    await bridge.status();
    await bridge.takePendingLink();
    await bridge.openPushokAccount();
    await bridge.openPushokHub();
    expect(calls.map((call) => call.method),
      ['status', 'takePendingLink', 'openPushokAccount', 'openPushokHub']);
    expect(calls.every((call) => call.arguments == null), isTrue);
    await bridge.importSubscription('https://example.invalid/sub/PRIVATE_TOKEN', 'Название');
    expect(calls.last.arguments, {'url': 'https://example.invalid/sub/PRIVATE_TOKEN', 'name': 'Название'});
    await bridge.refreshSubscription(_id);
    expect(calls.last.arguments, {'id': _id});
    await bridge.deleteSubscription(_id);
    expect(calls.last.arguments, {'id': _id});
    await bridge.setAutomaticUpdates(false);
    expect(calls.last.arguments, {'enabled': false});
    expect(calls.any((call) => call.method.contains('connect')), isFalse);
  });
}
