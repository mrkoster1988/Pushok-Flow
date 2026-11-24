import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';
import 'flow_test_navigation.dart';

class _RoutesBridge {
  final calls = <MethodCall>[];
  Set<String> selected = {'example.mail'};
  Set<String> unavailable = {};
  Completer<Object?>? nextRead;
  Completer<void>? writeGate;
  Object? appsError;
  Object? readError;
  Object? writeError;
  void Function()? beforeWrite;
  bool connected = false;
  String? statusState;
  Map<String, Object?> recommendations = {
    'rulesVersion': 1,
    'packages': <String>['example.browser', 'remote.not_installed'],
    'checkedAtMillis': 1795320000000,
    'busy': false,
    'errorCode': null,
    'autoUpdateEnabled': false,
  };
  Completer<Object?>? nextRecommendationRead;
  Completer<Object?>? nextRecommendationRefresh;
  Completer<Object?>? nextRecommendationAutomaticRefresh;
  Completer<void>? recommendationSettingGate;
  Object? recommendationRefreshError;
  Object? recommendationSettingError;

  List<MethodCall> named(String method) =>
      calls.where((call) => call.method == method).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'status':
        return {'subscriptions': <Object?>[], 'automaticUpdatesEnabled': true};
      case 'takePendingLink':
        return null;
      case 'recommendationStatus':
        final recommendationRead = nextRecommendationRead;
        nextRecommendationRead = null;
        return recommendationRead == null ? recommendations : recommendationRead.future;
      case 'refreshRecommendations':
        if (recommendationRefreshError != null) throw recommendationRefreshError!;
        final refresh = nextRecommendationRefresh;
        nextRecommendationRefresh = null;
        return refresh == null ? recommendations : refresh.future;
      case 'refreshRecommendationsIfDue':
        if (recommendationRefreshError != null) throw recommendationRefreshError!;
        final automaticRefresh = nextRecommendationAutomaticRefresh;
        nextRecommendationAutomaticRefresh = null;
        return automaticRefresh == null ? recommendations : automaticRefresh.future;
      case 'setAutoUpdateEnabled':
        if (recommendationSettingGate != null) await recommendationSettingGate!.future;
        if (recommendationSettingError != null) throw recommendationSettingError!;
        recommendations = {
          ...recommendations,
          'autoUpdateEnabled': (call.arguments as Map)['enabled'],
        };
        return recommendations;
      case 'installedApps':
        if (appsError != null) throw appsError!;
        return [
          {'packageName': 'example.browser', 'label': 'Браузер'},
          {'packageName': 'example.mail', 'label': 'Почта'},
        ];
      case 'getBypass':
        return selected.toList();
      case 'getBypassStatus':
        if (readError != null) throw readError!;
        final read = nextRead;
        nextRead = null;
        if (read != null) return read.future;
        return {'packages': selected.toList(),
          'unavailablePackages': unavailable.intersection(selected).toList()};
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
  await flowGoTo(tester, label);
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.descendant(of: find.byKey(const Key('routes_list')),
      matching: find.byType(Scrollable)).first;
    // A lazy header may have been disposed after inspecting a lower route.
    // Start at the top before searching down, so either direction is reachable.
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(finder, 180, scrollable: scrollable);
    }
  }
  await tester.ensureVisible(finder);
  await tester.pump();
}

Finder _toggle(String package) => find.byKey(Key('route_toggle_$package'));

