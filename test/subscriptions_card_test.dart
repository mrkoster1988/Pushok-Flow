import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/subscriptions.dart';
import 'package:pushok_flow/ui/subscription_editor.dart';
import 'package:pushok_flow/ui/subscriptions_card.dart';

const _id = '10000000-0000-4000-8000-000000000001';
const _url = 'https://example.invalid/sub/PRIVATE_TOKEN';
SubscriptionStatus _status({int? expiresAt, bool busy = false}) =>
    SubscriptionStatus.fromPlatform({
      'automaticUpdatesEnabled': true, 'busy': busy,
      'subscriptions': [{
        'id': _id, 'name': 'Магазин', 'host': 'example.invalid',
        'profileCount': 2, 'updatedAt': 1795377600000,
        'expiresAt': expiresAt, 'usedBytes': null, 'totalBytes': null,
      }],
    });

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(theme: buildPushokTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Unknown expiry does not claim paid active access', (tester) async {
    await _pump(tester, SubscriptionsCard(status: _status(), mutationsEnabled: true,
      onAdd: () {}, onOpenAccount: () {}));
    expect(find.text('Сервис не передал срок подписки.'), findsOneWidget);
    expect(find.textContaining('Активна'), findsNothing);
    expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
    expect(find.text('Кабинет MTProxy'), findsOneWidget);
    expect(find.text('Управлять подпиской'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Expired metadata is attributed to provider and refresh stays possible', (tester) async {
    var refreshes = 0;
    await _pump(tester, SubscriptionsCard(status: _status(expiresAt: 1795291200000),
      now: DateTime.fromMillisecondsSinceEpoch(1795377600000), mutationsEnabled: true,
      onRefresh: (_) => refreshes++));
    expect(find.textContaining('По данным сервиса срок истёк'), findsOneWidget);
    await _tap(tester, 'refresh_subscription_$_id');
    expect(refreshes, 1);
  });

  testWidgets('Native busy and connected states block changes but keep account access', (tester) async {
    for (final state in [(busy: true, enabled: true), (busy: false, enabled: false)]) {
      await _pump(tester, SubscriptionsCard(status: _status(busy: state.busy),
        mutationsEnabled: state.enabled, onRefresh: (_) {}, onDelete: (_) {},
        onOpenAccount: () {}));
      for (final key in ['refresh_subscription_$_id', 'delete_subscription_$_id']) {
        expect(tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed, isNull);
      }
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('manage_pushok_subscription'))).onPressed,
        isNotNull);
    }
  });

  testWidgets('A received URL stays masked and only explicit save imports', (tester) async {
    var saves = 0;
    await _pump(tester, SubscriptionEditor(draft: const SubscriptionDraft(url: _url),
      onSave: (url, name) async {
        expect(url, _url);
        saves++;
        throw PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR', message: 'PRIVATE_FAILURE');
      }));
    expect(saves, 0);
    final field = find.byKey(const Key('subscription_url'));
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(find.text('Источник серверов: example.invalid'), findsOneWidget);
    await _tap(tester, 'save_subscription');
    expect(saves, 1);
    expect(tester.widget<TextField>(field).controller!.text, _url);
    expect(find.textContaining('Сохранённые серверы'), findsOneWidget);
    expect(find.textContaining('PRIVATE_FAILURE'), findsNothing);
  });

  testWidgets('Revealed link hides again when app loses focus', (tester) async {
    await _pump(tester, SubscriptionEditor(draft: const SubscriptionDraft(url: _url),
      onSave: (_, _) async {}));
    await _tap(tester, 'toggle_subscription_url_visibility');
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('subscription_url'))).obscureText, isTrue);
  });
}
