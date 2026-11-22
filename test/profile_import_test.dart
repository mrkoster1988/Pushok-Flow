import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/platform/profile_import.dart';
import 'package:pushok_flow/platform/wireguard_tunnel.dart';

const _profile = '[Interface]\nPrivateKey = UI_FIXTURE\n[Peer]\nPublicKey = UI_PEER\n';
const _vless = 'vless://00000000-0000-4000-8000-000000000001@example.invalid:443'
    '?type=tcp&security=tls#UI%20fixture';
const _subscription = 'https://example.invalid/sub/PRIVATE%2FKEY?token=a%2Bb+c';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Typed imports preserve profile bytes and subscription escapes', () {
    for (final config in [_profile, _vless]) {
      expect(ProfileImportPayload.read({'kind': 'profile', 'config': config}), config);
      expect(ProfileImportPayload.read(config), config);
    }
    expect(ProfileImportPayload.read({'kind': 'subscription', 'url': _subscription}),
        _subscription);
    expect(ProfileImportPayload.read(null), isNull);
  });

  test('Malformed bridge imports fail closed without returning private data', () {
    for (final raw in <Object?>[
      true, 42, <Object?>[], <String, Object?>{},
      {'kind': 'profile'},
      {'kind': 'profile', 'config': _profile, 'extra': 'PRIVATE_EXTRA'},
      {'kind': 'profile', 'config': _subscription},
      {'kind': 'profile', 'config': 'vmess://PRIVATE_KEY'},
      {'kind': 'profile', 'config': 42},
      {'kind': 'profile', 'config': 'PRIVATE\u0000KEY'},
      {'kind': 'profile', 'config': 'PRIVATE\u007fKEY'},
      {'kind': 'profile', 'config': 'я' * 32769},
      {'kind': 'profile', 'config': 'x' * 65537},
      {'kind': 'subscription', 'url': 'http://example.invalid/PRIVATE_KEY'},
      {'kind': 'subscription', 'url': 'https://u:PRIVATE_KEY@example.invalid/sub'},
      {'kind': 'subscription', 'url': 'https://example.invalid/#PRIVATE_KEY'},
      {'kind': 'subscription', 'url': ' https://example.invalid/PRIVATE_KEY'},
      {'kind': 'subscription', 'url': 'https://example.invalid/PRIVATE\nKEY'},
      {'kind': 'subscription', 'url': _subscription, 'config': _profile},
      {'kind': 'subscription', 'url': null},
      {'kind': 'PRIVATE_KIND', 'url': _subscription},
      '', '  ', 'PRIVATE\u0001KEY',
    ]) {
      expect(() => ProfileImportPayload.read(raw), throwsA(isA<FormatException>()
          .having((error) => error.message, 'fixed message',
              'Invalid imported connection data')
          .having((error) => error.source, 'no source payload', isNull)));
    }
  });

  for (final source in [
    ('importWireGuardProfile', WireGuardTunnel.importProfile),
    ('scanWireGuardProfileQr', WireGuardTunnel.scanProfileQr),
    ('importWireGuardProfileQrImage', WireGuardTunnel.importProfileQrImage),
  ]) {
    test('${source.$1} accepts both typed kinds and cancellation across the channel', () async {
      const channel = MethodChannel('shop.pushok.flow/app_routes');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Object? response;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        expect(call.arguments, isNull);
        return response;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      response = {'kind': 'profile', 'config': _profile};
      expect(await source.$2(), _profile);
      response = {'kind': 'subscription', 'url': _subscription};
      expect(await source.$2(), _subscription);
      response = null;
      expect(await source.$2(), isNull);
      response = _vless; // Compatibility with older bridges and existing callers.
      expect(await source.$2(), _vless);
      response = {'kind': 'subscription', 'url': _subscription, 'extra': 'PRIVATE_KEY'};
      await expectLater(source.$2(), throwsFormatException);
      expect(methods, List.filled(5, source.$1));
    });
  }
}
