import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// Navigate the real one-home application using the gear, never the removed
// five-item bottom tab bar. No native account or VPN interaction is bypassed.
Future<void> flowGoTo(WidgetTester tester, String label) async {
  const pages = {
    'Маршруты': 'settings_routes',
    'Серверы': 'settings_servers',
    'Pushok ИИ': 'settings_ai',
    'Профиль': 'settings_account',
    'Обновления': 'settings_updates',
  };
  if (label == 'Настройки') {
    if (find.byKey(const Key('flow_settings_menu')).evaluate().isNotEmpty) return;
    if (find.byKey(const Key('open_flow_settings')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('open_flow_settings')));
    } else {
      await tester.tap(find.byKey(const Key('flow_back_navigation')));
    }
    await tester.pump();
    return;
  }
  if (label == 'Главная') {
    if (find.byKey(const Key('open_flow_settings')).evaluate().isNotEmpty) return;
    if (find.byKey(const Key('flow_settings_menu')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('flow_back_navigation')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('flow_back_navigation')));
    await tester.pump();
    return;
  }
  final target = pages[label];
  if (target == null) throw ArgumentError.value(label,'label');
  if (find.byKey(const Key('flow_settings_menu')).evaluate().isEmpty) {
    if (find.byKey(const Key('open_flow_settings')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('open_flow_settings')));
    } else {
      await tester.tap(find.byKey(const Key('flow_back_navigation')));
    }
    await tester.pump();
  }
  final item = find.byKey(Key(target));
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pump();
}
