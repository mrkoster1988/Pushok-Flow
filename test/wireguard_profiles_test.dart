import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/platform/wireguard_profiles.dart';
import 'package:pushok_flow/platform/wireguard_tunnel.dart';

const _firstId = '10000000-0000-4000-8000-000000000001';
const _secondId = '10000000-0000-4000-8000-000000000002';

Map<String, Object?> _catalog() => {
  'profiles': [
    {'id': _firstId, 'name': 'Дом'},
    {'id': _secondId, 'name': 'Работа'},
  ],
  'activeProfileId': _secondId,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Metadata preserves names and selected ID without mutable collections', () {
    final input = _catalog();
    final catalog = WireGuardProfiles.fromPlatform(input);
    expect(catalog.profiles.map((profile) => profile.name), ['Дом', 'Работа']);
    expect(catalog.activeProfileId, _secondId);
    expect(catalog.activeProfile?.name, 'Работа');
    expect(catalog.isFull, isFalse);
    expect(() => catalog.profiles.clear(), throwsUnsupportedError);
    (input['profiles']! as List).clear();
    expect(catalog.profiles.length, 2);
    expect(catalog.activeProfile?.id, _secondId);
  });

  test('An empty catalog has no selected profile', () {
    final parsed = WireGuardProfiles.fromPlatform({
      'profiles': <Object?>[], 'activeProfileId': null,
    });
    const empty = WireGuardProfiles.empty();
    expect(parsed.profiles, isEmpty);
    expect(parsed.activeProfile, isNull);
    expect(empty.profiles, isEmpty);
    expect(empty.isFull, isFalse);
  });

  test('Managed profiles expose ownership without exposing a subscription URL', () {
    final catalog = WireGuardProfiles.fromPlatform({
      'profiles': [{
        'id': _firstId, 'name': 'Сервер',
        'subscriptionId': _secondId, 'subscriptionName': 'Магазин',
      }],
      'activeProfileId': _firstId,
    });
    expect(catalog.activeProfile!.isManaged, isTrue);
    expect(catalog.activeProfile!.subscriptionName, 'Магазин');
    for (final invalid in [
      {'id': _firstId, 'name': 'Сервер', 'subscriptionId': _secondId},
      {'id': _firstId, 'name': 'Сервер', 'subscriptionName': 'Магазин'},
      {'id': _firstId, 'name': 'Сервер', 'subscriptionId': 'bad', 'subscriptionName': 'Магазин'},
    ]) {
      expect(() => WireGuardProfiles.fromPlatform({
        'profiles': [invalid], 'activeProfileId': _firstId,
      }), throwsFormatException);
    }
  });

  test('Incomplete, secret-bearing or ambiguous envelopes fail as a whole', () {
    for (final invalid in <Object?>[
      null,
      [],
      {},
      {'profiles': []},
      {'profiles': [], 'activeProfileId': null, 'config': 'PRIVATE_KEY'},
      {'profiles': 'not-a-list', 'activeProfileId': null},
      {'profiles': [], 'activeProfileId': 1},
      {'profiles': [], 'activeProfileId': _firstId},
      {..._catalog(), 'activeProfileId': null},
      {..._catalog(), 'activeProfileId': '10000000-0000-4000-8000-000000000099'},
    ]) {
      expect(() => WireGuardProfiles.fromPlatform(invalid), throwsFormatException);
    }
  });

  test('Invalid or duplicate entries do not yield a partially editable list', () {
    for (final entry in <Object?>[
      null,
      {'id': _secondId},
      {'id': _secondId, 'name': 'Работа', 'config': 'PRIVATE_KEY'},
      {'id': 'wrong-id', 'name': 'Работа'},
      {'id': 2, 'name': 'Работа'},
      {'id': _secondId, 'name': null},
      {'id': _firstId, 'name': 'Повтор ID'},
    ]) {
      expect(() => WireGuardProfiles.fromPlatform({
        'profiles': [ {'id': _firstId, 'name': 'Дом'}, entry ],
        'activeProfileId': _firstId,
      }), throwsFormatException);
    }
  });

  test('Names enforce Unicode scalar count and reject controls or untrimmed text', () {
    expect(WireGuardProfiles.isValidName('🐈' * 64), isTrue);
    expect(WireGuardProfiles.isValidName('🐈' * 65), isFalse);
    expect(WireGuardProfiles.isValidName('Дом / Работа — 2'), isTrue);
    for (final invalid in ['', ' ', ' Дом', 'Дом ', 'a' * 65,
        'Дом\nРабота', 'Дом\tРабота', 'Дом\u0000Работа', 'Дом\u007f',
        'Дом\u0085', 'Дом\u2028Работа', 'Дом\u2029Работа',
        String.fromCharCode(0xd800), String.fromCharCode(0xdfff)]) {
      expect(WireGuardProfiles.isValidName(invalid), isFalse);
      expect(() => WireGuardProfiles.fromPlatform({
        'profiles': [{'id': _firstId, 'name': invalid}],
        'activeProfileId': _firstId,
      }), throwsFormatException);
    }
  });

  test('Profile count is bounded and reaching the limit is represented', () {
    List<Map<String, String>> profiles(int count) => List.generate(count,
      (index) => {
        'id': '10000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
        'name': 'Профиль ${index + 1}',
      });
    final catalog = WireGuardProfiles.fromPlatform({
      'profiles': profiles(20), 'activeProfileId': _firstId,
    });
    expect(catalog.isFull, isTrue);
    expect(() => WireGuardProfiles.fromPlatform({
      'profiles': profiles(21), 'activeProfileId': _firstId,
    }), throwsFormatException);
  });

  test('Decode errors contain no rejected metadata or configuration', () {
    try {
      WireGuardProfiles.fromPlatform({
        'profiles': [{'id': _firstId, 'name': 'PRIVATE_NAME', 'config': 'PRIVATE_KEY'}],
        'activeProfileId': _firstId,
      });
      fail('Expected a constant error');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('PRIVATE_')));
      expect(error.source, isNull);
      expect(error.message, 'Invalid profile catalog');
    }
  });

  test('Bridge keeps list, explicit profile edits and active load separate', () async {
    const channel = MethodChannel('shop.pushok.flow/app_routes');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'listWireGuardProfiles') return _catalog();
      if (call.method == 'loadWireGuardProfile') return 'CONFIG_FIXTURE';
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final profiles = await WireGuardTunnel.listProfiles();
    expect(profiles.activeProfileId, _secondId);
    expect(calls.single.method, 'listWireGuardProfiles');
    expect(calls.single.arguments, isNull);
    await WireGuardTunnel.saveProfile('CONFIG_FIXTURE',
      profileId: _firstId, name: 'Дом');
    expect(calls.last.arguments, {
      'config': 'CONFIG_FIXTURE', 'profileId': _firstId, 'name': 'Дом',
    });
    await WireGuardTunnel.saveProfile('CONFIG_FIXTURE',
      name: 'Новый', createNew: true);
    expect(calls.last.arguments, {
      'config': 'CONFIG_FIXTURE', 'name': 'Новый', 'createNew': true,
    });
    await WireGuardTunnel.loadProfile(profileId: _firstId);
    expect(calls.last.arguments, {'profileId': _firstId});
    await WireGuardTunnel.loadProfile();
    expect(calls.last.arguments, isNull);
    await WireGuardTunnel.selectProfile(_firstId);
    expect(calls.last.method, 'selectWireGuardProfile');
    expect(calls.last.arguments, {'profileId': _firstId});
    await WireGuardTunnel.deleteProfile(profileId: _secondId);
    expect(calls.last.arguments, {'profileId': _secondId});
    expect(calls.where((call) => call.method == 'connectWireGuard'), isEmpty);
  });

  test('QR bridge uses explicit camera and image actions and preserves cancellation', () async {
    const channel = MethodChannel('shop.pushok.flow/app_routes');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var cancelled = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'scanWireGuardProfileQr') {
        return cancelled ? null : 'CAMERA_CONFIG_FIXTURE';
      }
      if (call.method == 'importWireGuardProfileQrImage') {
        return cancelled ? null : 'IMAGE_CONFIG_FIXTURE';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await WireGuardTunnel.scanProfileQr(), 'CAMERA_CONFIG_FIXTURE');
    expect(await WireGuardTunnel.importProfileQrImage(), 'IMAGE_CONFIG_FIXTURE');
    cancelled = true;
    expect(await WireGuardTunnel.scanProfileQr(), isNull);
    expect(await WireGuardTunnel.importProfileQrImage(), isNull);
    await WireGuardTunnel.cancelProfileImport();
    expect(calls.map((call) => call.method), [
      'scanWireGuardProfileQr', 'importWireGuardProfileQrImage',
      'scanWireGuardProfileQr', 'importWireGuardProfileQrImage',
      'cancelWireGuardProfileImport',
    ]);
    expect(calls.every((call) => call.arguments == null), isTrue);
  });
}
