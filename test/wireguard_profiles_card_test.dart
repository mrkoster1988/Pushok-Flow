import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/wireguard_profiles.dart';
import 'package:pushok_flow/ui/wireguard_profiles_card.dart';

const _firstId = '10000000-0000-4000-8000-000000000001';
const _secondId = '10000000-0000-4000-8000-000000000002';

WireGuardProfiles _catalog({String firstName = 'Дом', int count = 2}) =>
    WireGuardProfiles.fromPlatform({
      'profiles': List.generate(count, (index) => {
        'id': '10000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
        'name': index == 0 ? firstName : 'Работа $index',
      }),
      'activeProfileId': count == 0 ? null : _firstId,
    });

Future<void> _pumpCard(WidgetTester tester, WireGuardProfilesCard card, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(16), child: card,
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

void main() {
  testWidgets('An empty catalog offers explicit creation without any automatic action',
      (tester) async {
    var adds = 0;
    await _pumpCard(tester, WireGuardProfilesCard(
      catalog: const WireGuardProfiles.empty(),
      mutationsEnabled: true,
      onAdd: () => adds++,
    ));
    expect(find.text('Профили подключения'), findsOneWidget);
    expect(find.textContaining('Профилей пока нет.'), findsOneWidget);
    expect(adds, 0);
    await _tap(tester, 'add_wireguard_profile');
    expect(adds, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Names and active marker stay distinct from explicit edit, select and delete',
      (tester) async {
    final edited = <String>[];
    final selected = <String>[];
    final deleted = <String>[];
    await _pumpCard(tester, WireGuardProfilesCard(
      catalog: _catalog(), mutationsEnabled: true,
      onEdit: (profile) => edited.add(profile.id),
      onSelect: (profile) => selected.add(profile.id),
      onDelete: (profile) => deleted.add(profile.id),
    ));
    expect(find.text('Дом'), findsOneWidget);
    expect(find.text('Работа 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('active_wireguard_profile_$_firstId')), findsOneWidget);
    expect(find.byKey(const ValueKey('active_wireguard_profile_$_secondId')), findsNothing);
    expect(find.byKey(const ValueKey('select_wireguard_profile_$_firstId')), findsNothing);
    expect(find.textContaining(_firstId), findsNothing);
    expect(edited, isEmpty);
    expect(selected, isEmpty);
    expect(deleted, isEmpty);
    await _tap(tester, 'select_wireguard_profile_$_secondId');
    expect(selected, [_secondId]);
    expect(edited, isEmpty);
    expect(deleted, isEmpty);
    // The caller must confirm a native success before a new active marker appears.
    expect(find.byKey(const ValueKey('active_wireguard_profile_$_firstId')), findsOneWidget);
    await _tap(tester, 'edit_wireguard_profile_$_firstId');
    await _tap(tester, 'delete_wireguard_profile_$_secondId');
    expect(edited, [_firstId]);
    expect(deleted, [_secondId]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Connected, refreshing and failed states disable every mutation',
      (tester) async {
    var mutations = 0;
    for (final state in [
      (enabled: false, loading: false, error: null),
      (enabled: true, loading: true, error: null),
      (enabled: true, loading: false, error: 'Не удалось прочитать список.'),
    ]) {
      await _pumpCard(tester, WireGuardProfilesCard(
        catalog: _catalog(), mutationsEnabled: state.enabled,
        loading: state.loading, error: state.error,
        onAdd: () => mutations++,
        onEdit: (_) => mutations++,
        onSelect: (_) => mutations++,
        onDelete: (_) => mutations++,
      ));
      for (final key in ['add_wireguard_profile',
          'select_wireguard_profile_$_secondId',
          'edit_wireguard_profile_$_firstId',
          'delete_wireguard_profile_$_firstId']) {
        expect(tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed, isNull);
      }
      expect(mutations, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('The twenty-profile limit blocks creation while existing profiles remain editable',
      (tester) async {
    await _pumpCard(tester, WireGuardProfilesCard(
      catalog: _catalog(count: 20), mutationsEnabled: true,
      onAdd: () {}, onEdit: (_) {}, onSelect: (_) {}, onDelete: (_) {},
    ));
    expect(find.text('Сохранено 20 из 20'), findsOneWidget);
    expect(find.textContaining('Достигнут лимит 20 профилей.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(
      find.byKey(const Key('add_wireguard_profile'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('edit_wireguard_profile_$_firstId'))).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Unavailable catalog offers a retry and does not imply there are no saved profiles',
      (tester) async {
    var refreshes = 0;
    await _pumpCard(tester, WireGuardProfilesCard(
      mutationsEnabled: true,
      error: 'Не удалось открыть список профилей. Попробуйте снова.',
      onRefresh: () => refreshes++, onAdd: () {},
    ));
    expect(find.textContaining('Профилей пока нет.'), findsNothing);
    expect(find.byKey(const Key('wireguard_profiles_error')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(
      find.byKey(const Key('add_wireguard_profile'))).onPressed, isNull);
    await _tap(tester, 'refresh_wireguard_profiles');
    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Long names and action buttons remain usable on a compact phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var changes = 0;
    await _pumpCard(tester, WireGuardProfilesCard(
      catalog: _catalog(firstName: 'С' * 64), mutationsEnabled: true,
      onAdd: () => changes++,
      onEdit: (_) => changes++,
      onSelect: (_) => changes++,
      onDelete: (_) => changes++,
    ), textScale: 2.2);
    for (final key in ['add_wireguard_profile',
        'edit_wireguard_profile_$_firstId',
        'select_wireguard_profile_$_secondId',
        'delete_wireguard_profile_$_secondId']) {
      await _tap(tester, key);
      expect(tester.takeException(), isNull);
    }
    expect(changes, 4);
  });
}
