import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/route_recommendations.dart';
import 'package:pushok_flow/ui/route_recommendations_card.dart';

Map<String, Object?> _status({int version = 1, List<String>? packages}) => {
  'rulesVersion': version,
  'packages': packages ?? <String>['example.mail'],
  'checkedAtMillis': 1795320000000,
  'busy': false,
  'errorCode': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/route_recommendations');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Verified catalogue is immutable and errors preserve its version and check time', () {
    final packages = <String>['example.mail'];
    final parsed = RecommendationStatus.fromPlatform(_status(packages: packages));
    packages.add('example.browser');
    expect(parsed.packages, {'example.mail'});
    expect(() => parsed.packages.add('example.other'), throwsUnsupportedError);
    final failed = parsed.withError('RECOMMENDATIONS_NETWORK_ERROR');
    expect(failed.rulesVersion, 1);
    expect(failed.packages, {'example.mail'});
    expect(failed.checkedAtMillis, 1795320000000);
    expect(failed.busy, isFalse);
    expect(failed.errorCode, 'RECOMMENDATIONS_NETWORK_ERROR');
  });

  test('Malformed native snapshots cannot introduce catalogue entries or arbitrary errors', () {
    final invalid = <Object?>[
      null,
      <Object?>[],
      {..._status(), 'extra': true},
      <String, Object?>{'rulesVersion': 1},
      {..._status(), 'rulesVersion': true},
      {..._status(), 'rulesVersion': 1.0},
      {..._status(), 'rulesVersion': -1},
      {..._status(), 'rulesVersion': 2147483648},
      {..._status(), 'rulesVersion': 0},
      {..._status(), 'packages': null},
      {..._status(), 'packages': <Object?>[123]},
      {..._status(), 'packages': <String>['example.mail', 'example.mail']},
      {..._status(), 'packages': <String>['example.mail\n']},
      {..._status(), 'packages': <String>['no_dot']},
      {..._status(), 'packages': <String>['example.${'a' * 248}']},
      {..._status(), 'packages': List.generate(257, (index) => 'example.app$index')},
      {..._status(), 'busy': 'false'},
      {..._status(), 'checkedAtMillis': 0},
      {..._status(), 'checkedAtMillis': 1.0},
      {..._status(), 'checkedAtMillis': 8640000000000001},
      {..._status(), 'errorCode': 'PRIVATE_NATIVE_DETAILS'},
    ];
    for (final raw in invalid) {
      expect(() => RecommendationStatus.fromPlatform(raw), throwsFormatException,
        reason: 'Invalid snapshot must not become an advisory catalogue.');
    }
    final empty = RecommendationStatus.fromPlatform({
      ..._status(version: 0, packages: []), 'checkedAtMillis': null,
    });
    expect(empty.rulesVersion, 0);
    expect(empty.packages, isEmpty);
    final withdrawn = RecommendationStatus.fromPlatform(_status(version: 2, packages: []));
    expect(withdrawn.rulesVersion, 2);
    expect(withdrawn.packages, isEmpty);
  });

  test('Bridge reads cache and requests network only through its distinct explicit method', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return _status();
    });
    final bridge = RouteRecommendations(isAndroid: true);
    await bridge.recommendationStatus();
    expect(calls, ['recommendationStatus']);
    await bridge.refreshRecommendations();
    expect(calls, ['recommendationStatus', 'refreshRecommendations']);
  });

  test('Unavailable platforms and native failures produce only fixed safe codes', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(code: 'PRIVATE_CODE', message: 'PRIVATE_NATIVE_DETAILS');
    });
    await expectLater(RouteRecommendations(isAndroid: false).recommendationStatus(),
      throwsA(isA<RecommendationFailure>().having((error) => error.code, 'code',
        'RECOMMENDATIONS_UNAVAILABLE')));
    expect(calls, 0);
    await expectLater(RouteRecommendations(isAndroid: true).refreshRecommendations(),
      throwsA(isA<RecommendationFailure>().having((error) => error.code, 'code',
        'RECOMMENDATIONS_INVALID')));
    expect(calls, 1);
  });

  testWidgets('Recommendation card remains usable with large text and preserves error context', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var refreshes = 0;
    final status = RecommendationStatus.fromPlatform(_status())
        .withError('RECOMMENDATIONS_NETWORK_ERROR');
    await tester.pumpWidget(MaterialApp(theme: buildPushokTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(body: ListView(padding: const EdgeInsets.all(14), children: [
        RouteRecommendationsCard(status: status, loading: false, refreshing: false,
          onRefresh: () => refreshes++),
      ])),
    ));
    final button = find.byKey(const Key('refresh_recommendations'));
    await tester.ensureVisible(button);
    await tester.pump();
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(refreshes, 1);
    expect(find.text('Версия рекомендаций: 1'), findsOneWidget);
    expect(find.byKey(const Key('recommendations_checked_at')), findsOneWidget);
    expect(find.textContaining('Проверьте интернет'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
