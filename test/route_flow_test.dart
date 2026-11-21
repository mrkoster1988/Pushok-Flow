import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';

class _RoutesBridge {
  final calls = <MethodCall>[];
  Set<String> selected = {'example.mail'};
  Completer<Object?>? nextRead;
  Completer<void>? writeGate;
  Object? appsError;
  Object? readError;
  Object? writeError;
  void Function()? beforeWrite;
  bool connected = false;
  String? statusState;

  List<MethodCall> named(String method) =>
      calls.where((call) => call.method == method).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'installedApps':
        if (appsError != null) throw appsError!;
        return [
          {'packageName': 'example.browser', 'label': 'Браузер'},
          {'packageName': 'example.mail', 'label': 'Почта'},
        ];
      case 'getBypass':
        if (readError != null) throw readError!;
        final read = nextRead;
        nextRead = null;
        if (read != null) return read.future;
        return selected.toList();
      case 'setBypass':
        if (writeGate != null) await writeGate!.future;
        beforeWrite?.call();
        if (writeError != null) throw writeError!;
        final args = call.arguments as Map;
        final expected = Set<String>.from(args['expectedPackages'] as List);
        if (expected.length != selected.length || !expected.containsAll(selected)) {
          throw PlatformException(code: 'ROUTES_CHANGED', message: 'PRIVATE_PLATFORM_DETAILS');
        }
        selected = Set<String>.from(args['packages'] as List);
        return null;
      case 'listWireGuardProfiles':
        return {'profiles': <Object>[], 'activeProfileId': null};
      case 'vpnStatus':
        return {
          'connected': connected,
          'state': statusState ?? (connected ? 'connected' : 'disconnected'),
          'uptimeSeconds': 0,
          'lastErrorCode': null,
          'statistics': {'status': 'inactive'},
        };
      case 'aiFeedbackSummary':
        return <String, int>{};
      case 'connectWireGuard':
        connected = true;
        return {'connected': true};
    }
    throw MissingPluginException(call.method);
  }
}

Future<void> _nav(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar), matching: find.text(label),
  ));
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 180,
      scrollable: find.descendant(of: find.byKey(const Key('routes_list')),
        matching: find.byType(Scrollable)).first);
  }
  await tester.ensureVisible(finder);
  await tester.pump();
}

Finder _toggle(String package) => find.byKey(Key('route_toggle_$package'));

