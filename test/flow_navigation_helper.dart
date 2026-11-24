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

  if (destination == 'Главная') {
    for (var i = 0; i < 3; i++) {
      final back = find.byKey(const Key('flow_settings_back'));
      if (back.evaluate().isEmpty) break;
      await tester.tap(back);
      await tester.pump();
    }
    return;
  }

  final keyName = routes[destination];
  if (keyName == null) throw ArgumentError.value(destination, 'destination');
  final target = find.byKey(ValueKey(keyName));

  if (target.evaluate().isEmpty) {
    final back = find.byKey(const Key('flow_settings_back'));
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
    } else {
      await tester.tap(find.byKey(const Key('flow_settings_button')));
    }
    await tester.pump();
  }
  // A repeated tap on the already selected settings section is a no-op.
  if (target.evaluate().isEmpty) return;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}
