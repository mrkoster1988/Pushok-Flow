import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';
import 'package:pushok_flow/ui/wireguard_profile_editor.dart';
import 'package:pushok_flow/ui/tunnel_diagnostics_card.dart';

// Synthetic test data; the platform channel is mocked and never opens a VPN.
const _profile = '[Interface]\n'
    'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
    'Address = 192.0.2.2/32\n\n'
    '[Peer]\n'
    'PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n'
    'AllowedIPs = 0.0.0.0/0\n'
    'Endpoint = vpn.example:51820\n';

Map<String, Object?> _statistics({int rx = 2048, int tx = 1024, int? age = 5}) => {
  'status': 'available',
  'rxBytes': rx,
  'txBytes': tx,
  'latestHandshakeAgeSeconds': age,
  'handshakeStatus': age == null ? 'never' : 'observed',
};

Map<String, Object?> _snapshot({bool active = true, int rx = 2048}) => {
  'connected': active,
  'state': active ? 'connected' : 'disconnected',
  'uptimeSeconds': active ? 12 : 0,
  'lastErrorCode': null,
  'statistics': active ? _statistics(rx: rx) : {'status': 'inactive'},
};

const _firstProfileId = '11111111-1111-4111-8111-111111111111';
const _secondProfileId = '22222222-2222-4222-8222-222222222222';

