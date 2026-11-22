import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/subscriptions.dart';

class SubscriptionsCard extends StatelessWidget {
  const SubscriptionsCard({
    super.key, this.status, this.loading = false, this.busy = false,
    this.mutationsEnabled = false, this.error, this.pendingLink = false,
    this.onAdd, this.onRefreshList, this.onRefresh, this.onDelete,
    this.onAutomaticUpdatesChanged, this.onOpenAccount, this.onOpenPendingLink,
    this.now,
  });

  final SubscriptionStatus? status;
  final bool loading;
  final bool busy;
  final bool mutationsEnabled;
  final String? error;
  final bool pendingLink;
  final VoidCallback? onAdd;
  final VoidCallback? onRefreshList;
  final ValueChanged<FlowSubscription>? onRefresh;
  final ValueChanged<FlowSubscription>? onDelete;
  final ValueChanged<bool>? onAutomaticUpdatesChanged;
  final VoidCallback? onOpenAccount;
  final VoidCallback? onOpenPendingLink;
  final DateTime? now;

  bool get _busy => busy || (status?.busy ?? false);
  bool get _canChange => mutationsEnabled && !_busy && !loading && status != null;

  String _date(DateTime date) {
    final value = date.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.day)}.${two(value.month)}.${value.year}';
  }

  String _bytes(int amount) {
    if (amount < 1024) return '$amount Б';
    if (amount < 1024 * 1024) return '${(amount / 1024).toStringAsFixed(1)} КБ';
    if (amount < 1024 * 1024 * 1024) {
      return '${(amount / (1024 * 1024)).toStringAsFixed(1)} МБ';
    }
    return '${(amount / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГБ';
  }

  void _showHelp(BuildContext context) {
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Подписки и серверы'),
      content: const SingleChildScrollView(child: Text(
        'Вход и регистрация доступны в существующем кабинете MTProxy '
        '(${FlowSubscriptions.botUsername}).\n\n'
        'Для подключения Flow добавьте HTTPS-ссылку подписки своего провайдера '
        'или панели с поддерживаемыми ссылками VLESS. '
        'Аккаунт MTProxy сам по себе не предоставляет серверы для Flow.\n\n'
        'Flow загружает список серверов и сохраняет его на устройстве. '
        'Автообновление проверяет список при открытии приложения, когда подключение '
        'Flow отключено: не чаще раза в шесть часов после успешной проверки. '
        'После ошибки сохранённые настройки остаются доступны.\n\n'
        'Срок и расход трафика отображаются, если сервис передал эти данные. '
        'Они не заменяют информацию об оплате в магазине. '
        'Удаление подписки из Flow удаляет её локальные серверы; '
        'оплаченный доступ и автосписания в магазине этим не отменяются.'
      )),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(),
        child: const Text('Понятно'))],
    ));
  }

  Widget _subscription(FlowSubscription entry) {
    final expiry = entry.expiresAt;
    final expired = expiry != null && !expiry.isAfter(now ?? DateTime.now());
    return PushokPanel(
      key: ValueKey('subscription_${entry.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 3),
            child: Icon(Icons.link, color: PushokPalette.glowCyan)),
          const SizedBox(width: 10),
          Expanded(child: Text(entry.name,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 8),
        Text('${entry.host} · Серверов: ${entry.profileCount}',
          style: const TextStyle(color: PushokPalette.muted)),
        const SizedBox(height: 8),
        Text(expiry == null ? 'Сервис не передал срок подписки.'
            : expired ? 'По данным сервиса срок истёк ${_date(expiry)}.'
                : 'Срок по данным сервиса: до ${_date(expiry)}.',
          key: ValueKey('subscription_expiry_${entry.id}'),
          style: TextStyle(color: expired ? PushokPalette.orange : PushokPalette.muted)),
        if (entry.usedBytes != null) ...[
          const SizedBox(height: 6),
          Text(entry.totalBytes != null && entry.totalBytes! > 0
              ? 'Трафик: ${_bytes(entry.usedBytes!)} из ${_bytes(entry.totalBytes!)}'
              : 'Использовано: ${_bytes(entry.usedBytes!)}',
            style: const TextStyle(color: PushokPalette.muted)),
        ],
        const SizedBox(height: 6),
        Text('Серверы обновлены: ${_date(entry.updatedAt)}',
          style: const TextStyle(color: PushokPalette.muted, fontSize: 12)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(key: ValueKey('refresh_subscription_${entry.id}'),
            onPressed: _canChange && onRefresh != null ? () => onRefresh!(entry) : null,
            icon: const Icon(Icons.refresh), label: const Text('Обновить серверы')),
          OutlinedButton.icon(key: ValueKey('delete_subscription_${entry.id}'),
            onPressed: _canChange && onDelete != null ? () => onDelete!(entry) : null,
            icon: const Icon(Icons.delete_outline), label: const Text('Удалить')),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('subscriptions_card'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PushokPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Expanded(child: Text('Подписки',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
            IconButton(key: const Key('subscriptions_info'), tooltip: 'О подписках',
              onPressed: () => _showHelp(context), icon: const Icon(Icons.info_outline)),
            IconButton(key: const Key('refresh_subscriptions_list'),
              tooltip: 'Обновить список подписок',
              onPressed: loading || _busy ? null : onRefreshList,
              icon: const Icon(Icons.refresh)),
          ]),
          const Text('Добавьте ссылку, чтобы получать актуальные серверы.',
            style: TextStyle(color: PushokPalette.muted)),
          if (loading || _busy) const Padding(padding: EdgeInsets.only(top: 12),
            child: Row(children: [
              SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10), Expanded(child: Text('Обновляем подписки…')),
            ])),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Semantics(liveRegion: true,
              child: Text(error!, key: const Key('subscriptions_error'),
                style: const TextStyle(color: PushokPalette.orange)))),
          if (status != null) ...[
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              key: const Key('automatic_subscription_updates'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Обновлять серверы'),
              subtitle: const Text('Проверка при открытии Flow'),
              value: status!.automaticUpdatesEnabled,
              onChanged: _busy || loading ? null : onAutomaticUpdatesChanged,
            ),
          ],
          if (pendingLink) ...[
            const SizedBox(height: 12),
            const Text('Получена ссылка подписки. Добавьте её после отключения Flow.',
              key: Key('pending_subscription_link'),
              style: TextStyle(color: PushokPalette.mint)),
            const SizedBox(height: 8),
            OutlinedButton.icon(key: const Key('open_pending_subscription_link'),
              onPressed: _canChange ? onOpenPendingLink : null,
              icon: const Icon(Icons.add_link), label: const Text('Добавить полученную подписку')),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(key: const Key('add_subscription'),
            onPressed: _canChange && status!.subscriptions.length <
                SubscriptionStatus.maxSubscriptions ? onAdd : null,
            icon: const Icon(Icons.add_link), label: const Text('Добавить подписку')),
          const SizedBox(height: 8),
          OutlinedButton.icon(key: const Key('manage_pushok_subscription'),
            onPressed: onOpenAccount, icon: const Icon(Icons.open_in_new),
            label: const Text('Кабинет MTProxy')),
        ])),
      for (final entry in status?.subscriptions ?? const <FlowSubscription>[]) ...[
        const SizedBox(height: 12),
        _subscription(entry),
      ],
    ],
  );
}