Future<void> _withRoutes(WidgetTester tester, Future<void> Function() body) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(const PushokFlowApp(isAndroid: true, animationsEnabled: false));
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
  const recommendationsChannel = MethodChannel('shop.pushok.flow/route_recommendations');
  const subscriptionsChannel = MethodChannel('shop.pushok.flow/subscriptions');
  late _RoutesBridge bridge;
  setUp(() {
    bridge = _RoutesBridge();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, bridge.handle);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recommendationsChannel, bridge.handle);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(subscriptionsChannel, bridge.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recommendationsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(subscriptionsChannel, null);
  });

  testWidgets('Recommendation refresh needs a tap and preserves every selected route', (tester) async {
    bridge.selected = {'example.mail', 'missing.saved'};
    await _withRoutes(tester, () async {
      expect(bridge.named('recommendationStatus'), hasLength(1));
      expect(bridge.named('refreshRecommendations'), isEmpty);
      expect(bridge.named('refreshRecommendationsIfDue'), isEmpty);
      expect(bridge.named('setAutoUpdateEnabled'), isEmpty);
      final filter = find.byKey(const Key('routes_filter_recommended'));
      await _reveal(tester, filter);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.browser'));
      expect(tester.widget<SwitchListTile>(_toggle('example.browser')).value, isFalse);
      expect(_toggle('remote.not_installed'), findsNothing);
      expect(_toggle('missing.saved'), findsNothing);
      bridge.recommendations = {
        ...bridge.recommendations,
        'rulesVersion': 2,
        'packages': <String>['example.mail'],
      };
      final refresh = find.byKey(const Key('refresh_recommendations'));
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.mail'));
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).value, isTrue);
      expect(_toggle('example.browser'), findsNothing);
      expect(bridge.selected, {'example.mail', 'missing.saved'});
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.named('refreshRecommendations'), hasLength(1));
      expect(bridge.named('installUpdate'), isEmpty);
      final selected = find.byKey(const Key('routes_filter_selected'));
      await _reveal(tester, selected);
      await tester.tap(selected);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('missing.saved'));
      expect(tester.widget<SwitchListTile>(_toggle('missing.saved')).value, isTrue);
    });
  });

  testWidgets('Failed catalogue refresh keeps recommendations and local route editing available', (tester) async {
    await _withRoutes(tester, () async {
      bridge.recommendationRefreshError = PlatformException(
        code: 'RECOMMENDATIONS_NETWORK_ERROR', message: 'PRIVATE_NATIVE_DETAILS');
      final refresh = find.byKey(const Key('refresh_recommendations'));
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text('Версия рекомендаций: 1'), findsOneWidget);
      expect(find.textContaining('PRIVATE_NATIVE_DETAILS'), findsNothing);
      expect(find.byKey(const Key('routes_error')), findsNothing);
      expect(bridge.named('setBypass'), isEmpty);
      final filter = find.byKey(const Key('routes_filter_recommended'));
      await _reveal(tester, filter);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.browser'));
      expect(tester.widget<SwitchListTile>(_toggle('example.browser')).onChanged, isNotNull);
      await tester.tap(_toggle('example.browser'));
      await tester.pumpAndSettle();
      expect(bridge.selected, {'example.browser', 'example.mail'});
      expect(bridge.named('setBypass'), hasLength(1));
    });
  });

  testWidgets('Late recommendation refresh cannot overwrite cache read after resume', (tester) async {
    await _withRoutes(tester, () async {
      final oldRefresh = Completer<Object?>();
      bridge.nextRecommendationRefresh = oldRefresh;
      final refresh = find.byKey(const Key('refresh_recommendations'));
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      bridge.recommendations = {
        ...bridge.recommendations,
        'rulesVersion': 3,
        'packages': <String>['example.mail'],
      };
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      oldRefresh.complete({
        ...bridge.recommendations,
        'rulesVersion': 2,
        'packages': <String>['example.browser'],
      });
      await tester.pumpAndSettle();
      expect(find.text('Версия рекомендаций: 3'), findsOneWidget);
      expect(find.text('Версия рекомендаций: 2'), findsNothing);
      expect(bridge.named('refreshRecommendations'), hasLength(1));
      expect(bridge.named('recommendationStatus'), hasLength(2));
      expect(bridge.named('setBypass'), isEmpty);
      final filter = find.byKey(const Key('routes_filter_recommended'));
      await _reveal(tester, filter);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.mail'));
      expect(tester.widget<SwitchListTile>(_toggle('example.mail')).value, isTrue);
      expect(_toggle('example.browser'), findsNothing);
    });
  });

  testWidgets('Returning to Routes reads persisted recommendations without a network request', (tester) async {
    await _withRoutes(tester, () async {
      await _nav(tester, 'Главная');
      await tester.pumpAndSettle();
      bridge.recommendations = {
        ...bridge.recommendations,
        'rulesVersion': 2,
        'packages': <String>[],
      };
      await _nav(tester, 'Маршруты');
      await tester.pumpAndSettle();
      expect(find.text('Версия рекомендаций: 2'), findsOneWidget);
      expect(bridge.named('recommendationStatus'), hasLength(2));
      expect(bridge.named('refreshRecommendations'), isEmpty);
      expect(bridge.named('refreshRecommendationsIfDue'), isEmpty);
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.selected, {'example.mail'});
    });
  });

  testWidgets('Opt-in waits for durable acknowledgement then asks native once without changing routes', (tester) async {
    await _withRoutes(tester, () async {
      final automatic = find.byKey(const Key('recommendations_auto_update'));
      await _reveal(tester, automatic);
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      final saved = Completer<void>();
      bridge.recommendationSettingGate = saved;
      await tester.tap(automatic);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(tester.widget<SwitchListTile>(automatic).onChanged, isNull);
      expect(bridge.named('refreshRecommendationsIfDue'), isEmpty);
      expect(bridge.named('setAutoUpdateEnabled').single.arguments, {'enabled': true});
      saved.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(bridge.named('refreshRecommendations'), isEmpty);
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
      expect(bridge.named('installUpdate'), isEmpty);
      expect(bridge.selected, {'example.mail'});
    });
  });

  testWidgets('Persisted opt-in checks once on Routes entry and resume, never on Home', (tester) async {
    bridge.recommendations['autoUpdateEnabled'] = true;
    await _withRoutes(tester, () async {
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      await _nav(tester, 'Маршруты');
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(2));
      await _nav(tester, 'Главная');
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(2));
      await _nav(tester, 'Маршруты');
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(3));
      expect(bridge.named('refreshRecommendations'), isEmpty);
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

  testWidgets('Busy automatic result polls only local status without automatic retry', (tester) async {
    await _withRoutes(tester, () async {
      final automatic = find.byKey(const Key('recommendations_auto_update'));
      final pendingRefresh = Completer<Object?>();
      bridge.nextRecommendationAutomaticRefresh = pendingRefresh;
      await _reveal(tester, automatic);
      await tester.tap(automatic);
      await tester.pump();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      bridge.recommendations = {...bridge.recommendations,
        'autoUpdateEnabled': true, 'busy': true};
      pendingRefresh.complete(bridge.recommendations);
      await tester.pump();
      final localReads = bridge.named('recommendationStatus').length;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(bridge.named('recommendationStatus'), hasLength(localReads + 1));
      bridge.recommendations = {...bridge.recommendations, 'busy': false};
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.named('recommendationStatus'), hasLength(localReads + 2));
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(bridge.named('refreshRecommendations'), isEmpty);
    });
  });

  testWidgets('Failed opt-in preserves disabled setting and never starts a due check', (tester) async {
    await _withRoutes(tester, () async {
      bridge.recommendationSettingError = PlatformException(
        code: 'RECOMMENDATIONS_STORAGE_ERROR', message: 'PRIVATE_NATIVE_DETAILS');
      final automatic = find.byKey(const Key('recommendations_auto_update'));
      await _reveal(tester, automatic);
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(bridge.named('refreshRecommendationsIfDue'), isEmpty);
      expect(find.text('Версия рекомендаций: 1'), findsOneWidget);
      expect(find.textContaining('PRIVATE_NATIVE_DETAILS'), findsNothing);
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

  testWidgets('Opt-out invalidates an in-flight automatic result and keeps manual refresh', (tester) async {
    await _withRoutes(tester, () async {
      final automatic = find.byKey(const Key('recommendations_auto_update'));
      final pendingRefresh = Completer<Object?>();
      bridge.nextRecommendationAutomaticRefresh = pendingRefresh;
      await _reveal(tester, automatic);
      await tester.tap(automatic);
      await tester.pump();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(tester.widget<SwitchListTile>(automatic).onChanged, isNotNull);
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      pendingRefresh.complete({...bridge.recommendations,
        'autoUpdateEnabled': true, 'rulesVersion': 9});
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(find.text('Версия рекомендаций: 9'), findsNothing);
      final manual = find.byKey(const Key('refresh_recommendations'));
      await _reveal(tester, manual);
      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendations'), hasLength(1));
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      await _nav(tester, 'Главная');
      await tester.pumpAndSettle();
      await _nav(tester, 'Маршруты');
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

  testWidgets('Late automatic response after navigation cannot replace a newer catalogue or preference', (tester) async {
    await _withRoutes(tester, () async {
      final pendingRefresh = Completer<Object?>();
      bridge.nextRecommendationAutomaticRefresh = pendingRefresh;
      final automatic = find.byKey(const Key('recommendations_auto_update'));
      await _reveal(tester, automatic);
      await tester.tap(automatic);
      await tester.pump();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      await _nav(tester, 'Главная');
      await tester.pumpAndSettle();
      bridge.recommendations = {...bridge.recommendations,
        'autoUpdateEnabled': false, 'rulesVersion': 3};
      await _nav(tester, 'Маршруты');
      await tester.pumpAndSettle();
      pendingRefresh.complete({...bridge.recommendations,
        'autoUpdateEnabled': true, 'rulesVersion': 2});
      await tester.pumpAndSettle();
      expect(find.text('Версия рекомендаций: 3'), findsOneWidget);
      expect(find.text('Версия рекомендаций: 2'), findsNothing);
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

  testWidgets('Automatic network error keeps opt-in and selected routes without retry polling', (tester) async {
    bridge.recommendations['autoUpdateEnabled'] = true;
    bridge.recommendationRefreshError = PlatformException(
      code: 'RECOMMENDATIONS_NETWORK_ERROR', message: 'PRIVATE_NATIVE_DETAILS');
    await _withRoutes(tester, () async {
      expect(find.text('Версия рекомендаций: 1'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(
        find.byKey(const Key('recommendations_auto_update'))).value, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(bridge.named('recommendationStatus'), hasLength(1));
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.selected, {'example.mail'});
      expect(find.byKey(const Key('routes_error')), findsNothing);
      expect(find.textContaining('PRIVATE_NATIVE_DETAILS'), findsNothing);
    });
  });

  testWidgets('Late opt-in acknowledgement in background cannot start network until Routes resumes', (tester) async {
    await _withRoutes(tester, () async {
      final saved = Completer<void>();
      bridge.recommendationSettingGate = saved;
      final automatic = find.byKey(const Key('recommendations_auto_update'));
      await _reveal(tester, automatic);
      await tester.tap(automatic);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      saved.complete();
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.named('refreshRecommendationsIfDue'), hasLength(1));
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(bridge.named('setBypass'), isEmpty);
    });
  });

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

  testWidgets('unavailable exclusion is removed only explicitly and preserves other saved apps', (tester) async {
    bridge.selected = {'example.mail', 'example.hidden', 'example.deleted'};
    bridge.unavailable = {'example.deleted'};
    await _withRoutes(tester, () async {
      expect(bridge.named('setBypass'), isEmpty);
      final filter = find.byKey(const Key('routes_filter_unavailable'));
      await _reveal(tester, filter);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(_toggle('example.hidden'), findsNothing);
      await _reveal(tester, _toggle('example.deleted'));
      await tester.tap(_toggle('example.deleted'));
      await tester.pumpAndSettle();
      expect(bridge.selected, {'example.mail', 'example.hidden'});
      expect(bridge.named('setBypass'), hasLength(1));
      expect(bridge.named('setBypass').single.arguments, {
        'packages': ['example.hidden', 'example.mail'],
        'expectedPackages': ['example.deleted', 'example.hidden', 'example.mail'],
      });
      expect(find.text('Недоступных исключений больше нет. Можно повторить подключение.'),
        findsOneWidget);
      expect(bridge.named('connectWireGuard'), isEmpty);
    });
  });

  testWidgets('availability check failure preserves old diagnosis and recovery never changes choices', (tester) async {
    bridge.selected = {'example.mail', 'example.deleted'};
    bridge.unavailable = {'example.deleted'};
    await _withRoutes(tester, () async {
      bridge.readError = PlatformException(code: 'ROUTES_APPS_CHECK_FAILED',
        message: 'PRIVATE_PLATFORM_DETAILS');
      final refresh = find.byKey(const Key('refresh_routes'));
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.textContaining('Последняя проверка: недоступно 1.'), findsOneWidget);
      expect(find.textContaining('Не удалось проверить доступность приложений.'), findsOneWidget);
      expect(find.textContaining('PRIVATE_PLATFORM_DETAILS'), findsNothing);
      await _reveal(tester, _toggle('example.deleted'));
      expect(tester.widget<SwitchListTile>(_toggle('example.deleted')).value, isTrue);
      expect(tester.widget<SwitchListTile>(_toggle('example.deleted')).onChanged, isNull);
      bridge.readError = null;
      bridge.unavailable.clear();
      await _reveal(tester, refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.deleted'));
      expect(tester.widget<SwitchListTile>(_toggle('example.deleted')).value, isTrue);
      expect(tester.widget<SwitchListTile>(_toggle('example.deleted')).onChanged, isNotNull);
      expect(find.byKey(const Key('routes_unavailable_summary')), findsNothing);
      expect(bridge.selected, {'example.mail', 'example.deleted'});
      expect(bridge.named('setBypass'), isEmpty);
      expect(bridge.named('connectWireGuard'), isEmpty);
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
      bridge.unavailable = {'example.browser'};
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      oldRead.complete({'packages': ['example.mail'], 'unavailablePackages': ['example.mail']});
      await tester.pumpAndSettle();
      await _reveal(tester, _toggle('example.browser'));
      expect(tester.widget<SwitchListTile>(_toggle('example.browser')).value, isTrue);
      expect(find.descendant(of: _toggle('example.browser'),
        matching: find.text('Недоступно для Pushok Flow. Проверьте исключение.')), findsOneWidget);
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
