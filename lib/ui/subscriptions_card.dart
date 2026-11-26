import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../models/moscow_time.dart';
import '../platform/subscription_diagnostics.dart';
import '../platform/subscriptions.dart';
import 'subscription_diagnostic_copy.dart';


class SubscriptionsCard extends StatelessWidget {
  const SubscriptionsCard({
    super.key, this.status, this.loading = false, this.busy = false,
    this.savingAutoUpdate = false,
    this.mutationsEnabled = false, this.error, this.pendingLink = false,
    this.errorDiagnostic, this.refreshDiagnostics = const {},
    this.isCurrentErrorDiagnostic, this.isCurrentRefreshDiagnostic,
    this.onAdd, this.onRefreshList, this.onRefresh, this.onDelete,
    this.onAutomaticUpdatesChanged, this.onOpenAccount, this.onOpenPendingLink,
    this.now, this.clock,
  });

  final SubscriptionStatus? status;
  final bool loading;
  final bool busy;
  final bool savingAutoUpdate;
  final bool mutationsEnabled;
  final String? error;
  final SubscriptionDiagnostic? errorDiagnostic;
  final Map<String, SubscriptionDiagnostic> refreshDiagnostics;
  final bool Function(SubscriptionDiagnostic)? isCurrentErrorDiagnostic;
  final bool Function(String, SubscriptionDiagnostic)? isCurrentRefreshDiagnostic;
  final bool pendingLink;
  final VoidCallback? onAdd;
  final VoidCallback? onRefreshList;
  final ValueChanged<FlowSubscription>? onRefresh;
  final ValueChanged<FlowSubscription>? onDelete;
  final ValueChanged<bool>? onAutomaticUpdatesChanged;
  final VoidCallback? onOpenAccount;
  final VoidCallback? onOpenPendingLink;
  final DateTime? now;
  /// An injectable live clock; a fixed [now] remains a deterministic snapshot.
  final DateTime Function()? clock;

