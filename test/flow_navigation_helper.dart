import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// User-level navigation: one Home; all other destinations under the gear.
/// Mirrors actual taps instead of calling private FlowHome state methods.
Future<void> flowNavigate(WidgetTester tester, String destination) async {
  const routes = <String, String>{
    'Справка': 'settings_help',
    'Маршруты': 'settings_routes',
    'Серверы': 'settings_servers',
    'Pushok ИИ': 'settings_assistant',
    'Профиль': 'settings_profile',
  };
  const titles = <String, String>{
    'Справка': 'Справка',
    'Маршруты': 'Маршруты',
    'Серверы': 'Серверы и подписки',
    'Pushok ИИ': 'Pushok ИИ',
    'Профиль': 'Аккаунт и обновления',
  };
  final back = find.byKey(const Key('flow_settings_back'));
  if (destination == 'Главная') {
    for (var i = 0; i < 3 && back.evaluate().isNotEmpty; i++) {
      await tester.tap(back);
      await tester.pump();
    }
    return;
  }

  final key = routes[destination];
  if (key == null) throw ArgumentError.value(destination, 'destination');
  // Re-selecting an already open panel should not trigger another network
  // read or a duplicate automatic refresh.
  if (find.descendant(of: find.byType(AppBar),
      matching: find.text(titles[destination]!)).evaluate().isNotEmpty &&
      find.byKey(const Key('flow_settings_menu')).evaluate().isEmpty) {
    return;
  }

  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
    } else {
      await tester.tap(find.byKey(const Key('flow_settings_button')));
    }
    await tester.pump();
  }
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 130,
      scrollable: find.descendant(
        of: find.byKey(const Key('flow_settings_menu')),
        matching: find.byType(Scrollable),
      ).first);
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pump();
}
