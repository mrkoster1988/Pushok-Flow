import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';
import 'package:pushok_flow/ui/wireguard_profile_editor.dart';

// Synthetic test data; the platform channel is mocked and never opens a VPN.
const _profile = '[Interface]\n'
    'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
    'Address = 192.0.2.2/32\n\n'
    '[Peer]\n'
    'PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n'
    'AllowedIPs = 0.0.0.0/0\n'
    'Endpoint = vpn.example:51820\n';

class _AndroidBridge {
  String? savedProfile;
  bool connected = false;
  bool failProfileExists = false;
  PlatformException? connectError;
  PlatformException? saveError;
  Object? privacyError;
  bool invalidPrivacyToken = false;
  Completer<void>? connectGate;
  Completer<void>? saveGate;
  Completer<String?>? loadGate;
  Completer<String>? privacyGate;
  final privacyTokens = <String>{};
  final calls = <MethodCall>[];

  List<MethodCall> named(String method) =>
      calls.where((call) => call.method == method).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'installedApps':
        return [{'packageName': 'example.browser', 'label': 'Test browser'}];
      case 'getBypass':
        return <String>[];
      case 'setBypass':
        return null;
      case 'aiFeedbackSummary':
        return <String, int>{};
      case 'savedProfileExists':
        if (failProfileExists) throw PlatformException(code: 'PROFILE_LOAD_FAILED');
        return savedProfile != null;
      case 'loadWireGuardProfile':
        if (loadGate != null) return await loadGate!.future;
        return savedProfile;
      case 'saveWireGuardProfile':
        if (saveGate != null) await saveGate!.future;
        if (saveError != null) throw saveError!;
        savedProfile = (call.arguments as Map)['config'] as String;
        return true;
      case 'deleteWireGuardProfile':
        savedProfile = null;
        return true;
      case 'connectWireGuard':
        if (connectGate != null) await connectGate!.future;
        if (connectError != null) throw connectError!;
        connected = true;
        return {'connected': true};
      case 'disconnectWireGuard':
        connected = false;
        return {'connected': false};
      case 'vpnStatus':
        return {
          'connected': connected,
          'state': connected ? 'connected' : 'disconnected',
          'uptimeSeconds': connected ? 12 : 0,
          'lastErrorCode': null,
        };
    }
    throw MissingPluginException(call.method);
  }

  Future<Object?> handlePrivacy(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'acquire':
        if (privacyError != null) throw privacyError!;
        if (invalidPrivacyToken) return '';
        final token = privacyGate == null
            ? 'test-lease-${named('acquire').length}' : await privacyGate!.future;
        privacyTokens.add(token);
        return token;
      case 'release':
        privacyTokens.remove((call.arguments as Map)['token']);
        return true;
    }
    throw MissingPluginException(call.method);
  }
}

Future<void> _withApp(WidgetTester tester, Future<void> Function() body) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(const PushokFlowApp(isAndroid: true));
  await tester.pumpAndSettle();
  try {
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  }
}