class _AndroidBridge {
  final profiles = <String, Map<String, String>>{};
  String? activeProfileId;
  int _nextProfileId = 0;
  String? get savedProfile => profiles[activeProfileId]?['config'];
  set savedProfile(String? config) {
    if (config == null) {
      profiles.clear();
      activeProfileId = null;
    } else {
      activeProfileId ??= _firstProfileId;
      profiles[activeProfileId!] = {'name': 'Мой профиль', 'config': config};
    }
  }
  Map<String, Object?> get catalog => {
    'profiles': [for (final entry in profiles.entries)
      {'id': entry.key, 'name': entry.value['name']}],
    'activeProfileId': activeProfileId,
  };
  Completer<Object?>? catalogGate;
  Object? loadError;
  Object? mutationError;
  bool connected = false;
  bool failProfileExists = false;
  PlatformException? connectError;
  PlatformException? saveError;
  Object? privacyError;
  Object? statusError;
  Object? bypassReadError;
  Set<String> bypassPackages = {};
  Set<String> unavailablePackages = {};
  String? statusState;
  bool? statusConnected;
  Map<String, Object?> statistics = _statistics();
  bool invalidPrivacyToken = false;
  Completer<void>? connectGate;
  Completer<void>? saveGate;
  Completer<String?>? loadGate;
  Completer<String>? privacyGate;
  Completer<Object?>? statusGate;
  Completer<String?>? importGate;
  String? importedProfile = _profile;
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
        return bypassPackages.toList();
      case 'getBypassStatus':
        if (bypassReadError != null) throw bypassReadError!;
        return {'packages': bypassPackages.toList(),
          'unavailablePackages': unavailablePackages.intersection(bypassPackages).toList()};
      case 'setBypass':
        return null;
      case 'aiFeedbackSummary':
        return <String, int>{};
      case 'savedProfileExists':
        if (failProfileExists) throw PlatformException(code: 'PROFILE_LOAD_FAILED');
        return savedProfile != null;
      case 'listWireGuardProfiles':
        if (failProfileExists) throw PlatformException(code: 'PROFILE_LOAD_FAILED',
            message: 'PRIVATE_CATALOG_DETAILS');
        if (catalogGate != null) return await catalogGate!.future;
        return catalog;
      case 'loadWireGuardProfile':
        if (loadError != null) throw loadError!;
        if (loadGate != null) return await loadGate!.future;
        final id = (call.arguments as Map?)?['profileId'] ?? activeProfileId;
        return profiles[id]?['config'];
      case 'importWireGuardProfile':
        if (privacyTokens.isEmpty) {
          throw PlatformException(code: 'PROFILE_IMPORT_UNAVAILABLE');
        }
        if (importGate != null) return await importGate!.future;
        return importedProfile;
      case 'cancelWireGuardProfileImport':
        return null;
      case 'saveWireGuardProfile':
        if (saveGate != null) await saveGate!.future;
        if (saveError != null) throw saveError!;
        final args = call.arguments as Map;
        final String id = args['createNew'] == true
            ? '00000000-0000-4000-8000-${(++_nextProfileId).toString().padLeft(12, '0')}'
            : args['profileId'] as String? ?? activeProfileId ?? _firstProfileId;
        profiles[id] = {'name': args['name'] as String? ?? 'Мой профиль',
          'config': args['config'] as String};
        activeProfileId ??= id;
        return true;
      case 'selectWireGuardProfile':
        if (mutationError != null) throw mutationError!;
        activeProfileId = (call.arguments as Map)['profileId'] as String;
        return true;
      case 'deleteWireGuardProfile':
        if (mutationError != null) throw mutationError!;
        final id = (call.arguments as Map?)?['profileId'] ?? activeProfileId;
        profiles.remove(id);
        if (id == activeProfileId) {
          activeProfileId = profiles.isEmpty ? null : profiles.keys.first;
        }
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
        if (statusError != null) throw statusError!;
        if (statusGate != null) return await statusGate!.future;
        return {
          'connected': statusConnected ?? connected,
          'state': statusState ?? (connected ? 'connected' : 'disconnected'),
          'uptimeSeconds': connected ? 12 : 0,
          'lastErrorCode': null,
          'statistics': connected ? statistics : {'status': 'inactive'},
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
  await tester.pumpWidget(const PushokFlowApp(isAndroid: true, animationsEnabled: false));
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
  await _closeInformation(tester);
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar), matching: find.text('Маршруты'),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openServers(WidgetTester tester) async {
  await _closeInformation(tester);
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar), matching: find.text('Серверы'),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openProfileEditor(WidgetTester tester) async {
  if (find.byKey(const Key('wireguard_profiles_card')).evaluate().isEmpty) {
    await _openServers(tester);
  }
  final edit = find.byKey(const Key('edit_wireguard_profile_$_firstProfileId'));
  final button = edit.evaluate().isEmpty
      ? find.byKey(const Key('add_wireguard_profile')) : edit;
  await tester.ensureVisible(button);
  await tester.tap(button);
}

Future<void> _showDiagnostics(WidgetTester tester) async {
  if (find.byKey(const Key('app_information_sheet')).evaluate().isEmpty) {
    expect(find.byKey(const Key('tunnel_diagnostics_card')), findsNothing);
    await tester.tap(find.byKey(const Key('open_app_information')));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.byKey(const Key('tunnel_diagnostics_card')));
  await tester.pumpAndSettle();
}

Future<void> _closeInformation(WidgetTester tester) async {
  final close = find.byKey(const Key('close_app_information'));
  if (close.evaluate().isEmpty) return;
  await tester.tap(close);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('app_information_sheet')), findsNothing);
  expect(find.byKey(const Key('tunnel_diagnostics_card')), findsNothing);
}