Future<void> _withRoutes(WidgetTester tester, Future<void> Function() body) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(const PushokFlowApp(isAndroid: true));
  await tester.pumpAndSettle();
  await _nav(tester, 'Маршруты');
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/app_routes');
  late _RoutesBridge bridge;
  setUp(() {
    bridge = _RoutesBridge();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, bridge.handle);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  testWidgets('route switch saves expected snapshot and waits for native acknowledgement', (tester) async {
    await _withRoutes(tester, () async {
      bridge.writeGate = Completer<void>();
      final toggle = _toggle('example.browser');
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(bridge.named('setBypass'), hasLength(1));
      final args = bridge.named('setBypass').single.arguments as Map;
      expect(args['expectedPackages'], ['example.mail']);
      expect(args['packages'], ['example.browser', 'example.mail']);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      bridge.writeGate!.complete();
      await tester.pumpAndSettle();
      await _reveal(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    });
  });

  testWidgets('native compare-and-set conflict refreshes actual choice without overwriting it', (tester) async {
    await _withRoutes(tester, () async {
      bridge.beforeWrite = () => bridge.selected = {'example.browser', 'example.hidden'};
      final toggle = _toggle('example.browser');
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(bridge.selected, {'example.browser', 'example.hidden'});
      expect(bridge.named('setBypass'), hasLength(1));
      expect(find.textContaining('PRIVATE_PLATFORM_DETAILS'), findsNothing);
      await _reveal(tester, _toggle('example.hidden'));
      expect(tester.widget<SwitchListTile>(_toggle('example.hidden')).value, isTrue);
      expect(find.textContaining('Список исключений изменился.'), findsOneWidget);
    });
  });

  testWidgets('failed durable write retains previous selection and blocks more edits', (tester) async {
    await _withRoutes(tester, () async {
      bridge.writeError = PlatformException(code: 'ROUTES_STORE_UNAVAILABLE',
        message: 'PRIVATE_PLATFORM_DETAILS');
      bridge.beforeWrite = () => bridge.readError = bridge.writeError;
      final toggle = _toggle('example.browser');
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _reveal(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      expect(bridge.selected, {'example.mail'});
      expect(find.textContaining('PRIVATE_PLATFORM_DETAILS'), findsNothing);
      expect(find.textContaining('Перезапустите приложение'), findsWidgets);
    });
  });

  testWidgets('refresh failure retains visible choices and retry restores editing', (tester) async {
    await _withRoutes(tester, () async {
      bridge.appsError = PlatformException(code: 'APPS_LOAD_FAILED');
      final refresh = find.byKey(const Key('refresh_routes'));
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.mail'));
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).value, isTrue);
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).onChanged, isNull);
      bridge.appsError = null;
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.mail'));
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).onChanged, isNotNull);
    });
  });

  testWidgets('older read after app switch cannot replace the newer choice', (tester) async {
    await _withRoutes(tester, () async {
      final oldRead = Completer<Object?>();
      bridge.nextRead = oldRead;
      final refresh = find.byKey(const Key('refresh_routes'));
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      bridge.selected = {'example.browser'};
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      oldRead.complete(['example.mail']);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.browser'));
      expect(tester.widget<SwitchListTile>(_toggle('example.browser')).value, isTrue);
      await _reveal(tester, _toggle('example.mail'));
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).value, isFalse);
    });
  });

  testWidgets('background save reply re-reads selection when returning', (tester) async {
    await _withRoutes(tester, () async {
      bridge.writeGate = Completer<void>();
      await _reveal(tester, _toggle('example.browser'));
      await tester.tap(_toggle('example.browser'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      bridge.writeGate!.complete();
      await tester.pump();
      bridge.selected = {'example.mail', 'example.hidden'};
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.browser'));
      expect(tester.widget<SwitchListTile>(_toggle('example.browser')).value, isFalse);
      await _reveal(tester, _toggle('example.hidden'));
      expect(tester.widget<SwitchListTile>(_toggle('example.hidden')).value, isTrue);
    });
  });

  testWidgets('clear requires confirmation and clears hidden selections too', (tester) async {
    bridge.selected = {'example.mail', 'example.hidden'};
    await _withRoutes(tester, () async {
      final clear = find.byKey(const Key('clear_route_selections'));
      await _reveal(tester, clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.selected, hasLength(2));
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_clear_route_selections')));
      await tester.pumpAndSettle();
      expect(bridge.named('setBypass'), hasLength(1));
      expect((bridge.named('setBypass').single.arguments as Map)['expectedPackages'],
          ['example.hidden', 'example.mail']);
      expect(bridge.selected, isEmpty);
    });
  });

  testWidgets('old clear confirmation after app switch cannot erase choices', (tester) async {
    await _withRoutes(tester, () async {
      final clear = find.byKey(const Key('clear_route_selections'));
      await _reveal(tester, clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      bridge.selected = {'example.hidden'};
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_clear_route_selections')));
      await tester.pumpAndSettle();
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.selected, {'example.hidden'});
      await _reveal(tester, _toggle('example.hidden'));
      expect(tester.widget<SwitchListTile>(_toggle('example.hidden')).value, isTrue);
    });
  });

  testWidgets('in-flight route save also blocks connect and profile creation on other tabs', (tester) async {
    await _withRoutes(tester, () async {
      bridge.writeGate = Completer<void>();
      await _reveal(tester, _toggle('example.browser'));
      await tester.tap(_toggle('example.browser'));
      await tester.pump();
      await _nav(tester, 'Главная');
      await tester.tap(find.byKey(const Key('pushok_connect_button')));
      await tester.pump();
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('loadWireGuardProfile'), isEmpty);
      await _nav(tester, 'Серверы');
      await tester.pump();
      final add = find.byKey(const Key('add_wireguard_profile'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pump();
      expect(find.byKey(const Key('wireguard_profile_name')), findsNothing);
      bridge.writeGate!.complete();
      await tester.pumpAndSettle();
    });
  });

  testWidgets('unknown tunnel state blocks mutation while search remains usable', (tester) async {
    bridge.statusState = 'unknown';
    await _withRoutes(tester, () async {
      final search = find.byKey(const Key('route_search'));
      await _reveal(tester, search);
      await tester.enterText(search, 'BROWSER');
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.browser'));
      expect(tester.widget<SwitchListTile>(_toggle('example.browser')).onChanged, isNull);
      expect(find.byKey(const Key('route_toggle_example.mail')), findsNothing);
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

  testWidgets('query and selected filter persist across tabs and refresh', (tester) async {
    await _withRoutes(tester, () async {
      final search = find.byKey(const Key('route_search'));
      await _reveal(tester, search);
      await tester.enterText(search, 'mail');
      await tester.pumpAndSettle();
      final filter = find.byKey(const Key('routes_filter_selected'));
      await _reveal(tester, filter);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await _nav(tester, 'Главная');
      await tester.pumpAndSettle();
      await _nav(tester, 'Маршруты');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'mail');
      await _reveal(tester, _toggle('example.mail'));
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).value, isTrue);
      expect(_toggle('example.browser'), findsNothing);
    });
  });
}
