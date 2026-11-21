import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/tunnel_diagnostics.dart';
import 'package:pushok_flow/ui/tunnel_diagnostics_card.dart';

const _zero = TunnelDiagnostics(
  isKnown: true,
  connected: true,
  uptimeSeconds: 65,
  statistics: TunnelStatistics(
    status: TunnelStatisticsStatus.available,
    rxBytes: 0,
    txBytes: 1024,
    handshakeStatus: HandshakeStatus.never,
  ),
);

const _observed = TunnelDiagnostics(
  isKnown: true,
  connected: true,
  uptimeSeconds: 7265,
  statistics: TunnelStatistics(
    status: TunnelStatisticsStatus.available,
    rxBytes: 1048576,
    txBytes: 1073741824,
    latestHandshakeAgeSeconds: 90 * 86400,
    handshakeStatus: HandshakeStatus.observed,
  ),
);

Future<void> _showCard(WidgetTester tester, {
  required TunnelDiagnostics diagnostics,
  bool refreshing = false,
  bool stale = false,
  VoidCallback? onRefresh,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: TunnelDiagnosticsCard(
        diagnostics: diagnostics,
        refreshing: refreshing,
        stale: stale,
        onRefresh: onRefresh,
      ),
    )),
  ));
  if (refreshing) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

String _value(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('Measured zero is shown as zero; unknown statistics never become zero', (tester) async {
    await _showCard(tester, diagnostics: _zero);
    expect(_value(tester, 'tunnel_rx_value'), '0 Б');
    expect(_value(tester, 'tunnel_tx_value'), '1,0 КиБ');
    expect(_value(tester, 'tunnel_handshake_value'), 'Ещё не зафиксировано');
    expect(_value(tester, 'tunnel_uptime_value'), '1 мин 5 сек');

    await _showCard(tester, diagnostics: const TunnelDiagnostics(
      isKnown: true, connected: true,
    ));
    expect(_value(tester, 'tunnel_rx_value'), '—');
    expect(_value(tester, 'tunnel_tx_value'), '—');
    expect(_value(tester, 'tunnel_handshake_value'), 'Данные недоступны');
    expect(find.text('0 Б'), findsNothing);
    expect(find.text('Туннель включён. Статистика пока недоступна.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Old handshake remains a neutral observation, not a claim of internet failure', (tester) async {
    await _showCard(tester, diagnostics: _observed);
    expect(_value(tester, 'tunnel_handshake_value'), '90 дн 0 ч назад');
    expect(_value(tester, 'tunnel_rx_value'), '1,0 МиБ');
    expect(_value(tester, 'tunnel_tx_value'), '1,0 ГиБ');
    expect(find.text('Туннель включён.'), findsOneWidget);
    expect(find.textContaining('Интернет работает'), findsNothing);
    expect(find.textContaining('сбой'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('tunnel_handshake_value')))
        .style!.color, PushokPalette.text);
  });

  testWidgets('Stale and unknown snapshots hide every previous measurement', (tester) async {
    await _showCard(tester, diagnostics: _observed, stale: true);
    for (final key in ['tunnel_rx_value', 'tunnel_tx_value', 'tunnel_uptime_value']) {
      expect(_value(tester, key), '—');
    }
    expect(_value(tester, 'tunnel_handshake_value'), 'Данные недоступны');
    expect(find.text('90 дн 0 ч назад'), findsNothing);
    expect(find.text('Туннель включён.'), findsNothing);
    expect(find.text('Нет свежих данных. Обновите диагностику.'), findsOneWidget);

    await _showCard(tester, diagnostics: const TunnelDiagnostics(
      isKnown: false, connected: true, uptimeSeconds: 9000,
      statistics: TunnelStatistics(
        status: TunnelStatisticsStatus.available,
        rxBytes: 500, txBytes: 600,
        latestHandshakeAgeSeconds: 0,
        handshakeStatus: HandshakeStatus.observed,
      ),
    ));
    expect(find.text('500 Б'), findsNothing);
    expect(find.text('600 Б'), findsNothing);
    expect(find.text('Только что'), findsNothing);
    expect(_value(tester, 'tunnel_uptime_value'), '—');
    expect(tester.takeException(), isNull);
  });

  testWidgets('An inactive or transitioning tunnel cannot show old connection counters', (tester) async {
    await _showCard(tester, diagnostics: const TunnelDiagnostics(
      isKnown: true, connected: false,
      statistics: TunnelStatistics.inactive(),
    ));
    expect(find.text('Туннель выключен.'), findsOneWidget);
    expect(_value(tester, 'tunnel_handshake_value'), 'Нет активного туннеля');
    expect(_value(tester, 'tunnel_rx_value'), '—');

    await _showCard(tester, diagnostics: const TunnelDiagnostics(
      isKnown: true, connected: true, transitioning: true,
      statistics: TunnelStatistics(
        status: TunnelStatisticsStatus.available, rxBytes: 500, txBytes: 600,
        latestHandshakeAgeSeconds: 2, handshakeStatus: HandshakeStatus.observed,
      ),
    ));
    expect(find.text('Состояние туннеля изменяется…'), findsOneWidget);
    expect(find.text('500 Б'), findsNothing);
    expect(_value(tester, 'tunnel_handshake_value'), 'Данные недоступны');
  });

  testWidgets('Refresh requires a tap and is disabled while pending or unavailable', (tester) async {
    var refreshes = 0;
    await _showCard(tester, diagnostics: _zero, onRefresh: () => refreshes++);
    expect(refreshes, 0);
    await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
    await tester.pump();
    expect(refreshes, 1);

    await _showCard(tester, diagnostics: _zero, refreshing: true,
      onRefresh: () => refreshes++);
    expect(tester.widget<IconButton>(find.byKey(const Key('refresh_tunnel_diagnostics')))
        .onPressed, isNull);
    await tester.tap(find.byKey(const Key('refresh_tunnel_diagnostics')));
    await tester.pump();
    expect(refreshes, 1);

    await _showCard(tester, diagnostics: _zero);
    expect(tester.widget<IconButton>(find.byKey(const Key('refresh_tunnel_diagnostics')))
        .onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Help explains peer, internet and cumulative-traffic limits without running a check', (tester) async {
    var refreshes = 0;
    await _showCard(tester, diagnostics: _observed, onRefresh: () => refreshes++);
    await tester.tap(find.byKey(const Key('info_tunnel_diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Что показывает диагностика'), findsOneWidget);
    expect(find.textContaining('хотя бы с одним узлом'), findsOneWidget);
    expect(find.textContaining('не подтверждает доступность сайтов'), findsOneWidget);
    expect(find.textContaining('а не скорость соединения'), findsOneWidget);
    expect(refreshes, 0);
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    expect(find.text('Что показывает диагностика'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Compact screen, large text and largest counters remain readable', (tester) async {
    await _showCard(tester,
      size: const Size(360, 640), scale: 2.2,
      diagnostics: const TunnelDiagnostics(
        isKnown: true, connected: true, uptimeSeconds: 9223372036854775807,
        statistics: TunnelStatistics(
          status: TunnelStatisticsStatus.available,
          rxBytes: 9223372036854775807, txBytes: 9223372036854775807,
          latestHandshakeAgeSeconds: 9223372036854775807,
          handshakeStatus: HandshakeStatus.observed,
        ),
      ),
    );
    expect(find.text('8,0 ЭиБ'), findsNWidgets(2));
    expect(find.text('Более года назад'), findsOneWidget);
    expect(find.text('Более года'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('info_tunnel_diagnostics')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Понятно'));
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