Future<void> _openRoutes(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar), matching: find.text('Маршруты'),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/app_routes');
  const privacyChannel = MethodChannel('shop.pushok.flow/profile_privacy');
  late _AndroidBridge bridge;

  setUp(() {
    bridge = _AndroidBridge();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, bridge.handle);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(privacyChannel, bridge.handlePrivacy);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(privacyChannel, null);
  });

  testWidgets('Connect without a profile opens setup without requesting VPN', (tester) async {
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(find.text('Сохранить и подключить'), findsOneWidget);
      expect(bridge.named('connectWireGuard'), isEmpty);

      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wireguard_profile_error')), findsOneWidget);
      expect(bridge.named('saveWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      await tester.tap(find.byKey(const Key('close_wireguard_profile')));
      await tester.pumpAndSettle();
      await _openRoutes(tester);
      expect(find.byKey(const Key('wireguard_profile_error')), findsNothing);
      expect(find.text('Test browser'), findsOneWidget);
    });
  });

  testWidgets('A stored profile connects after a cold start without opening editor', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      // Startup reads metadata only; decrypting the profile requires user action.
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect((bridge.named('connectWireGuard').single.arguments as Map)['config'], _profile);
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(bridge.named('acquire'), isEmpty);
      expect(find.text('Трафик подключён'), findsOneWidget);
      await _openRoutes(tester);
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.onChanged, isNull);
    });
  });

  testWidgets('Save and connect persists the new profile before starting VPN', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': _profile};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('paste_wireguard_profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.named('saveWireGuardProfile'), hasLength(1));
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect(bridge.calls.indexWhere((c) => c.method == 'saveWireGuardProfile'),
          lessThan(bridge.calls.indexWhere((c) => c.method == 'connectWireGuard')));
      expect(bridge.savedProfile, _profile);
      expect(find.text('Трафик подключён'), findsOneWidget);
    });
  });

  testWidgets('Profile validation failure stays in editor and preserves previous profile', (tester) async {
    bridge.savedProfile = _profile;
    bridge.saveError = PlatformException(code: 'INVALID_CONFIG', message: 'SECRET_MUST_NOT_APPEAR');
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toggle_wireguard_profile_visibility')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wireguard_profile_field')), '[broken]');
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wireguard_profile_error')), findsOneWidget);
      expect(find.textContaining('SECRET_MUST_NOT_APPEAR'), findsNothing);
      expect(bridge.savedProfile, _profile);
      expect(bridge.named('connectWireGuard'), isEmpty);
      final errorText = tester.widget<Text>(find.byKey(const Key('wireguard_profile_error'))).data!;
      await tester.tap(find.byKey(const Key('close_wireguard_profile')));
      await tester.pumpAndSettle();
      await _openRoutes(tester);
      expect(find.text(errorText), findsNothing);
      expect(find.text('Test browser'), findsOneWidget);
    });
  });

  testWidgets('Permission denial produces a visible safe connection message', (tester) async {
    bridge.savedProfile = _profile;
    bridge.connectError = PlatformException(code: 'VPN_DENIED', message: 'SECRET_MUST_NOT_APPEAR');
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connection_error')), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Разрешение VPN отклонено'), findsWidgets);
      expect(find.textContaining('SECRET_MUST_NOT_APPEAR'), findsNothing);
      expect(find.text('Статус: отключено'), findsOneWidget);
    });
  });

  testWidgets('Repeated taps do not start concurrent tunnel operations', (tester) async {
    bridge.savedProfile = _profile;
    bridge.connectGate = Completer<void>();
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pump();
      expect(bridge.named('connectWireGuard'), hasLength(1));
      bridge.connectGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Трафик подключён'), findsOneWidget);
    });
  });

  testWidgets('Polling pauses in background and resume refreshes a disconnected tunnel', (tester) async {
    bridge.savedProfile = _profile;
    bridge.connected = true;
    await _withApp(tester, () async {
      expect(find.text('Трафик подключён'), findsOneWidget);
      final polls = bridge.named('vpnStatus').length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 31));
      expect(bridge.named('vpnStatus'), hasLength(polls));
      bridge.connected = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Статус: отключено'), findsOneWidget);
      expect(bridge.named('vpnStatus').length, greaterThan(polls));
    });
  });

  testWidgets('Profile metadata failure does not hide native tunnel status', (tester) async {
    bridge.failProfileExists = true;
    bridge.connected = true;
    await _withApp(tester, () async {
      expect(find.text('Трафик подключён'), findsOneWidget);
      expect(bridge.named('vpnStatus'), isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Closing app during profile loading never starts a stale connection', (tester) async {
    bridge.savedProfile = _profile;
    bridge.loadGate = Completer<String?>();
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      bridge.loadGate!.complete(_profile);
      await tester.pumpAndSettle();
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  for (final profile in <String?>[_profile, null]) {
    testWidgets('Delayed Connect profile lookup cannot open VPN or editor after app switching (${profile == null ? 'missing' : 'stored'})', (tester) async {
      bridge.loadGate = Completer<String?>();
      await _withApp(tester, () async {
        await tester.tap(find.byKey(const Key('pushok_connect_button')));
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        bridge.loadGate!.complete(profile);
        await tester.pumpAndSettle();
        expect(bridge.named('connectWireGuard'), isEmpty);
        expect(bridge.named('acquire'), isEmpty);
        expect(find.byType(WireGuardProfileEditor), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('Editor waits for protection before loading and releases after its closing animation', (tester) async {
    bridge.savedProfile = _profile;
    bridge.privacyGate = Completer<String>();
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
      await tester.pump();
      expect(bridge.named('acquire'), hasLength(1));
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(find.byType(WireGuardProfileEditor), findsNothing);

      bridge.privacyGate!.complete('protected-editor');
      await tester.pumpAndSettle();
      expect(bridge.named('loadWireGuardProfile'), hasLength(1));
      expect(bridge.privacyTokens, {'protected-editor'});
      await tester.tap(find.byKey(const Key('toggle_wireguard_profile_visibility')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close_wireguard_profile')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(bridge.named('release'), isEmpty);
      expect(bridge.privacyTokens, isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(bridge.privacyTokens, isEmpty);
      expect(bridge.named('release'), hasLength(1));
      expect((bridge.named('release').single.arguments as Map)['token'], 'protected-editor');
      expect(tester.takeException(), isNull);
    });
  });

  for (final failure in ['platform error', 'missing plugin', 'empty token']) {
    testWidgets('Privacy $failure keeps the profile unopened and reports no native details', (tester) async {
      bridge.savedProfile = _profile;
      if (failure == 'platform error') {
        bridge.privacyError = PlatformException(code: 'FAIL', message: 'SECRET_DETAIL');
      } else if (failure == 'missing plugin') {
        bridge.privacyError = MissingPluginException('SECRET_DETAIL');
      } else {
        bridge.invalidPrivacyToken = true;
      }
      await _withApp(tester, () async {
        await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
        await tester.pumpAndSettle();
        expect(find.byType(WireGuardProfileEditor), findsNothing);
        expect(bridge.named('loadWireGuardProfile'), isEmpty);
        expect(bridge.named('release'), isEmpty);
        expect(find.textContaining('Не удалось защитить экран профиля.'), findsOneWidget);
        expect(find.textContaining('SECRET_DETAIL'), findsNothing);
        // Failed protection does not leave the editor button busy forever.
        bridge.privacyError = null;
        bridge.invalidPrivacyToken = false;
        await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
        await tester.pumpAndSettle();
        expect(find.byType(WireGuardProfileEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }

  for (final waitFor in ['protection', 'profile load']) {
    testWidgets('App switching during $waitFor cancels a late editor and releases protection', (tester) async {
      bridge.savedProfile = _profile;
      if (waitFor == 'protection') {
        bridge.privacyGate = Completer<String>();
      } else {
        bridge.loadGate = Completer<String?>();
      }
      await _withApp(tester, () async {
        await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        bridge.privacyGate?.complete('late-lease');
        bridge.loadGate?.complete(_profile);
        await tester.pumpAndSettle();
        expect(find.byType(WireGuardProfileEditor), findsNothing);
        expect(bridge.privacyTokens, isEmpty);
        expect(bridge.named('release'), hasLength(1));
        if (waitFor == 'protection') expect(bridge.named('loadWireGuardProfile'), isEmpty);
        expect(bridge.named('connectWireGuard'), isEmpty);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('Disposed app releases a late protection acknowledgement without reading the key', (tester) async {
    bridge.privacyGate = Completer<String>();
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      bridge.privacyGate!.complete('disposed-lease');
      await tester.pumpAndSettle();
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('release'), hasLength(1));
      expect(bridge.privacyTokens, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Disposing an open editor releases its protection even without a pop result', (tester) async {
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('configure_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.privacyTokens, isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(bridge.privacyTokens, isEmpty);
      expect(bridge.named('release'), hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Save started before app switching preserves the profile without starting a late VPN request', (tester) async {
    bridge.saveGate = Completer<void>();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': _profile};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('paste_wireguard_profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      bridge.saveGate!.complete();
      await tester.pumpAndSettle();
      expect(bridge.savedProfile, _profile);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.privacyTokens, isEmpty);
      expect(find.text('Профиль сохранён. Нажмите «Подключить», когда будете готовы.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
