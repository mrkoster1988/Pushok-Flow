import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/subscriptions.dart';
import '../platform/tunnel_diagnostics.dart';
import '../platform/wireguard_profiles.dart';

/// Truthful home-only summary. No invented ping, expiry or tunnel health.
class FlowConnectionVitals extends StatelessWidget {
  const FlowConnectionVitals({
    super.key,
    required this.diagnostics,
    required this.diagnosticsCurrent,
    required this.confirmedConnected,
    required this.connecting,
    required this.nativeBusy,
    required this.ownsTunnel,
    required this.recovery,
    required this.isAndroid,
    this.selected,
    this.subscriptions,
    this.connectionError,
    this.selectionCurrent = false,
  });

  final TunnelDiagnostics diagnostics;
  final bool diagnosticsCurrent;
  final bool confirmedConnected;
  final bool connecting;
  final bool nativeBusy;
  final bool ownsTunnel;
  final TunnelRecovery recovery;
  bool get recovering => recovery != TunnelRecovery.none;
  final bool isAndroid;
  final bool selectionCurrent;
  final WireGuardProfileSummary? selected;
  final SubscriptionStatus? subscriptions;
  final String? connectionError;

  static String formatBytes(int? value) {
    if (value == null || value < 0) return '—';
    if (value < 1024) return value.toString() + ' Б';
    if (value < 1024 * 1024) return (value / 1024).toStringAsFixed(1) + ' КБ';
    if (value < 1024 * 1024 * 1024) {
      return (value / (1024 * 1024)).toStringAsFixed(1) + ' МБ';
    }
    return (value / (1024 * 1024 * 1024)).toStringAsFixed(1) + ' ГБ';
  }

  FlowSubscription? get _selectedSubscription {
    final id = selectionCurrent ? selected?.subscriptionId : null;
    if (id == null) return null;
    for (final sub in subscriptions?.subscriptions ?? const <FlowSubscription>[]) {
      if (sub.id == id) return sub;
    }
    return null;
  }

  String get _expires {
    final sub = _selectedSubscription;
    if (sub == null || sub.expiresAt == null) return 'Не указан';
    final expiry = sub.expiresAt!;
    final formatted = expiry.day.toString().padLeft(2, '0') + '.' +
        expiry.month.toString().padLeft(2, '0') + '.' + expiry.year.toString();
    final now = DateTime.now();
    final remaining = expiry.difference(now).inSeconds;
    final access = sub.effectiveState(now);
    // Revocation is different from expiry: do not report a revoked lease
    // as though its purchased term merely elapsed.
    if (access == SubscriptionAccessState.revoked) return 'Отозвана';
    if (remaining <= 0 || access == SubscriptionAccessState.expired) {
      return 'Истёк ' + formatted;
    }
    if (remaining < 86400) return 'До ' + formatted + ' · <1 дня';
    return 'До ' + formatted + ' · ' + ((remaining + 86399) ~/ 86400).toString() + ' дн.';
  }

  String get _state => connecting
      ? (ownsTunnel ? 'Отключение туннеля' : 'Соединение устанавливается')
      : nativeBusy ? 'Состояние изменяется'
      : recovery == TunnelRecovery.waitingNetwork ? 'Ожидание сети'
      : recovery == TunnelRecovery.reconnecting ? 'Восстанавливается'
      : isAndroid && !diagnosticsCurrent ? 'Статус уточняется'
      : confirmedConnected ? 'Туннель включён' : 'Статус: отключено';

  Widget _metric(String title, String value, IconData icon) => Expanded(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: PushokPalette.glowCyan, size: 15),
        const SizedBox(width: 5),
        Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: PushokPalette.muted, fontSize: 11))),
      ]),
      const SizedBox(height: 4),
      Text(value, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final sample = diagnostics.statistics;
    final fresh = confirmedConnected && diagnosticsCurrent &&
        sample.status == TunnelStatisticsStatus.available;
    final handshake = fresh && diagnostics.protocol == TunnelProtocol.wireguard &&
        sample.handshakeStatus == HandshakeStatus.observed &&
        sample.latestHandshakeAgeSeconds != null
        ? sample.latestHandshakeAgeSeconds.toString() + ' с назад'
        : '—';
    final traffic = fresh ? '↓ ' + formatBytes(sample.rxBytes) + ' ↑ ' +
        formatBytes(sample.txBytes) : '—';
    return PushokPanel(child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(alignment: Alignment.centerLeft, child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: PushokStatusChip(
          key: const Key('home_connection_state'),
          label: _state,
          icon: connecting || nativeBusy || recovering ? Icons.sync :
              !diagnosticsCurrent ? Icons.info_outline :
              ownsTunnel ? Icons.shield_outlined : Icons.circle,
          color: connecting || nativeBusy || recovering ? PushokPalette.glowCyan :
              !diagnosticsCurrent ? PushokPalette.muted :
              ownsTunnel ? PushokPalette.mint : PushokPalette.orange,
        ))),
        const SizedBox(height: 11),
        Row(children: [
          _metric('Срок подписки', _expires, Icons.event_available_outlined),
          const SizedBox(width: 10),
          _metric('Пинг', 'Нет замера', Icons.speed_outlined),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _metric('WireGuard handshake', handshake, Icons.sync_alt_outlined),
          const SizedBox(width: 10),
          _metric('Трафик', traffic, Icons.swap_vert_outlined),
        ]),
        if (connectionError != null) ...[
          const SizedBox(height: 9),
          Text(connectionError!, key: const Key('connection_error'),
            style: const TextStyle(color: PushokPalette.orange, fontSize: 12)),
        ],
      ],
    ));
  }
}
