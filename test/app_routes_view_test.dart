import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/android_app_routes.dart';
import 'package:pushok_flow/ui/app_routes_view.dart';

const _apps = [
  InstalledApp(packageName: 'example.browser', label: 'Браузер'),
  InstalledApp(packageName: 'example.mail', label: 'Почта'),
];

Future<void> _pumpRoutes(WidgetTester tester, {
  List<InstalledApp> apps = _apps,
  Set<String> selected = const {},
  bool loaded = true,
  bool loading = false,
  bool saving = false,
  bool canEdit = true,
  bool isAndroid = true,
  String query = '',
  bool onlySelected = false,
  String? error,
  String? disabledReason,
  VoidCallback? onRefresh,
  VoidCallback? onClear,
  void Function(String, bool)? onToggle,
  double textScale = 1,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: Padding(
      padding: const EdgeInsets.all(14),
      child: StatefulBuilder(builder: (context, setState) => AppRoutesView(
        apps: apps, selectedPackages: selected, isAndroid: isAndroid,
        loading: loading, saving: saving, loaded: loaded, canEdit: canEdit,
        query: query, onlySelected: onlySelected, error: error,
        disabledReason: disabledReason, onRefresh: onRefresh, onClear: onClear,
        onQueryChanged: (value) => setState(() => query = value),
        onFilterChanged: (value) => setState(() => onlySelected = value),
        onToggle: onToggle ?? (_, _) {},
      )),
    )),
  ));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Finder _listScrollable() => find.descendant(
  of: find.byKey(const Key('routes_list')), matching: find.byType(Scrollable),
).first;

