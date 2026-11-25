import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/main.dart';
import 'package:pushok_flow/ui/device_traffic_page.dart';

void main() {
  testWidgets('System back closes the modal, then the section, then settings', (tester) async {
    await tester.pumpWidget(const PushokFlowApp(animationsEnabled: false));
    await tester.pumpAndSettle();
    for (final key in ['flow_settings_button', 'settings_help', 'open_app_information']) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }
    for (final key in ['flow_help_screen', 'flow_settings_menu', 'flow_home_screen']) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    expect(find.byKey(const Key('app_information_sheet')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Addresses available before permission and totals after returning', (tester) async {
    const channel = MethodChannel('shop.pushok.flow/device_traffic');
    final messenger = tester.binding.defaultBinaryMessenger;
    var granted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'settings') { granted = true; return true; }
      return {
        'addresses': [{'network':'VPN','ip':'2001:db8::2'}],
        'status': granted ? 'ready' : 'permission',
        if (granted) 'sources': ['Wi-Fi'],
        if (granted) 'apps': [{'label':'Браузер','received':2048,'sent':512}],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DeviceTrafficPage())));
    await tester.pumpAndSettle();
    expect(find.text('VPN · 2001:db8::2'), findsOneWidget);
    await tester.tap(find.text('Открыть доступ'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Браузер'), findsOneWidget);
    expect(find.textContaining('2.0 КБ'), findsOneWidget);
    expect(find.textContaining('512 Б'), findsOneWidget);
  });
}