String? _diagnosticValue(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data;

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

  testWidgets('Unavailable exclusion failure offers route repair without dropping saved apps', (tester) async {
    bridge.savedProfile = _profile;
    bridge.bypassPackages = {'example.hidden', 'example.deleted'};
    bridge.unavailablePackages = {'example.deleted'};
    bridge.connectError = PlatformException(code: 'ROUTES_APPS_UNAVAILABLE',
      message: 'PRIVATE_PLATFORM_DETAILS', details: {'privateKey': 'SECRET'});
    await _withApp(tester, () async {
      final previousReads = bridge.named('getBypassStatus').length;
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Android не подтвердил доступность некоторых приложений.'), findsOneWidget);
      expect(find.textContaining('PRIVATE_PLATFORM_DETAILS'), findsNothing);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(bridge.named('getBypassStatus').length, greaterThan(previousReads));
      expect(bridge.named('setBypass'), isEmpty);
      await tester.tap(find.byKey(const Key('open_routes_after_connection_error')));
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('routes_filter_unavailable'))).selected, isTrue);
      final toggle = find.byKey(const Key('route_toggle_example.deleted'));
      await tester.scrollUntilVisible(toggle, 140, scrollable: find.descendant(
        of: find.byKey(const Key('routes_list')), matching: find.byType(Scrollable)).first);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(bridge.bypassPackages, {'example.hidden', 'example.deleted'});
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

  testWidgets('Failed availability lookup offers retry without inventing unavailable apps', (tester) async {
    bridge.savedProfile = _profile;
    bridge.bypassPackages = {'example.hidden'};
    bridge.connectError = PlatformException(code: 'ROUTES_APPS_CHECK_FAILED',
      message: 'PRIVATE_PLATFORM_DETAILS');
    bridge.bypassReadError = bridge.connectError;
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось проверить приложения в исключениях.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('open_routes_after_connection_error')));
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
      expect(find.byKey(const Key('routes_unavailable_summary')), findsNothing);
      expect(find.byKey(const Key('routes_filter_unavailable')), findsNothing);
      expect(find.textContaining('Не удалось проверить доступность приложений.'), findsOneWidget);
      expect(find.textContaining('PRIVATE_PLATFORM_DETAILS'), findsNothing);
      expect(bridge.bypassPackages, {'example.hidden'});
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.named('connectWireGuard'), hasLength(1));
    });
  });

  testWidgets('Connect without a profile opens setup without requesting VPN', (tester) async {
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(find.text('Сохранить и подключить'), findsOneWidget);
      expect(bridge.named('connectWireGuard'), isEmpty);

      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
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

  testWidgets('Initial status must finish before a missing profile can open setup', (tester) async {
    final pending = Completer<Object?>();
    bridge.statusGate = pending;
    await _withApp(tester, () async {
      final connect = find.byKey(const Key('pushok_connect_button'));
      expect(bridge.named('vpnStatus'), hasLength(1));
      expect(tester.widget<InkWell>(connect).onTap, isNull);
      await tester.tap(connect);
      await tester.pump();
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('acquire'), isEmpty);
      expect(find.byType(WireGuardProfileEditor), findsNothing);

      bridge.statusGate = null;
      pending.complete(_snapshot(active: false));
      await tester.pumpAndSettle();
      // Waiting never queues a connection or opens the editor automatically.
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(tester.widget<InkWell>(connect).onTap, isNotNull);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(find.text('Сохранить и подключить'), findsOneWidget);
      expect(bridge.named('acquire'), hasLength(1));
      expect(bridge.named('connectWireGuard'), isEmpty);
    });
  });

  testWidgets('Delayed startup status discovers an existing tunnel without reconnecting it', (tester) async {
    bridge.savedProfile = _profile;
    bridge.connected = true;
    final pending = Completer<Object?>();
    bridge.statusGate = pending;
    await _withApp(tester, () async {
      final connect = find.byKey(const Key('pushok_connect_button'));
      expect(tester.widget<InkWell>(connect).onTap, isNull);
      await tester.tap(connect);
      await tester.pump();
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('disconnectWireGuard'), isEmpty);

      bridge.statusGate = null;
      pending.complete(_snapshot());
      await tester.pumpAndSettle();
      expect(find.text('Отключить'), findsOneWidget);
      expect(tester.widget<InkWell>(connect).onTap, isNotNull);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('disconnectWireGuard'), hasLength(1));
      expect(find.text('Статус: отключено'), findsOneWidget);
    });
  });

  testWidgets('A stored profile connects after a cold start without opening editor', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      // Startup transfers metadata only; no configuration text crosses the channel.
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect((bridge.named('connectWireGuard').single.arguments as Map)['config'], _profile);
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(bridge.named('acquire'), isEmpty);
      expect(find.text('Туннель включён'), findsOneWidget);
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
      await tester.ensureVisible(find.byKey(const Key('paste_wireguard_profile')));
      await tester.tap(find.byKey(const Key('paste_wireguard_profile')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.named('saveWireGuardProfile'), hasLength(1));
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect(bridge.calls.indexWhere((c) => c.method == 'saveWireGuardProfile'),
          lessThan(bridge.calls.indexWhere((c) => c.method == 'connectWireGuard')));
      expect(bridge.savedProfile, _profile);
      expect(find.text('Туннель включён'), findsOneWidget);
    });
  });

  testWidgets('Profile validation failure stays in editor and preserves previous profile', (tester) async {
    bridge.savedProfile = _profile;
    bridge.saveError = PlatformException(code: 'INVALID_CONFIG', message: 'SECRET_MUST_NOT_APPEAR');
    await _withApp(tester, () async {
      await _openProfileEditor(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('toggle_wireguard_profile_visibility')));
      await tester.tap(find.byKey(const Key('toggle_wireguard_profile_visibility')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wireguard_profile_field')), '[broken]');
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
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
      expect(find.byKey(const Key('connection_error')), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Разрешение VPN отклонено'), findsWidgets);
      expect(find.textContaining('SECRET_MUST_NOT_APPEAR'), findsNothing);
      expect(find.text('Статус: отключено'), findsOneWidget);
      await _showDiagnostics(tester);
      expect(find.byKey(const Key('connection_error')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('connection_error'))).data,
          contains('Разрешение VPN отклонено'));
      expect(find.textContaining('SECRET_MUST_NOT_APPEAR'), findsNothing);
      await _closeInformation(tester);
      expect(find.byKey(const Key('connection_error')), findsNothing);
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
      expect(find.text('Туннель включён'), findsOneWidget);
    });
  });

  testWidgets('Polling pauses in background and resume refreshes a disconnected tunnel', (tester) async {
    bridge.savedProfile = _profile;
    bridge.connected = true;
    await _withApp(tester, () async {
      expect(find.text('Туннель включён'), findsOneWidget);
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

  testWidgets('Resume waits for current status before offering a new connection', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      final connect = find.byKey(const Key('pushok_connect_button'));
      expect(tester.widget<InkWell>(connect).onTap, isNotNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.connected = true;
      final pending = Completer<Object?>();
      bridge.statusGate = pending;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Статус уточняется'), findsOneWidget);
      expect(tester.widget<InkWell>(connect).onTap, isNull);
      await tester.tap(connect);
      await tester.pump();
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('disconnectWireGuard'), isEmpty);

      bridge.statusGate = null;
      pending.complete(_snapshot());
      await tester.pumpAndSettle();
      expect(find.text('Отключить'), findsOneWidget);
      expect(tester.widget<InkWell>(connect).onTap, isNotNull);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('disconnectWireGuard'), isEmpty);
    });
  });

  testWidgets('An unreadable native state blocks new connections until an explicit retry', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      bridge.connectError = PlatformException(code: 'VPN_STATE_UNAVAILABLE',
          message: 'SECRET_NATIVE_DETAIL');
      bridge.statusState = 'unknown';
      final connect = find.byKey(const Key('pushok_connect_button'));
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect(find.textContaining('Не удалось уточнить состояние туннеля'), findsWidgets);
      expect(find.textContaining('SECRET_NATIVE_DETAIL'), findsNothing);
      expect(tester.widget<InkWell>(connect).onTap, isNull);
      await tester.tap(connect);
      await tester.pump();
      expect(bridge.named('connectWireGuard'), hasLength(1));

      bridge.connectError = null;
      bridge.statusState = null;
      await _showDiagnostics(tester);
      await _closeInformation(tester);
      expect(tester.widget<InkWell>(connect).onTap, isNotNull);
      expect(bridge.named('connectWireGuard'), hasLength(1));
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(bridge.named('connectWireGuard'), hasLength(2));
      expect(find.text('Туннель включён'), findsOneWidget);
    });
  });

  testWidgets('Profile metadata failure does not hide native tunnel status', (tester) async {
    bridge.failProfileExists = true;
    bridge.connected = true;
    await _withApp(tester, () async {
      expect(find.text('Туннель включён'), findsOneWidget);
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
      bridge.savedProfile = _profile;
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
      await _openProfileEditor(tester);
      await tester.pump();
      expect(bridge.named('acquire'), hasLength(1));
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(find.byType(WireGuardProfileEditor), findsNothing);

      bridge.privacyGate!.complete('protected-editor');
      await tester.pumpAndSettle();
      expect(bridge.named('loadWireGuardProfile'), hasLength(1));
      expect(bridge.privacyTokens, {'protected-editor'});
      await tester.ensureVisible(find.byKey(const Key('toggle_wireguard_profile_visibility')));
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
        await _openProfileEditor(tester);
        await tester.pumpAndSettle();
        expect(find.byType(WireGuardProfileEditor), findsNothing);
        expect(bridge.named('loadWireGuardProfile'), isEmpty);
        expect(bridge.named('release'), isEmpty);
        expect(find.textContaining('Не удалось защитить экран профиля.'), findsOneWidget);
        expect(find.textContaining('SECRET_DETAIL'), findsNothing);
        // Failed protection does not leave the editor button busy forever.
        bridge.privacyError = null;
        bridge.invalidPrivacyToken = false;
        await _openProfileEditor(tester);
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
        await _openProfileEditor(tester);
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
      await _openProfileEditor(tester);
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
      await _openProfileEditor(tester);
      await tester.pumpAndSettle();
      expect(bridge.privacyTokens, isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(bridge.privacyTokens, isEmpty);
      expect(bridge.named('release'), hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Live diagnostics show measured bytes and recover after a safe read failure', (tester) async {
    bridge.connected = true;
    await _withApp(tester, () async {
      expect(find.text('Туннель включён'), findsOneWidget);
      expect(find.text('Трафик подключён'), findsNothing);
      await _showDiagnostics(tester);
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '2,0 КиБ');
      expect(_diagnosticValue(tester, 'tunnel_tx_value'), '1,0 КиБ');
      expect(_diagnosticValue(tester, 'tunnel_handshake_value'), '5 сек назад');

      bridge.statusError = PlatformException(code: 'NATIVE_FAILURE',
          message: 'PRIVATE_PROFILE_DETAIL', details: {'key': 'PRIVATE_PROFILE_DETAIL'});
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pumpAndSettle();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '—');
      expect(find.textContaining('PRIVATE_PROFILE_DETAIL'), findsNothing);
      expect(tester.widget<TunnelDiagnosticsCard>(find.byType(TunnelDiagnosticsCard)).stale, isTrue);

      bridge.statusError = null;
      bridge.statistics = _statistics(rx: 4096, tx: 0, age: null);
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pumpAndSettle();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '4,0 КиБ');
      expect(_diagnosticValue(tester, 'tunnel_tx_value'), '0 Б');
      expect(_diagnosticValue(tester, 'tunnel_handshake_value'), 'Ещё не зафиксировано');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('A late pre-disconnect sample cannot restore the previous connection or counters', (tester) async {
    bridge.connected = true;
    await _withApp(tester, () async {
      await _showDiagnostics(tester);
      final pending = Completer<Object?>();
      bridge.statusGate = pending;
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pump();
      // Closing the panel leaves the read pending while the user performs the
      // newer disconnect operation on Home.
      await _closeInformation(tester);
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pump();
      expect(bridge.named('disconnectWireGuard'), hasLength(1));
      bridge.statusGate = null;
      pending.complete(_snapshot(rx: 999999));
      await tester.pumpAndSettle();
      expect(find.text('Статус: отключено'), findsOneWidget);
      expect(find.text('Туннель включён'), findsNothing);
      await _showDiagnostics(tester);
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '—');
      expect(_diagnosticValue(tester, 'tunnel_handshake_value'), 'Нет активного туннеля');
      expect(bridge.named('vpnStatus').length, greaterThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Returning to the app replaces a delayed background sample with a new reading', (tester) async {
    bridge.connected = true;
    await _withApp(tester, () async {
      await _showDiagnostics(tester);
      final pending = Completer<Object?>();
      bridge.statusGate = pending;
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      bridge.statistics = _statistics(rx: 8192);
      bridge.statusGate = null;
      pending.complete(_snapshot(rx: 999999));
      await tester.pumpAndSettle();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '8,0 КиБ');
      expect(tester.widget<TunnelDiagnosticsCard>(find.byType(TunnelDiagnosticsCard)).stale, isFalse);
      expect(bridge.named('vpnStatus').length, greaterThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Unknown native state cannot silently drop a known active tunnel or expose old metrics', (tester) async {
    bridge.connected = true;
    await _withApp(tester, () async {
      await _showDiagnostics(tester);
      bridge.statusState = 'unknown';
      bridge.statusConnected = false;
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pumpAndSettle();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '—');
      expect(_diagnosticValue(tester, 'tunnel_handshake_value'), 'Данные недоступны');
      await _closeInformation(tester);
      expect(find.text('Отключить'), findsOneWidget);
      expect(find.text('Туннель включён'), findsNothing);
      expect(find.text('Статус уточняется'), findsOneWidget);
      final connect = find.byKey(const Key('pushok_connect_button'));
      expect(tester.widget<InkWell>(connect).onTap, isNotNull);
      expect(bridge.named('disconnectWireGuard'), isEmpty);
      bridge.statusState = null;
      bridge.statusConnected = null;
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(bridge.named('disconnectWireGuard'), hasLength(1));
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(find.text('Статус: отключено'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('A diagnostic timeout hides stale data and ignores the eventual old response', (tester) async {
    bridge.connected = true;
    await _withApp(tester, () async {
      await _showDiagnostics(tester);
      final pending = Completer<Object?>();
      bridge.statusGate = pending;
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pump();
      expect(tester.widget<IconButton>(find.byKey(const Key('refresh_tunnel_diagnostics'))).onPressed, isNull);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '—');
      bridge.statusGate = null;
      pending.complete(_snapshot(rx: 999999));
      await tester.pumpAndSettle();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '—');
      await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
      await tester.pumpAndSettle();
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '2,0 КиБ');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Native transitions keep old counters hidden and prevent competing actions', (tester) async {
    bridge.connected = true;
    bridge.statusState = 'transitioning';
    await _withApp(tester, () async {
      expect(find.text('Состояние изменяется'), findsOneWidget);
      expect(tester.widget<InkWell>(find.byKey(const Key('pushok_connect_button'))).onTap, isNull);
      await _showDiagnostics(tester);
      expect(_diagnosticValue(tester, 'tunnel_rx_value'), '—');
      await _openRoutes(tester);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged, isNull);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('disconnectWireGuard'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('File import uses the protected editor and requires explicit save', (tester) async {
    await _withApp(tester, () async {
      await _openProfileEditor(tester);
      await tester.pumpAndSettle();
      expect(bridge.privacyTokens, hasLength(1));
      await tester.ensureVisible(find.byKey(const Key('import_wireguard_profile')));
      await tester.tap(find.byKey(const Key('import_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.named('importWireGuardProfile'), hasLength(1));
      final field = tester.widget<TextField>(find.byKey(const Key('wireguard_profile_field')));
      expect(field.controller!.text, _profile);
      expect(field.obscureText, isTrue);
      expect(bridge.savedProfile, isNull);
      expect(bridge.named('saveWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.savedProfile, _profile);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.privacyTokens, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Explicit save and connect works after returning from the file picker', (tester) async {
    final pendingImport = Completer<String?>();
    bridge.importGate = pendingImport;
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('import_wireguard_profile')));
      await tester.tap(find.byKey(const Key('import_wireguard_profile')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      pendingImport.complete(_profile);
      await tester.pump();
      expect(bridge.named('saveWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(const Key('wireguard_profile_field')));
      expect(field.controller!.text, _profile);
      expect(field.obscureText, isTrue);
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.savedProfile, _profile);
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect(bridge.privacyTokens, isEmpty);
      expect(find.text('Туннель включён'), findsOneWidget);
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
      await tester.ensureVisible(find.byKey(const Key('paste_wireguard_profile')));
      await tester.tap(find.byKey(const Key('paste_wireguard_profile')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
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

  testWidgets('Selecting a named profile changes the next connection without opening its configuration', (tester) async {
    bridge.savedProfile = _profile;
    final secondConfig = _profile.replaceAll('vpn.example', 'second.example');
    bridge.profiles[_secondProfileId] = {'name': 'Запасной', 'config': secondConfig};
    await _withApp(tester, () async {
      await _openServers(tester);
      expect(find.text('Мой профиль'), findsOneWidget);
      expect(find.text('Запасной'), findsOneWidget);
      final select = find.byKey(const Key('select_wireguard_profile_$_secondProfileId'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(bridge.activeProfileId, _secondProfileId);
      expect(find.byKey(const Key('active_wireguard_profile_$_secondProfileId')), findsOneWidget);
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Главная')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      expect((bridge.named('connectWireGuard').single.arguments as Map)['config'], secondConfig);
      expect((bridge.named('connectWireGuard').single.arguments as Map)['expectedProfileId'], _secondProfileId);
      await _openServers(tester);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('add_wireguard_profile'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('edit_wireguard_profile_$_firstProfileId'))).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Adding a named imported profile preserves the active profile and requires explicit save', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      await _openServers(tester);
      await tester.tap(find.byKey(const Key('add_wireguard_profile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wireguard_profile_name')), '  Поездка  ');
      await tester.ensureVisible(find.byKey(const Key('import_wireguard_profile')));
      await tester.tap(find.byKey(const Key('import_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.profiles, hasLength(1));
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.profiles, hasLength(2));
      expect(bridge.activeProfileId, _firstProfileId);
      final args = bridge.named('saveWireGuardProfile').single.arguments as Map;
      expect(args['createNew'], isTrue);
      expect(args['name'], 'Поездка');
      expect(args.containsKey('profileId'), isFalse);
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(find.text('Поездка'), findsOneWidget);
      expect(bridge.privacyTokens, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Editing an inactive profile addresses its ID and keeps the active selection', (tester) async {
    bridge.savedProfile = _profile;
    final secondConfig = _profile.replaceAll('vpn.example', 'second.example');
    bridge.profiles[_secondProfileId] = {'name': 'Запасной', 'config': secondConfig};
    await _withApp(tester, () async {
      await _openServers(tester);
      await _showDiagnostics(tester);
      await _closeInformation(tester);
      final edit = find.byKey(const Key('edit_wireguard_profile_$_secondProfileId'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect((bridge.named('loadWireGuardProfile').single.arguments as Map)['profileId'], _secondProfileId);
      expect(tester.widget<TextField>(find.byKey(const Key('wireguard_profile_field'))).controller!.text, secondConfig);
      await tester.enterText(find.byKey(const Key('wireguard_profile_name')), 'Рабочий');
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.profiles[_secondProfileId], {'name': 'Рабочий', 'config': secondConfig});
      expect(bridge.activeProfileId, _firstProfileId);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect((bridge.named('saveWireGuardProfile').single.arguments as Map)['profileId'], _secondProfileId);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Deleting the active profile confirms its fallback and cancel preserves both profiles', (tester) async {
    bridge.savedProfile = _profile;
    bridge.profiles[_secondProfileId] = {'name': 'Запасной', 'config': _profile};
    await _withApp(tester, () async {
      await _openServers(tester);
      final remove = find.byKey(const Key('delete_wireguard_profile_$_firstProfileId'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.textContaining('будет выбран «Запасной»'), findsOneWidget);
      expect(bridge.named('deleteWireGuardProfile'), isEmpty);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(bridge.profiles, hasLength(2));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_delete_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.profiles.keys.toList(), [_secondProfileId]);
      expect(bridge.activeProfileId, _secondProfileId);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect((bridge.named('deleteWireGuardProfile').single.arguments as Map)['profileId'], _firstProfileId);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('A delete confirmation from before app switching cannot remove a profile', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      await _openServers(tester);
      final remove = find.byKey(const Key('delete_wireguard_profile_$_firstProfileId'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.byKey(const Key('confirm_delete_wireguard_profile')));
      await tester.pumpAndSettle();
      expect(bridge.named('deleteWireGuardProfile'), isEmpty);
      expect(bridge.savedProfile, _profile);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Unreadable existing profile never opens an empty replacement editor', (tester) async {
    bridge.savedProfile = _profile;
    bridge.loadError = PlatformException(code: 'PROFILE_LOAD_FAILED', message: 'SECRET_CONFIG');
    await _withApp(tester, () async {
      await _openProfileEditor(tester);
      await tester.pumpAndSettle();
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(bridge.named('saveWireGuardProfile'), isEmpty);
      expect(bridge.savedProfile, _profile);
      expect(bridge.privacyTokens, isEmpty);
      expect(find.textContaining('Не удалось открыть профиль.'), findsOneWidget);
      expect(find.textContaining('SECRET_CONFIG'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Catalog failure keeps existing names and disables edits until successful refresh', (tester) async {
    bridge.savedProfile = _profile;
    await _withApp(tester, () async {
      await _openServers(tester);
      bridge.failProfileExists = true;
      await tester.tap(find.byKey(const Key('refresh_wireguard_profiles')));
      await tester.pumpAndSettle();
      expect(find.text('Мой профиль'), findsOneWidget);
      expect(find.byKey(const Key('wireguard_profiles_error')), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('add_wireguard_profile'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('edit_wireguard_profile_$_firstProfileId'))).onPressed, isNull);
      expect(find.textContaining('PRIVATE_CATALOG_DETAILS'), findsNothing);
      bridge.failProfileExists = false;
      await tester.tap(find.byKey(const Key('refresh_wireguard_profiles')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wireguard_profiles_error')), findsNothing);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('edit_wireguard_profile_$_firstProfileId'))).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Native rejection of a stale selection keeps the original profile and hides raw errors', (tester) async {
    bridge.savedProfile = _profile;
    bridge.profiles[_secondProfileId] = {'name': 'Запасной', 'config': _profile};
    bridge.mutationError = PlatformException(code: 'VPN_ACTIVE', message: 'SECRET_NATIVE_DETAIL');
    await _withApp(tester, () async {
      await _openServers(tester);
      final select = find.byKey(const Key('select_wireguard_profile_$_secondProfileId'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(bridge.activeProfileId, _firstProfileId);
      expect(find.textContaining('Сначала отключите туннель'), findsOneWidget);
      expect(find.textContaining('SECRET_NATIVE_DETAIL'), findsNothing);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Post-save refresh blocks a duplicate tap while Save and Connect completes once', (tester) async {
    await _withApp(tester, () async {
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('import_wireguard_profile')));
      await tester.tap(find.byKey(const Key('import_wireguard_profile')));
      await tester.pumpAndSettle();
      final pending = Completer<Object?>();
      bridge.catalogGate = pending;
      await tester.ensureVisible(find.byKey(const Key('save_wireguard_profile')));
      await tester.tap(find.byKey(const Key('save_wireguard_profile')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      final connect = find.byKey(const Key('pushok_connect_button'));
      expect(tester.widget<InkWell>(connect).onTap, isNull);
      await tester.tap(connect);
      await tester.pump();
      expect(bridge.named('connectWireGuard'), isEmpty);
      bridge.catalogGate = null;
      pending.complete(bridge.catalog);
      await tester.pumpAndSettle();
      expect(bridge.named('disconnectWireGuard'), isEmpty);
      expect(bridge.named('connectWireGuard'), hasLength(1));
      expect(find.text('Туннель включён'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('A late pre-background catalog cannot restore an obsolete active profile', (tester) async {
    bridge.savedProfile = _profile;
    bridge.profiles[_secondProfileId] = {'name': 'Запасной', 'config': _profile};
    await _withApp(tester, () async {
      await _openServers(tester);
      final previous = bridge.catalog;
      final pending = Completer<Object?>();
      bridge.catalogGate = pending;
      await tester.tap(find.byKey(const Key('refresh_wireguard_profiles')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      bridge.activeProfileId = _secondProfileId;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      bridge.catalogGate = null;
      pending.complete(previous);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('active_wireguard_profile_$_firstProfileId')), findsNothing);
      expect(find.byKey(const Key('active_wireguard_profile_$_secondProfileId')), findsOneWidget);
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