void main() {
  testWidgets('Search matches labels and packages without changing selections', (tester) async {
    final changes = <String>[];
    await _pumpRoutes(tester, selected: {'example.mail'},
      onToggle: (package, _) => changes.add(package));
    await tester.enterText(find.byKey(const Key('route_search')), 'БРАУЗЕР');
    await tester.pump();
    expect(find.text('Браузер'), findsOneWidget);
    expect(find.text('Почта'), findsNothing);
    expect(find.text('Исключений: 1'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('route_search')), '  EXAMPLE.MAIL  ');
    await tester.pump();
    expect(find.text('Браузер'), findsNothing);
    expect(find.text('Почта'), findsOneWidget);
    await _tap(tester, 'clear_route_search');
    expect(tester.widget<TextField>(find.byKey(const Key('route_search'))).controller!.text, '');
    expect(find.text('Браузер'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('Selected filter retains absent packages and allows explicit removal', (tester) async {
    final changes = <(String, bool)>[];
    await _pumpRoutes(tester, selected: {'example.mail', 'missing.saved_app'},
      onToggle: (package, value) => changes.add((package, value)));
    await _tap(tester, 'routes_filter_selected');
    expect(find.text('Браузер'), findsNothing);
    expect(find.text('Почта'), findsOneWidget);
    final missing = find.byKey(const ValueKey('route_toggle_missing.saved_app'));
    await tester.scrollUntilVisible(missing, 140,
      scrollable: _listScrollable());
    expect(find.text('Нет в списке приложений. Сохранённое исключение.'), findsOneWidget);
    await _tap(tester, 'route_toggle_missing.saved_app');
    expect(changes, [('missing.saved_app', false)]);
    // A callback alone never pretends that the native store accepted the write.
    expect(tester.widget<SwitchListTile>(missing).value, isTrue);
  });

  testWidgets('Refreshing parent data keeps query and selected filter controlled', (tester) async {
    await _pumpRoutes(tester, selected: {'example.mail'}, query: 'mail', onlySelected: true);
    expect(find.text('Почта'), findsOneWidget);
    await _pumpRoutes(tester, selected: {'example.mail'}, query: 'mail', onlySelected: true,
      apps: [..._apps, const InstalledApp(packageName: 'example.mail_work', label: 'Рабочая почта')]);
    expect(tester.widget<TextField>(find.byKey(const Key('route_search'))).controller!.text, 'mail');
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('routes_filter_selected'))).selected, isTrue);
    expect(find.text('Рабочая почта'), findsNothing);
    await _pumpRoutes(tester, query: 'browser');
    expect(tester.widget<TextField>(find.byKey(const Key('route_search'))).controller!.text, 'browser');
    expect(find.text('Браузер'), findsOneWidget);
  });

  testWidgets('Empty list, empty selected filter and no matches have distinct guidance', (tester) async {
    await _pumpRoutes(tester, apps: []);
    expect(find.textContaining('В списке пока нет приложений.'), findsOneWidget);
    await _pumpRoutes(tester, onlySelected: true);
    expect(find.textContaining('Исключений пока нет.'), findsOneWidget);
    await _pumpRoutes(tester, query: 'no-match');
    expect(find.textContaining('Ничего не найдено.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed initial load does not show a fabricated zero or empty list', (tester) async {
    var refreshes = 0;
    await _pumpRoutes(tester, apps: [], loaded: false, error: 'Не удалось прочитать список.',
      onRefresh: () => refreshes++);
    expect(find.text('Исключения ещё не загружены'), findsOneWidget);
    expect(find.text('Исключений: 0'), findsNothing);
    expect(find.byKey(const Key('routes_empty')), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    await _tap(tester, 'refresh_routes');
    expect(refreshes, 1);
  });

  testWidgets('Read errors retain confirmed list while blocking toggles and clear', (tester) async {
    await _pumpRoutes(tester, selected: {'example.mail'},
      error: 'Не удалось обновить список.', onClear: () {});
    expect(find.text('Последний список: 1 исключений'), findsOneWidget);
    expect(find.text('Почта'), findsOneWidget);
    for (final tile in tester.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
      expect(tile.onChanged, isNull);
    }
    expect(tester.widget<TextButton>(find.byKey(const Key('clear_route_selections'))).onPressed, isNull);
  });

  testWidgets('Connected, reading and saving states disable mutations but allow filters', (tester) async {
    for (final state in [
      (canEdit: false, loading: false, saving: false),
      (canEdit: true, loading: true, saving: false),
      (canEdit: true, loading: false, saving: true),
    ]) {
      await _pumpRoutes(tester, selected: {'example.mail'}, canEdit: state.canEdit,
        loading: state.loading, saving: state.saving,
        disabledReason: 'Для изменения исключений отключите туннель.', onClear: () {});
      expect(tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('route_toggle_example.mail'))).onChanged, isNull);
      expect(tester.widget<TextButton>(find.byKey(const Key('clear_route_selections'))).onPressed, isNull);
      await _tap(tester, 'routes_filter_selected');
      expect(find.text('Браузер'), findsNothing);
      expect(find.text('Почта'), findsOneWidget);
    }
  });

  testWidgets('Clear asks the parent and does not optimistically remove exclusions', (tester) async {
    var clears = 0;
    await _pumpRoutes(tester, selected: {'example.mail'}, onClear: () => clears++);
    await _tap(tester, 'clear_route_selections');
    expect(clears, 1);
    expect(find.text('Исключений: 1'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('route_toggle_example.mail'))).value, isTrue);
  });

  testWidgets('Large app lists build only the visible portion', (tester) async {
    await _pumpRoutes(tester, apps: List.generate(2000, (index) => InstalledApp(
      packageName: 'example.app${index.toString().padLeft(4, '0')}',
      label: 'Приложение ${index.toString().padLeft(4, '0')}',
    )));
    expect(find.byType(SwitchListTile).evaluate().length, lessThan(20));
    expect(find.byKey(const ValueKey('route_toggle_example.app1999')), findsNothing);
  });

  testWidgets('Long labels and controls fit a compact phone with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var toggles = 0;
    final longPackage = 'example.${'a' * 240}';
    await _pumpRoutes(tester, apps: [
      InstalledApp(packageName: longPackage, label: 'Приложение ${'я' * 100}'),
    ], selected: {longPackage}, textScale: 2.2, onClear: () {},
      onToggle: (_, _) => toggles++);
    await _tap(tester, 'routes_filter_selected');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'clear_route_selections');
    expect(tester.takeException(), isNull);
    final tile = find.byKey(ValueKey('route_toggle_$longPackage'));
    await tester.scrollUntilVisible(tile, 160,
      scrollable: _listScrollable());
    await tester.ensureVisible(tile);
    await tester.pump();
    // Bounded labels keep the switch reachable; full values remain available
    // through the tooltip and Text semantics despite the visual ellipsis.
    final title = find.descendant(of: tile, matching: find.text('Приложение ${'я' * 100}'));
    expect(tester.widget<Text>(title).maxLines, 2);
    final tooltip = find.descendant(of: tile, matching: find.byType(Tooltip));
    expect(tester.widgetList<Tooltip>(tooltip).map((item) => item.message),
      containsAll(['Приложение ${'я' * 100}', longPackage]));
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    await tester.ensureVisible(toggle);
    await tester.pump();
    expect(toggle.hitTestable(), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(toggles, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Unsupported platforms state availability without Android controls', (tester) async {
    await _pumpRoutes(tester, isAndroid: false, loaded: false);
    expect(find.text('Приложения без туннеля'), findsOneWidget);
    expect(find.text('Исключения приложений доступны в приложении для Android.'), findsOneWidget);
    expect(find.byKey(const Key('route_search')), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });
}
