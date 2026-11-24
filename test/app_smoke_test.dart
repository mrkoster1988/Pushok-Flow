import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/main.dart';
import 'flow_test_navigation.dart';

void main() {
  testWidgets('Pushok Flow shows the home screen', (tester) async {
    await tester.pumpWidget(const PushokFlowApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.textContaining('Pushok Flow'), findsWidgets);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('Умный маршрут'), findsNothing);
    expect(find.text('Профиль подключения'), findsNothing);
    expect(find.byKey(const Key('configure_wireguard_profile')), findsNothing);
    expect(find.byKey(const Key('tunnel_diagnostics_card')), findsNothing);
    expect(find.byKey(const Key('connection_error')), findsNothing);
    expect(find.text('Твой интернет. Твои правила.'), findsNothing);
    expect(find.text('трафик'), findsNothing);
    expect(find.byKey(const Key('open_flow_settings')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('home_vital_status')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets('All navigation screens render at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const PushokFlowApp(animationsEnabled: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pushok_connect_button')), findsOneWidget);
      expect(find.byKey(const Key('pushok_mascot')), findsOneWidget);
      expect(tester.takeException(), isNull);

      const screens = {
        'Маршруты': 'Приложения без туннеля',
        'Серверы': 'Профили подключения',
        'Pushok ИИ': 'Локальная память результатов',
        'Профиль': 'Аккаунт Pushok',
        'Главная': 'Подключить',
      };
      for (final screen in screens.entries) {
        await flowGoTo(tester, screen.key);
        await tester.pumpAndSettle();
        expect(find.text(screen.value), findsWidgets);
        expect(tester.takeException(), isNull);
      }

      await flowGoTo(tester, 'Настройки');
      expect(find.byKey(const Key('settings_help')), findsOneWidget);
      expect(find.byKey(const Key('settings_updates')), findsOneWidget);
      await tester.tap(find.byKey(const Key('open_app_information')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_information_sheet')), findsOneWidget);
      final packageVersion = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$',
          multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync());
      expect(packageVersion, isNotNull, reason: 'The app version must match the package metadata.');
      expect(tester.widget<Text>(find.byKey(const Key('app_information_version'))).data,
          contains(packageVersion!.group(1)!));
      final close = find.byKey(const Key('close_app_information'));
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_information_sheet')), findsNothing);
      expect(find.byKey(const Key('tunnel_diagnostics_card')), findsNothing);
      await flowGoTo(tester, 'Главная');
      expect(find.byKey(const Key('pushok_connect_button')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Single home and gear open help before advanced settings', (tester) async {
    await tester.pumpWidget(const PushokFlowApp(
      isAndroid: false, animationsEnabled: false));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('flow_page_0')), findsOneWidget);
    expect(find.byKey(const Key('home_account_actions')), findsOneWidget);
    expect(find.byKey(const Key('home_vital_status')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('home_subscription_expiry'))).data,
      'Нет данных');
    expect(tester.widget<Text>(find.byKey(const Key('home_latency_value'))).data, '—');

    await tester.tap(find.byKey(const Key('open_flow_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('flow_settings_menu')), findsOneWidget);
    final helpTop = tester.getTopLeft(find.byKey(const Key('settings_help'))).dy;
    final accountTop = tester.getTopLeft(find.byKey(const Key('settings_account'))).dy;
    expect(helpTop, lessThan(accountTop), reason: 'Help must be first in Settings');

    await tester.tap(find.byKey(const Key('settings_help')));
    await tester.pumpAndSettle();
    expect(find.text('Как подключить Pushok Flow'), findsOneWidget);
    await tester.tap(find.byKey(const Key('close_flow_help')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings_routes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('flow_page_1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('flow_back_navigation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('flow_settings_menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('flow_back_navigation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('flow_page_0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
