import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/main.dart';

void main() {
  testWidgets('Pushok Flow shows the home screen', (tester) async {
    await tester.pumpWidget(const PushokFlowApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.textContaining('Pushok Flow'), findsWidgets);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('Умный маршрут'), findsNothing);
    expect(find.text('Профиль WireGuard'), findsNothing);
    expect(find.byKey(const Key('configure_wireguard_profile')), findsNothing);
    expect(find.byKey(const Key('tunnel_diagnostics_card')), findsNothing);
    expect(find.byKey(const Key('connection_error')), findsNothing);
    expect(find.text('Твой интернет. Твои правила.'), findsNothing);
    expect(find.text('трафик'), findsNothing);
    expect(find.byKey(const Key('open_app_information')), findsOneWidget);
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
        'Серверы': 'Профили WireGuard',
        'Pushok ИИ': 'Локальная память результатов',
        'Профиль': 'Pushok ID',
        'Главная': 'Подключить',
      };
      for (final screen in screens.entries) {
        await tester.tap(find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(screen.key),
        ));
        await tester.pumpAndSettle();
        expect(find.text(screen.value), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.byKey(const Key('open_app_information')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_information_sheet')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('app_information_version'))).data,
          contains('0.30.0'));
      final close = find.byKey(const Key('close_app_information'));
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_information_sheet')), findsNothing);
      expect(find.byKey(const Key('tunnel_diagnostics_card')), findsNothing);
      expect(find.byKey(const Key('pushok_connect_button')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
