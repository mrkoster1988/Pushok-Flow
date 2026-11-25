import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/tunnel_diagnostics.dart';

/// Displays a passive tunnel snapshot; it does not probe remote services.
class TunnelDiagnosticsCard extends StatelessWidget {
  const TunnelDiagnosticsCard({
    super.key,
    required this.diagnostics,
    required this.refreshing,
    required this.stale,
    this.disconnecting = false,
    this.onRefresh,
    this.onDisconnect,
  });

  final TunnelDiagnostics diagnostics;
  final bool refreshing;
  final bool stale;
  final bool disconnecting;
  final VoidCallback? onRefresh;
  final VoidCallback? onDisconnect;

  bool get _current => !stale && diagnostics.isKnown;
  bool get _active =>
      _current && diagnostics.connected && !diagnostics.transitioning && !diagnostics.recovering;
  bool get _statisticsAvailable => _active &&
      diagnostics.statistics.status == TunnelStatisticsStatus.available;
  bool get _wireGuard => diagnostics.protocol == TunnelProtocol.wireguard;

  String get _summary {
    if (!_current) {
      return refreshing
          ? 'Обновляем диагностику…'
          : 'Нет свежих данных. Обновите диагностику.';
    }
    if (diagnostics.transitioning) return 'Состояние туннеля изменяется…';
    if (diagnostics.recovery == TunnelRecovery.waitingNetwork) {
      return 'Нет сети · подключение сохранено';
    }
    if (diagnostics.recovery == TunnelRecovery.reconnecting) return 'Восстанавливается';
    if (!diagnostics.connected) return 'Туннель выключен.';
    if (!_statisticsAvailable) {
      return 'Туннель включён. Статистика пока недоступна.';
    }
    return 'Туннель включён.';
  }

  String get _handshake {
    if (_current && !diagnostics.ownsTunnel && !diagnostics.transitioning) {
      return 'Нет активного туннеля';
    }
    if (!_statisticsAvailable) return 'Данные недоступны';
    final statistics = diagnostics.statistics;
    switch (statistics.handshakeStatus) {
      case HandshakeStatus.never:
        return 'Ещё не зафиксировано';
      case HandshakeStatus.unknown:
        return 'Данные недоступны';
      case HandshakeStatus.observed:
        final seconds = statistics.latestHandshakeAgeSeconds;
        if (seconds == null || seconds < 0) return 'Данные недоступны';
        if (seconds == 0) return 'Только что';
        if (seconds >= 365 * 86400) return 'Более года назад';
        return '${_duration(seconds)} назад';
    }
  }

  String _bytes(int? count) {
    if (!_statisticsAvailable || count == null || count < 0) return '—';
    if (count < 1024) return '$count Б';
    const units = ['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ', 'ПиБ', 'ЭиБ'];
    var amount = count.toDouble();
    var unit = 0;
    while (amount >= 1024 && unit < units.length - 1) {
      amount /= 1024;
      unit++;
    }
    return '${amount.toStringAsFixed(1).replaceAll('.', ',')} ${units[unit]}';
  }

  String _duration(int seconds) {
    if (seconds >= 365 * 86400) return 'Более года';
    if (seconds >= 86400) return '${seconds ~/ 86400} дн ${(seconds % 86400) ~/ 3600} ч';
    if (seconds >= 3600) return '${seconds ~/ 3600} ч ${(seconds % 3600) ~/ 60} мин';
    if (seconds >= 60) return '${seconds ~/ 60} мин ${seconds % 60} сек';
    return '$seconds сек';
  }

  Widget _metric(String label, String value, Key valueKey) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: PushokPalette.muted, fontSize: 12)),
        const SizedBox(height: 3),
        Text(value, key: valueKey, softWrap: true,
          style: const TextStyle(color: PushokPalette.text,
              fontSize: 16, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  void _showHelp(BuildContext context) {
    final transportHelp = _wireGuard
        ? 'Последний отклик показывает, когда туннель обменялся ключами '
          'хотя бы с одним узлом. Здесь показано последнее известное '
          'рукопожатие среди узлов профиля.\n\n'
          'Даже недавнее рукопожатие не подтверждает доступность сайтов, '
          'работу DNS или прямые маршруты исключённых приложений. '
          'Давнее рукопожатие возможно при простое и само по себе не означает сбой.'
        : diagnostics.protocol == TunnelProtocol.vless
            ? 'Состояние VLESS показывает работу локального туннеля. Само включение '
              'не подтверждает доступность сайтов, работу DNS или прямые маршруты '
              'исключённых приложений. Счётчики VLESS в этой версии недоступны.'
            : 'Протокол и свежие показатели пока неизвестны. Обновите диагностику. '
              'Состояние локального туннеля само по себе не подтверждает доступность сайтов.';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Что показывает диагностика'),
        scrollable: true,
        content: Text(
          '$transportHelp\n\n'
          'Получено и отправлено — накопленные счётчики туннеля, '
          'а не скорость соединения. Прямой трафик исключённых приложений '
          'в них не входит. После нового подключения счётчики могут начаться заново.',
        ),
        actions: [TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Понятно'),
        )],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PushokPanel(
      key: const Key('tunnel_diagnostics_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: Text('Диагностика связи',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            IconButton(
              key: const Key('info_tunnel_diagnostics'),
              tooltip: 'О диагностике связи',
              onPressed: () => _showHelp(context),
              icon: const Icon(Icons.info_outline),
            ),
            IconButton(
              key: const Key('refresh_tunnel_diagnostics'),
              tooltip: refreshing ? 'Обновляем диагностику' : 'Обновить диагностику',
              onPressed: refreshing ? null : onRefresh,
              icon: refreshing
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ]),
          const SizedBox(height: 6),
          Text(_summary, key: const Key('tunnel_diagnostics_summary'),
            style: const TextStyle(color: PushokPalette.muted)),
          if (!_current || diagnostics.recovering) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('recover_tunnel_disconnect'),
              onPressed: refreshing || disconnecting ? null : onDisconnect,
              icon: disconnecting
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.power_settings_new),
              label: Text(disconnecting ? 'Отключение…' : 'Отключить туннель'),
            ),
          ],
          if (_wireGuard)
            _metric('Последний отклик', _handshake,
                const Key('tunnel_handshake_value')),
          if (diagnostics.protocol == TunnelProtocol.vless)
            _metric('Протокол', 'VLESS', const Key('tunnel_protocol_value')),
          _metric('Получено', _bytes(diagnostics.statistics.rxBytes),
              const Key('tunnel_rx_value')),
          _metric('Отправлено', _bytes(diagnostics.statistics.txBytes),
              const Key('tunnel_tx_value')),
          _metric('Время работы туннеля',
              _active && diagnostics.uptimeSeconds >= 0
                  ? _duration(diagnostics.uptimeSeconds) : '—',
              const Key('tunnel_uptime_value')),
        ],
      ),
    );
  }
}
