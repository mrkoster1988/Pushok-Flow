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
Map<String, Object?> _wireGuardEntry({String state = 'active'}) => {
  ..._entry(), 'format': 'wireguard-v1', 'state': state,
  'profileCount': state == 'active' ? 2 : 0,
  'expiresAt': 1795464000000, 'skippedProfileCount': 0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Subscription metadata preserves unknown expiry and is immutable', () {
    final source = _status();
    final status = SubscriptionStatus.fromPlatform(source);
    expect(status.subscriptions.single.expiresAt, isNull);
    expect(status.subscriptions.single.host, 'example.invalid');
    expect(status.subscriptions.single.skippedProfileCount, 0);
    expect(status.subscriptions.single.format, SubscriptionFormat.vless);
    expect(status.subscriptions.single.state, SubscriptionAccessState.active);
    expect(status.busy, isFalse);
    expect(status.errorCode, isNull);
    expect(status.refreshErrors, isEmpty);
    expect(status.automaticUpdatesEnabled, isTrue);
    expect(() => status.subscriptions.clear(), throwsUnsupportedError);
    (source['subscriptions']! as List).clear();
    expect(status.subscriptions.length, 1);
  });

  test('Legacy expiry stays informational with absent or explicit legacy metadata', () {
    for (final entry in [
      {..._entry(), 'expiresAt': 1000},
      {..._entry(), 'format': 'vless', 'state': 'active', 'expiresAt': 1000},
    ]) {
      final value = SubscriptionStatus.fromPlatform({
        ..._status(), 'subscriptions': [entry],
      }).subscriptions.single;
      expect(value.isWireGuard, isFalse);
      expect(value.effectiveState(DateTime.fromMillisecondsSinceEpoch(2000)),
        SubscriptionAccessState.active);
    }
  });

  test('WireGuard declared states and local expiry remain distinct without changing cached counts', () {
    final deadline = DateTime.fromMillisecondsSinceEpoch(1795464000000);
    final active = SubscriptionStatus.fromPlatform({
      ..._status(), 'subscriptions': [_wireGuardEntry()],
    }).subscriptions.single;
    expect(active.format, SubscriptionFormat.wireGuardV1);
    expect(active.state, SubscriptionAccessState.active);
    expect(active.effectiveState(deadline.subtract(const Duration(milliseconds: 1))),
      SubscriptionAccessState.active);
    expect(active.effectiveState(deadline), SubscriptionAccessState.expired);
    expect(active.effectiveState(deadline.add(const Duration(days: 1))),
      SubscriptionAccessState.expired);
    expect(active.state, SubscriptionAccessState.active);
    expect(active.profileCount, 2);
    for (final state in ['expired', 'revoked']) {
      final status = SubscriptionStatus.fromPlatform({
        ..._status(), 'subscriptions': [_wireGuardEntry(state: state)],
      });
      final value = status.subscriptions.single;
      final expected = state == 'expired'
          ? SubscriptionAccessState.expired : SubscriptionAccessState.revoked;
      expect(value.state, expected);
      expect(value.effectiveState(deadline.subtract(const Duration(days: 1))), expected);
      expect(value.effectiveState(deadline.add(const Duration(days: 1))), expected);
      expect(value.profileCount, 0);
      expect(status.errorCode, isNull);
      expect(status.refreshErrors, isEmpty);
    }
  });

  test('WireGuard metadata requires the bounded declared contract and rejects private extensions', () {
    final missingState = _wireGuardEntry()..remove('state');
    final missingExpiry = _wireGuardEntry()..remove('expiresAt');
    final invalidEntries = <Map<String, Object?>>[
      missingState, missingExpiry,
      for (final format in <Object?>[null, '', 'wireguard', 'wireguard-v2', 'VLESS', 1, true,
        'PRIVATE_FORMAT_TOKEN', <String, Object?>{}])
        {..._wireGuardEntry(), 'format': format},
      for (final state in <Object?>[null, '', 'ACTIVE', 'disabled', 0, true,
        'PRIVATE_STATE_TOKEN', <Object?>[]])
        {..._wireGuardEntry(), 'state': state},
      for (final expiry in <Object?>[null, 0, -1000, 1001, 1795464000000.0,
        '1795464000000', true, 253402300800000, <Object?>[]])
        {..._wireGuardEntry(), 'expiresAt': expiry},
      {..._entry(), 'state': 'revoked'},
      {..._entry(), 'format': 'vless', 'state': 'expired'},
      {..._wireGuardEntry(), 'profileCount': 0},
      {..._wireGuardEntry(state: 'expired'), 'profileCount': 1},
      {..._wireGuardEntry(state: 'revoked'), 'profileCount': 1},
      {..._wireGuardEntry(), 'skippedProfileCount': 1},
      {..._wireGuardEntry(), 'usedBytes': 0},
      {..._wireGuardEntry(), 'totalBytes': 1},
      for (final field in ['revision', 'providerEntryId', 'deviceId', 'config', 'url', 'token'])
        {..._wireGuardEntry(), field: 'PRIVATE_METADATA_TOKEN'},
    ];
    for (final entry in invalidEntries) {
      try {
        SubscriptionStatus.fromPlatform({..._status(), 'subscriptions': [entry]});
        fail('Invalid WireGuard metadata was accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString(), isNot(contains('PRIVATE_')));
      }
    }
  });

  test('WireGuard expiry accepts exact positive second bounds for every declared state', () {
    for (final state in ['active', 'expired', 'revoked']) {
      for (final expiry in [1000, 253402300799000]) {
        final value = SubscriptionStatus.fromPlatform({
          ..._status(), 'subscriptions': [{..._wireGuardEntry(state: state), 'expiresAt': expiry}],
        }).subscriptions.single;
        expect(value.expiresAt!.millisecondsSinceEpoch, expiry);
      }
    }
  });

  test('Inactive access is not a provider download failure and fixed errors do not imply disconnect', () {
    for (final code in ['SUBSCRIPTION_EXPIRED', 'SUBSCRIPTION_REVOKED']) {
      expect(() => SubscriptionStatus.fromPlatform({
        ..._status(), 'subscriptions': [_wireGuardEntry(state: 'expired')],
        'refreshErrors': {_id: code},
      }), throwsFormatException);
      final message = subscriptionErrorMessage(PlatformException(code: code,
        message: 'PRIVATE_PROVIDER_MESSAGE', details: 'PRIVATE_CONFIG'));
      expect(message, isNot(contains('WireGuard')));
      expect(message, contains(code == 'SUBSCRIPTION_EXPIRED' ? 'истёк' : 'отозван'));
      expect(message, isNot(contains('отключён')));
      expect(message, isNot(contains('PRIVATE_')));
    }
  });

  test('Skipped connection counts preserve legacy metadata and valid bounds', () {
    final legacy = SubscriptionStatus.fromPlatform(_status());
    expect(legacy.subscriptions.single.skippedProfileCount, 0);
    final manual = FlowSubscription(id: _id, name: 'Моя подписка',
      host: 'example.invalid', profileCount: 2,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1795377600000));
    expect(manual.skippedProfileCount, 0);
    for (final count in [0, 1, 199, 200]) {
      final status = SubscriptionStatus.fromPlatform({
        ..._status(),
        'subscriptions': [{..._entry(), 'skippedProfileCount': count}],
      });
      expect(status.subscriptions.single.skippedProfileCount, count);
      expect(status.subscriptions.single.profileCount, 2);
      expect(status.errorCode, isNull);
      expect(status.refreshErrors, isEmpty);
    }
  });

  test('Skipped connection metadata rejects invalid counts and private entry details', () {
    final invalidEntries = <Map<String, Object?>>[
      for (final count in <Object?>[-1, 201, 1000000, 1.0, '1', true, null,
        'https://example.invalid/PRIVATE_TOKEN',
        {'count': 1, 'url': 'PRIVATE_TOKEN'}, <Object?>[]])
        {..._entry(), 'skippedProfileCount': count},
      {..._entry(), 'skippedProfileCount': 1, 'skippedProfiles': ['PRIVATE_TOKEN']},
      {..._entry(), 'skippedProfileCount': 1, 'skippedUrls': ['PRIVATE_TOKEN']},
    ];
    for (final entry in invalidEntries) {
      try {
        SubscriptionStatus.fromPlatform({..._status(), 'subscriptions': [entry]});
        fail('Invalid skipped connection metadata was accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString(), isNot(contains('PRIVATE_TOKEN')));
      }
    }
  });

  test('Unsupported feed error explains that no compatible servers were found', () {
    final message = subscriptionErrorMessage(PlatformException(
      code: 'SUBSCRIPTION_UNSUPPORTED',
      message: 'https://example.invalid/PRIVATE_TOKEN', details: 'PRIVATE_CONFIG'));
    expect(message, startsWith('В подписке нет поддерживаемых подключений.'));
    expect(message, isNot(contains('WireGuard')));
    expect(message, isNot(contains('VLESS')));
    expect(message, isNot(contains('PRIVATE_')));
    expect(message, isNot(contains('example.invalid')));
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
