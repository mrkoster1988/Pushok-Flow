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

Widget _screen(SubscriptionStatus lease) => MaterialApp(
      home: Scaffold(
        body: FlowConnectionVitals(
          selected: const WireGuardProfileSummary(
              id: '10000000-0000-4000-8000-000000000003',
              name: 'Pushok WireGuard',
              subscriptionId: subscriptionId,
              subscriptionName: 'Моё подключение'),
          selectionCurrent: true,
          subscriptions: lease,
          diagnostics: const TunnelDiagnostics.unavailable(),
          diagnosticsCurrent: false,
          confirmedConnected: false,
          connecting: false,
          nativeBusy: false,
          ownsTunnel: false,
          recovery: TunnelRecovery.none,
          isAndroid: true,
        ),
      ),
    );

void main() {
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
}
