import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/main.dart';

void main() {
  testWidgets('Pushok Flow shows the home screen', (tester) async {
    await tester.pumpWidget(const PushokFlowApp());
    await tester.pump();
    expect(find.textContaining('Pushok Flow'), findsWidgets);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('Умный маршрут'), findsNothing);
    expect(find.text('Профиль WireGuard'), findsNothing);
    expect(find.byKey(const Key('configure_wireguard_profile')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets('All navigation screens render at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const PushokFlowApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pushok_connect_button')), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);

      const screens = {
        'Маршруты': 'Приложения без туннеля',
        'Серверы': 'Профили WireGuard',
        'Pushok ИИ': 'Локальная память результатов',
        'Профиль': 'Pushok ID',
        'Главная': 'Твой интернет. Твои правила.',
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

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
