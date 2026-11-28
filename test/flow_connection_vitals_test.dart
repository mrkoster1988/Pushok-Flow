import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/platform/subscriptions.dart';
import 'package:pushok_flow/platform/tunnel_diagnostics.dart';
import 'package:pushok_flow/platform/wireguard_profiles.dart';
import 'package:pushok_flow/ui/flow_connection_vitals.dart';

const subscriptionId = '10000000-0000-4000-8000-000000000002';

SubscriptionStatus _lease(String state, int expiresAt) =>
    SubscriptionStatus.fromPlatform({
      'subscriptions': [
        {
          'id': subscriptionId,
          'name': 'Моё подключение',
          'host': 'pushok.shop',
          'profileCount': state == 'active' ? 1 : 0,
          'updatedAt': expiresAt - 3600000,
          'expiresAt': expiresAt,
          'format': 'wireguard-v1',
          'state': state,
        }
      ],
      'automaticUpdatesEnabled': true,
      'shopAutoSyncEnabled': false,
      'shopSyncState': state,
      'busy': false,
      'errorCode': null,
      'refreshErrors': <String, String>{},
    });

Widget _screen(SubscriptionStatus lease, {
  TunnelDiagnostics diagnostics = const TunnelDiagnostics.unavailable(),
  bool diagnosticsCurrent = false,
  bool confirmedConnected = false,
}) => MaterialApp(
      home: Scaffold(
        body: FlowConnectionVitals(
          selected: const WireGuardProfileSummary(
              id: '10000000-0000-4000-8000-000000000003',
              name: 'Pushok WireGuard',
              subscriptionId: subscriptionId,
              subscriptionName: 'Моё подключение'),
          selectionCurrent: true,
          subscriptions: lease,
          diagnostics: diagnostics,
          diagnosticsCurrent: diagnosticsCurrent,
          confirmedConnected: confirmedConnected,
          connecting: false,
          nativeBusy: false,
          ownsTunnel: diagnostics.ownsTunnel,
          recovery: TunnelRecovery.none,
          isAndroid: true,
        ),
      ),
    );

void main() {
  testWidgets('An unguarded failed tunnel is retained and automatic handover is explained', (tester) async {
    await tester.pumpWidget(_screen(_lease('active', 4102444800000),
      diagnostics: const TunnelDiagnostics(isKnown: true, connected: true,
        managedRecovery: 'guard_required'), diagnosticsCurrent: true, confirmedConnected: true));
    expect(find.text('Связь не подтверждена'), findsOneWidget);
    expect(find.byKey(const Key('managed_recovery_notice')), findsOneWidget);
    expect(find.textContaining('Системная защита'), findsOneWidget);
    expect(find.text('Статус: отключено'), findsNothing);
    expect(find.text('Подключено'), findsNothing);
  });
  testWidgets('Revoked WireGuard access is not mislabelled expired', (tester) async {
    final expiry = (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400) * 1000;
    await tester.pumpWidget(_screen(_lease('revoked', expiry)));
    await tester.pump();
    expect(find.text('Отозвана'), findsOneWidget);
    expect(find.textContaining('Истёк'), findsNothing);
  });

  testWidgets('Actual WireGuard expiry is shown as expiry', (tester) async {
    final expiry = (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400) * 1000;
    await tester.pumpWidget(_screen(_lease('expired', expiry)));
    await tester.pump();
    expect(find.textContaining('Истёк'), findsOneWidget);
    expect(find.text('Отозвана'), findsNothing);
  });

  testWidgets('A fresh zero handshake reports waiting without inventing server failure', (tester) async {
    await tester.pumpWidget(_screen(_lease('active', 4102444800000),
      diagnostics: const TunnelDiagnostics(
        isKnown: true, connected: true,
        statistics: TunnelStatistics(status: TunnelStatisticsStatus.available,
          rxBytes: 0, txBytes: 1024, handshakeStatus: HandshakeStatus.never),
      ),
      diagnosticsCurrent: true,
      confirmedConnected: true,
    ));
    expect(find.text('Ожидание отклика'), findsOneWidget);
    expect(find.textContaining('успешный обмен с сервером ещё не зафиксирован'), findsOneWidget);
    expect(find.text('Нет отклика сервера'), findsNothing);
    expect(find.text('↓ 0 Б ↑ 1.0 КБ'), findsOneWidget);
  });

  for (final status in [HandshakeStatus.unknown, HandshakeStatus.observed]) {
    testWidgets('A $status handshake does not report that the server has not answered', (tester) async {
      await tester.pumpWidget(_screen(_lease('active', 4102444800000),
        diagnostics: TunnelDiagnostics(
          isKnown: true, connected: true,
          statistics: TunnelStatistics(status: TunnelStatisticsStatus.available,
            rxBytes: 1024, txBytes: 2048, handshakeStatus: status,
            latestHandshakeAgeSeconds: status == HandshakeStatus.observed ? 86400 : null),
        ),
        diagnosticsCurrent: true,
        confirmedConnected: true,
      ));
      expect(find.text('Туннель включён'), findsOneWidget);
      expect(find.text('Ожидание отклика'), findsNothing);
      expect(find.textContaining('успешный обмен с сервером ещё не зафиксирован'), findsNothing);
    });
  }

  testWidgets('A stale zero handshake cannot describe the current connection', (tester) async {
    await tester.pumpWidget(_screen(_lease('active', 4102444800000),
      diagnostics: const TunnelDiagnostics(
        isKnown: true, connected: true,
        statistics: TunnelStatistics(status: TunnelStatisticsStatus.available,
          rxBytes: 0, txBytes: 1024, handshakeStatus: HandshakeStatus.never),
      ),
      confirmedConnected: true,
    ));
    expect(find.text('Статус уточняется'), findsOneWidget);
    expect(find.text('Ожидание отклика'), findsNothing);
    expect(find.textContaining('успешный обмен с сервером ещё не зафиксирован'), findsNothing);
    expect(find.text('↓ 0 Б ↑ 1.0 КБ'), findsNothing);
  });
}