  bool get _busy => busy || savingAutoUpdate || (status?.busy ?? false);
  bool get _canChange => mutationsEnabled && !_busy && !loading && status != null;

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
        'Для подписки откройте HTTPS-ссылку вашего провайдера или отсканируйте её QR-код. '
        'Проверьте название и нажмите «Добавить подписку».\n\n'
        'Для управления доступом нужна подписка в формате Flow от вашего сервиса. '
        'Обычный QR подключения или файл .conf добавляется как отдельный профиль. '
        'Сервис сообщает состояние и срок доступа. По истечении срока '
        'новые подключения недоступны, даже если настройки ещё сохранены на устройстве. '
        'Ответ сервиса об истечении или отзыве доступа удаляет серверы этой подписки. '
        'Flow не отключает уже работающий туннель автоматически; '
        'фактический доступ контролирует сервер.\n\n'
        'Автообновление проверяет список при открытии приложения, когда подключение '
        'Flow отключено: не чаще раза в шесть часов после успешной проверки. '
        'Ошибка одного сервиса не мешает проверке остальных подписок. '
        'Сетевые ошибки и повреждённые ответы не заменяют сохранённый список.\n\n'
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
    final refreshError = status?.refreshErrors[entry.id];
    final suppliedDiagnostic = refreshDiagnostics[entry.id];
    final matchingDiagnostic = refreshError != null && suppliedDiagnostic?.code == refreshError
        ? suppliedDiagnostic : null;
    final diagnostic = refreshError == null ? null : matchingDiagnostic ??
        SubscriptionDiagnostic.fromCode(refreshError,
          operation: SubscriptionDiagnosticOperation.refreshServers,
          source: SubscriptionDiagnosticSource.savedSubscription);
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
        Text(entry.isWireGuard
            ? '${entry.host} · Сохранено серверов: ${entry.profileCount}'
            : '${entry.host} · Серверов: ${entry.profileCount}',
          style: const TextStyle(color: PushokPalette.muted)),
        if (entry.skippedProfileCount > 0) ...[
          const SizedBox(height: 8),
          Semantics(liveRegion: true,
            child: Text('Несовместимых записей пропущено: ${entry.skippedProfileCount}. '
                'Доступные серверы добавлены.',
              key: ValueKey('subscription_skipped_profiles_${entry.id}'),
              style: const TextStyle(color: PushokPalette.orange))),
        ],
        const SizedBox(height: 8),
        _SubscriptionAccessDetails(
          key: ValueKey('subscription_access_details_${entry.id}'),
          entry: entry, now: now, clock: clock),
        if (entry.usedBytes != null) ...[
          const SizedBox(height: 6),
          Text(entry.totalBytes != null && entry.totalBytes! > 0
              ? 'Трафик: ${_bytes(entry.usedBytes!)} из ${_bytes(entry.totalBytes!)}'
              : 'Использовано: ${_bytes(entry.usedBytes!)}',
            style: const TextStyle(color: PushokPalette.muted)),
        ],
        const SizedBox(height: 6),
        Text('${entry.isWireGuard ? 'Подписка проверена' : 'Серверы обновлены'}: '
            '${formatMoscowDate(entry.updatedAt)}',
          style: const TextStyle(color: PushokPalette.muted, fontSize: 12)),
        if (refreshError != null) ...[
          const SizedBox(height: 10),
          Semantics(liveRegion: true,
            child: Text(subscriptionErrorMessage(PlatformException(code: refreshError)),
              key: ValueKey('subscription_refresh_error_${entry.id}'),
              style: const TextStyle(color: PushokPalette.orange))),
          if (diagnostic != null) SubscriptionDiagnosticCopy(
            key: ValueKey('subscription_refresh_diagnostic_${entry.id}'),
            diagnostic: diagnostic,
            errorIdentity: matchingDiagnostic ?? (status, entry.id, refreshError),
            buttonKey: ValueKey('copy_subscription_refresh_error_${entry.id}'),
            noticeKey: ValueKey('subscription_refresh_error_copy_notice_${entry.id}'),
            enabled: !_busy && !loading,
            isCurrentError: () => isCurrentRefreshDiagnostic?.call(entry.id, diagnostic) ?? true),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(key: ValueKey('refresh_subscription_${entry.id}'),
            onPressed: _canChange && onRefresh != null ? () => onRefresh!(entry) : null,
            icon: const Icon(Icons.refresh), label: Text(refreshError == null
              ? 'Обновить серверы' : 'Повторить обновление')),
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
          const Text('Добавьте ссылку или QR-код подписки, чтобы получать актуальные серверы.',
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
          if (error != null && errorDiagnostic != null) SubscriptionDiagnosticCopy(
            key: const Key('subscriptions_error_diagnostic'),
            diagnostic: errorDiagnostic!,
            buttonKey: const Key('copy_subscriptions_error'),
            noticeKey: const Key('subscriptions_error_copy_notice'),
            enabled: !_busy && !loading,
            isCurrentError: () => isCurrentErrorDiagnostic?.call(errorDiagnostic!) ?? true),
          if (status?.refreshErrors.isNotEmpty ?? false)
            Padding(padding: const EdgeInsets.only(top: 12),
              child: Semantics(liveRegion: true,
                child: const Text('Не все подписки удалось обновить. '
                    'Подробности — в карточках ниже.',
                  key: Key('subscriptions_refresh_warning'),
                  style: TextStyle(color: PushokPalette.orange)))),
          if (status != null) ...[
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              key: const Key('automatic_subscription_updates'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Обновлять серверы'),
              subtitle: const Text('Проверка при открытии Flow'),
              value: status!.automaticUpdatesEnabled,
              onChanged: savingAutoUpdate ||
                  ((_busy || loading) && !status!.automaticUpdatesEnabled)
                      ? null : onAutomaticUpdatesChanged,
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

/// The deadline only refreshes visible metadata. It never fetches a feed,
/// mutates profiles or changes a running tunnel.
class _SubscriptionAccessDetails extends StatefulWidget {
  const _SubscriptionAccessDetails({super.key, required this.entry, this.now, this.clock});
  final FlowSubscription entry;
  final DateTime? now;
  final DateTime Function()? clock;

  @override
  State<_SubscriptionAccessDetails> createState() => _SubscriptionAccessDetailsState();
}

class _SubscriptionAccessDetailsState extends State<_SubscriptionAccessDetails>
    with WidgetsBindingObserver {
  Timer? _deadline;
  bool _foreground = true;

  DateTime get _now => widget.now ?? widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _scheduleDeadline();
  }

  @override
  void didUpdateWidget(covariant _SubscriptionAccessDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleDeadline();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _foreground = state == AppLifecycleState.resumed;
    _deadline?.cancel();
    if (_foreground) {
      setState(() {});
      _scheduleDeadline();
    }
  }

  void _scheduleDeadline() {
    _deadline?.cancel();
    final entry = widget.entry;
    final expiry = entry.expiresAt;
    if (!_foreground || widget.now != null || !entry.isWireGuard ||
        entry.state != SubscriptionAccessState.active || expiry == null) return;
    final remaining = expiry.difference(_now);
    if (remaining <= Duration.zero) return;
    _deadline = Timer(remaining, () {
      if (!mounted || !_foreground) return;
      setState(() {});
      _scheduleDeadline();
    });
  }

  @override
  void dispose() {
    _deadline?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final expiry = entry.expiresAt;
    final now = _now;
    final state = entry.effectiveState(now);
    final expired = expiry != null && !expiry.isAfter(now);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (entry.isWireGuard) ...[
        Semantics(liveRegion: true, child: Text(switch (state) {
          SubscriptionAccessState.active => 'Доступ активен.',
          SubscriptionAccessState.expired =>
            'Срок доступа истёк. Новые подключения недоступны.',
          SubscriptionAccessState.revoked =>
            'Доступ отозван сервисом. Новые подключения недоступны.',
        }, key: ValueKey('subscription_access_state_${entry.id}'),
          style: TextStyle(color: state == SubscriptionAccessState.active
              ? PushokPalette.mint : PushokPalette.orange))),
        const SizedBox(height: 6),
      ],
      Text(entry.isWireGuard && expiry != null
          ? 'Срок доступа: до ${formatMoscowDate(expiry, includeTime: true)}.'
          : expiry == null ? 'Сервис не передал срок подписки.'
              : expired ? 'По данным сервиса срок истёк ${formatMoscowDate(expiry)}.'
                  : 'Срок по данным сервиса: до ${formatMoscowDate(expiry)}.',
        key: ValueKey('subscription_expiry_${entry.id}'),
        style: TextStyle(color: entry.isWireGuard
            ? state == SubscriptionAccessState.active ? PushokPalette.muted : PushokPalette.orange
            : expired ? PushokPalette.orange : PushokPalette.muted)),
    ]);
  }
}
