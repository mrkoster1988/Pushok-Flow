import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/account.dart';
import '../platform/subscriptions.dart';

enum _LocalAccountClear { cancelLogin, logout, recoverAccount }

class PushokAccountCard extends StatefulWidget {
  const PushokAccountCard({super.key, required this.isAndroid, this.account,
    this.subscriptions, this.onShopSynced,
    this.onOpenCabinet, this.onOpenHub, this.now});
  final bool isAndroid;
  final FlowAccount? account;
  final FlowSubscriptions? subscriptions;
  final VoidCallback? onShopSynced;
  final VoidCallback? onOpenCabinet;
  final VoidCallback? onOpenHub;
  final DateTime Function()? now;

  @override
  State<PushokAccountCard> createState() => _PushokAccountCardState();
}

class _PushokAccountCardState extends State<PushokAccountCard> with WidgetsBindingObserver {
  late final FlowAccount _account;
  late final FlowSubscriptions _shop;
  bool _shopAutoSync = false;
  bool _shopBusy = false;
  String _shopSyncState = 'idle';
  String? _shopError;
  int _shopEpoch = 0;
  String? _shopAccountId;
  DateTime? _shopLastAttempt;
  FlowAccountStatus? _status;
  String? _error;
  bool _busy = false;
  bool _foreground = true;
  bool _recoveryDialogOpen = false;
  _LocalAccountClear? _clearingAccount;
  String? _cancellingUserCode;
  int _epoch = 0;
  Timer? _poll;
  Timer? _viewTimer;
  Timer? _shopPendingPoll;
  int? _expiryChecked;

  int get _nowMs => (widget.now?.call() ?? DateTime.now()).millisecondsSinceEpoch;
  int? get _expiresAt => _status?.pending?.expiresAt ?? _status?.sessionExpiresAt;
  bool get _expired => _expiresAt != null && _expiresAt! <= _nowMs;

  @override
  void initState() {
    super.initState();
    _account = widget.account ?? FlowAccount(isAndroid: widget.isAndroid);
    _shop = widget.subscriptions ?? FlowSubscriptions(isAndroid: widget.isAndroid);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    if (widget.isAndroid) unawaited(_read());
  }

  @override
  void dispose() {
    _epoch++;
    _shopEpoch++;
    _poll?.cancel();
    _viewTimer?.cancel();
    _shopPendingPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    _shopEpoch++;
    _shopBusy = false;
    _poll?.cancel();
    _viewTimer?.cancel();
    _shopPendingPoll?.cancel();
    _foreground = state == AppLifecycleState.resumed;
    // A response from before switching to Telegram must not overwrite the
    // fresh, durable native snapshot read on return.
    _busy = false;
    if (_foreground && widget.isAndroid) unawaited(_read());
  }

  void _schedulePoll() {
    _poll?.cancel();
    final pending = _status?.pending;
    if (!mounted || !_foreground || _busy || _clearingAccount != null ||
        pending == null || _expired || !widget.isAndroid) return;
    final now = _nowMs;
    final delay = (pending.nextPollAt - now).clamp(1000, 60000).toInt();
    _poll = Timer(Duration(milliseconds: delay), () => unawaited(_run(_account.pollLogin)));
  }

  void _scheduleViewUpdate() {
    _viewTimer?.cancel();
    if (!mounted || !_foreground || _clearingAccount != null || !widget.isAndroid) return;
    final expires = _expiresAt;
    if (expires == null) { _expiryChecked = null; return; }
    final now = _nowMs;
    if (expires <= now) {
      // Read the native authority once at this deadline. A failed bridge must not
      // create an immediate retry loop; the expired data is already hidden locally.
      if (!_busy && _expiryChecked != expires) {
        _expiryChecked = expires;
        _viewTimer = Timer(Duration.zero, () => unawaited(_run(_account.status)));
      }
      return;
    }
    _expiryChecked = null;
    var next = expires;
    final refreshed = _status?.refreshedAt;
    if (_status?.state == FlowAccountState.connected && !(_status?.stale ?? false) && refreshed != null) {
      final staleAt = refreshed + 5 * 60000;
      if (staleAt > now && staleAt < next) next = staleAt;
    }
    _viewTimer = Timer(Duration(milliseconds: next - now), () {
      if (!mounted || !_foreground) return;
      // Age labels change locally; only an expiry edge asks native code to clear
      // its durable record. No network refresh or new login starts from this timer.
      setState(() {});
      _scheduleViewUpdate();
    });
  }

  Future<void> _read() async {
    if (!await _run(_account.status)) return;
    final status = _status;
    if (!mounted || !_foreground || _busy || _clearingAccount != null ||
        _expired || status?.state != FlowAccountState.connected) return;
    final age = _nowMs - (status!.refreshedAt ?? 0);
    if (status.stale || age > 60000) await _run(_account.refresh);
  }

  Future<bool> _run(Future<FlowAccountStatus> Function() action,
      {_LocalAccountClear? clearing, String? cancellingUserCode}) async {
    if (!mounted || !_foreground || !widget.isAndroid ||
        (_busy && (clearing == null || _clearingAccount != null))) return false;
    final epoch = ++_epoch;
    _poll?.cancel();
    if (clearing != null) _viewTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      if (clearing != null) {
        _clearingAccount = clearing;
        _cancellingUserCode = cancellingUserCode;
      }
    });
    try {
      final status = await action();
      if (!mounted || !_foreground || epoch != _epoch) return false;
      setState(() {
        _status = status;
        final accountId = status.state == FlowAccountState.connected
            ? status.profile?.id : null;
        if (_shopAccountId != accountId) {
          _shopAccountId = accountId;
          _shopEpoch++;
          _shopBusy = false;
          _shopSyncState = 'idle';
          _shopError = null;
          _shopLastAttempt = null;
          _shopPendingPoll?.cancel();
        }
        // Keep identity/code hidden until native code confirms a durable local
        // clear. A failed store is fail-closed in memory but its disk state is
        // uncertain; it must not be presented as a completed logout.
        if (_clearingAccount != null && !status.busy &&
            status.state == FlowAccountState.signedOut &&
            !status.recoveryAvailable && status.errorCode != 'FLOW_STORE_UNAVAILABLE') {
          _clearingAccount = null;
          _cancellingUserCode = null;
        } else if (_clearingAccount == _LocalAccountClear.recoverAccount &&
            !status.recoveryAvailable &&
            (!status.busy || status.errorCode == 'FLOW_RECOVERY_NOT_REQUIRED')) {
          // A newer healthy login can reject an old recovery request, even
          // while its own network operation is still busy. Keep that login.
          _clearingAccount = null;
          _cancellingUserCode = null;
        } else if (clearing == _LocalAccountClear.cancelLogin &&
            !status.busy && status.errorCode == 'FLOW_INTERRUPTED') {
          // The qualified cancel was rejected because native state has moved
          // on. Show that authoritative state and its interruption message;
          // retrying the old public code cannot cancel a newer login.
          _clearingAccount = null;
          _cancellingUserCode = null;
        }
      });
      return true;
    } catch (error) {
      if (!mounted || !_foreground || epoch != _epoch) return false;
      setState(() => _error = flowAccountErrorMessage(error));
      return false;
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _busy = false);
        _schedulePoll();
        _scheduleViewUpdate();
        if (_foreground && _status?.state == FlowAccountState.connected &&
            _status?.profile != null && _clearingAccount == null) {
          unawaited(_readShopSettings(automatic: true));
        }
      }
    }
  }

  Future<void> _readShopSettings({bool automatic = false}) async {
    if (!mounted || !_foreground || !widget.isAndroid || _shopBusy ||
        _status?.state != FlowAccountState.connected || _status?.profile == null ||
        _clearingAccount != null) return;
    final accountId = _status!.profile!.id;
    final epoch = ++_shopEpoch;
    try {
      final value = await _shop.status();
      if (!mounted || !_foreground || epoch != _shopEpoch ||
          _status?.profile?.id != accountId) return;
      setState(() {
        _shopAutoSync = value.shopAutoSyncEnabled;
        _shopSyncState = value.shopSyncState;
      });
      if (automatic && value.shopAutoSyncEnabled) {
        unawaited(_syncShop(automatic: true));
      }
    } catch (_) {
      // On old APKs the channel may be absent; this read must not affect login.
      // Explicit sync will report a useful error and keeps the account intact.
    }
  }

  // A new WGDashboard peer is provisioned asynchronously. Keep checking a
  // pending claim on this visible screen so a user does not have to reopen Flow.
  // The signed MTProxy ticket is acquired afresh for every attempt; never cache it.
  void _schedulePendingShopPoll() {
    _shopPendingPoll?.cancel();
    if (!mounted || !_foreground || !_shopAutoSync ||
        _shopSyncState != 'pending' || _shopBusy || _busy || _expired ||
        _clearingAccount != null || _status?.state != FlowAccountState.connected ||
        _status?.profile?.id == null) return;
    final accountId = _status!.profile!.id;
    _shopPendingPoll = Timer(const Duration(seconds: 45), () {
      if (!mounted || !_foreground || accountId != _status?.profile?.id) return;
      unawaited(_syncShop(automatic: true));
    });
  }

  Future<void> _setShopAutoSync(bool value) async {
    if (!mounted || !_foreground || _shopBusy) return;
    final accountId = _status?.profile?.id;
    final epoch = ++_shopEpoch;
    _shopPendingPoll?.cancel();
    setState(() { _shopBusy = true; _shopError = null; });
    try {
      final updated = await _shop.setShopAutoSync(value);
      if (!mounted || !_foreground || epoch != _shopEpoch ||
          accountId != _status?.profile?.id) return;
      setState(() {
        _shopAutoSync = updated.shopAutoSyncEnabled;
        _shopSyncState = updated.shopSyncState;
      });
    } catch (error) {
      if (mounted && _foreground && epoch == _shopEpoch) {
        setState(() => _shopError = subscriptionErrorMessage(error));
      }
    } finally {
      if (mounted && epoch == _shopEpoch) {
        setState(() => _shopBusy = false);
        if (value && _shopAutoSync) unawaited(_syncShop(automatic: true));
        else _schedulePendingShopPoll();
      }
    }
  }

  Future<void> _syncShop({bool automatic = false}) async {
    if (!mounted || !_foreground || !widget.isAndroid ||
        _busy || _shopBusy || _clearingAccount != null ||
        _status?.state != FlowAccountState.connected ||
        _status?.profile == null || _expired) return;
    final accountId = _status!.profile!.id;
    final now = widget.now?.call() ?? DateTime.now();
    if (automatic && _shopLastAttempt != null &&
        now.difference(_shopLastAttempt!) < (_shopSyncState == 'pending'
            ? const Duration(seconds: 40) : const Duration(minutes: 5))) return;
    _shopLastAttempt = now;
    _shopPendingPoll?.cancel();
    final epoch = ++_shopEpoch;
    setState(() {
      _shopBusy = true;
      _shopError = null;
    });
    try {
      final status = await _shop.syncShop();
      if (!mounted || !_foreground || epoch != _shopEpoch ||
          _status?.profile?.id != accountId) return;
      setState(() => _shopSyncState = status.shopSyncState);
      if (status.shopSyncState == 'active') widget.onShopSynced?.call();
    } catch (error) {
      if (mounted && _foreground && epoch == _shopEpoch) {
        setState(() => _shopError = subscriptionErrorMessage(error));
      }
    } finally {
      if (mounted && epoch == _shopEpoch) {
        setState(() => _shopBusy = false);
        _schedulePendingShopPoll();
      }
    }
  }

  Future<void> _unlinkShop() async {
    if (!mounted || !_foreground || _shopBusy) return;
    final accountId = _status?.profile?.id;
    if (accountId == null) return;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Отвязать подключение?'),
      content: const SingleChildScrollView(child: Text(
        'Личная WireGuard-подписка будет удалена только с этого телефона. '
        'Остальные серверы и настройки аккаунта сохранятся. '
        'Перед отвязкой отключите туннель. '
        'Это действие не отзывает уже выданный ключ на сервере Shop.'
      )),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена')),
        FilledButton(key: const Key('confirm_shop_unlink'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Отвязать')),
      ],
    ));
    if (accepted != true || !mounted || !_foreground ||
        accountId != _status?.profile?.id || _shopBusy) return;
    final epoch = ++_shopEpoch;
    setState(() { _shopBusy = true; _shopError = null; });
    try {
      final result = await _shop.unlinkShop();
      if (mounted && epoch == _shopEpoch) {
        setState(() { _shopSyncState = result.shopSyncState; _shopLastAttempt = null; });
        widget.onShopSynced?.call();
      }
    } catch (error) {
      if (mounted && epoch == _shopEpoch) {
        setState(() => _shopError = subscriptionErrorMessage(error));
      }
    } finally {
      if (mounted && epoch == _shopEpoch) setState(() => _shopBusy = false);
    }
  }

  String _shopStateText() => switch (_shopSyncState) {
    'active' => 'Личная подписка добавлена. Выберите сервер и нажмите «Подключить».',
    'pending' => 'WGDashboard готовит подключение. Flow проверит готовность автоматически.',
    'expired' => 'Срок личного подключения истёк. Продлите его в Shop.',
    'revoked' => 'Личное подключение отозвано на сервере.',
    'disabled' => 'Автоматическая выдача доступа пока не включена владельцем Shop.',
    'unavailable' => 'В Shop пока нет доступного подключения для вашего аккаунта.',
    'link_disabled' => 'Личная ссылка отключена в Shop. Включите её в кабинете.',
    _ => 'Получайте действующую подписку WireGuard без QR-кода.',
  };

  Widget _shopControls(bool enabled) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 26),
      const Text('Мои подключения Pushok',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 5),
      const Text('Shop выдаёт только ваше личное подключение. '
        'При первом получении подтвердите обмен данными между MTProxy и Shop. '
        'Административные ключи приложению не передаются.',
        style: TextStyle(color: PushokPalette.muted)),
      SwitchListTile.adaptive(
        key: const Key('shop_auto_sync'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Получать подключения автоматически'),
        subtitle: const Text('При входе или возвращении на экран профиля'),
        value: _shopAutoSync,
        onChanged: enabled && !_shopBusy ? (value) =>
          unawaited(_setShopAutoSync(value)) : null,
      ),
      const SizedBox(height: 5),
      FilledButton.icon(
        key: const Key('shop_sync_now'),
        onPressed: enabled && !_shopBusy ? () => unawaited(_syncShop()) : null,
        icon: _shopBusy
            ? const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.sync),
        label: Text(_shopBusy ? 'Получаем личное подключение…' : 'Получить моё подключение'),
      ),
      const SizedBox(height: 7),
      Text(_shopStateText(), key: const Key('shop_sync_state'),
        style: const TextStyle(color: PushokPalette.muted)),
      if (_shopError != null) Padding(padding: const EdgeInsets.only(top: 6),
        child: Text(_shopError!, key: const Key('shop_sync_error'),
          style: const TextStyle(color: PushokPalette.orange))),
      TextButton(
        key: const Key('shop_unlink'),
        onPressed: enabled && !_shopBusy ? () => unawaited(_unlinkShop()) : null,
        child: const Text('Отвязать личное подключение на телефоне'),
      ),
    ],
  );

  Future<void> _openLogin() async {
    await _run(() async {
      await _account.openLogin();
      return _account.status();
    });
  }

  Future<void> _clearAccount(_LocalAccountClear clearing, {String? userCode}) async {
    final cancelCode = userCode ?? _cancellingUserCode;
    if (clearing == _LocalAccountClear.cancelLogin && cancelCode == null) return;
    await _run(switch (clearing) {
      _LocalAccountClear.logout => _account.logout,
      _LocalAccountClear.recoverAccount => _account.recoverLocalAccount,
      _LocalAccountClear.cancelLogin => () => _account.cancelLogin(cancelCode!),
    },
      clearing: clearing, cancellingUserCode: cancelCode);
  }

  Future<void> _confirmRecovery() async {
    if (!mounted || !_foreground || _busy || _recoveryDialogOpen ||
        !(_status?.recoveryAvailable ?? false)) return;
    final epoch = _epoch;
    setState(() => _recoveryDialogOpen = true);
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Восстановить вход?'),
      content: const SingleChildScrollView(child: Text(
        'Flow удалит сохранённый вход в аккаунт на этом устройстве. '
        'После восстановления нужно будет снова войти через Telegram.\n\n'
        'Аккаунт и баланс в кабинете MTProxy, добавленные серверы и подписки сохранятся.'
      )),
      actions: [
        TextButton(key: const Key('cancel_account_recovery'),
          onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
        FilledButton(key: const Key('confirm_account_recovery'),
          onPressed: () => Navigator.of(context).pop(true), child: const Text('Восстановить вход')),
      ],
    ));
    if (!mounted) return;
    setState(() => _recoveryDialogOpen = false);
    // Returning from another app refreshes native state. A dialog opened for
    // an older snapshot cannot authorize clearing that refreshed account.
    if (confirmed != true || !_foreground || epoch != _epoch ||
        !(_status?.recoveryAvailable ?? false)) return;
    await _clearAccount(_LocalAccountClear.recoverAccount);
  }

  void _help() {
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Аккаунт Pushok'),
      content: const SingleChildScrollView(child: Text(
        'Вход использует существующий аккаунт MTProxy. Подтвердите запрос '
        'в его кабинете и сравните код с кодом в Flow.\n\n'
        'Flow получает имя, роль, признак подтверждения телефона и баланс '
        'кабинета MTProxy. Списание денег и управление рекламой отсюда недоступны. '
        'Сессия действует 12 часов.\n\n'
        'Баланс MTProxy и подключение серверов Flow учитываются отдельно. '
        'Свою WireGuard-подписку можно получить в этом профиле после отдельного согласия. '
        'Серверы можно также добавлять в разделе «Серверы».'
      )),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(),
        child: const Text('Понятно'))],
    ));
  }

  Widget _walletValue(String title, String amount, String key) => Expanded(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: PushokPalette.muted, fontSize: 12)),
      const SizedBox(height: 5),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
        child: Text(amount, key: ValueKey(key),
          style: const TextStyle(color: PushokPalette.teal, fontSize: 17, fontWeight: FontWeight.w700))),
    ]),
  );

  Widget _profile(FlowAccountProfile profile) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Icon(Icons.person_outline, size: 30, color: PushokPalette.teal),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(profile.displayName, key: const Key('account_display_name'),
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          Text(profile.roleLabel, style: const TextStyle(color: PushokPalette.muted)),
        ])),
        if (profile.phoneVerified) const Tooltip(message: 'Телефон подтверждён в кабинете',
          child: Icon(Icons.verified, color: PushokPalette.glowCyan, size: 22)),
      ]),
      const SizedBox(height: 18),
      const Text('Баланс кабинета MTProxy', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _walletValue('Рубли', '${formatFlowWalletAmount(profile.wallet.rubles)} ₽', 'account_wallet_rub'),
        const SizedBox(width: 10),
        _walletValue('Бонусы', formatFlowWalletAmount(profile.wallet.bonuses), 'account_wallet_bonus'),
        const SizedBox(width: 10),
        _walletValue('Stars', formatFlowWalletAmount(profile.wallet.stars, fractional: false), 'account_wallet_xtr'),
      ]),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final expired = _expired;
    final pending = expired ? null : status?.pending;
    final connected = status?.state == FlowAccountState.connected && !expired;
    final stale = (status?.stale ?? false) || (connected &&
      _nowMs - (status?.refreshedAt ?? 0) >= 5 * 60000);
    final clearing = _clearingAccount;
    final recoveryAvailable = status?.recoveryAvailable ?? false;
    final enabled = widget.isAndroid && _foreground && !_busy &&
        !_recoveryDialogOpen && clearing == null && !(status?.busy ?? false);
    // Cancellation/logout supersede reads and polling in the native authority.
    // Only another local-clear request remains blocked until its own reply.
    final canClear = widget.isAndroid && _foreground && !(_busy && clearing != null);
    final errorCode = expired
      ? status?.pending != null ? 'FLOW_LOGIN_EXPIRED' : 'FLOW_SESSION_EXPIRED'
      : status?.errorCode;
    final error = _error ?? (errorCode == null ? null : flowAccountErrorMessage(errorCode));
    return PushokPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('Аккаунт Pushok',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(key: const Key('account_info'), onPressed: _help,
          tooltip: 'Об аккаунте', icon: const Icon(Icons.info_outline, color: PushokPalette.teal)),
      ]),
      const SizedBox(height: 8),
      if (!widget.isAndroid)
        const Text('Вход доступен в приложении для Android.', style: TextStyle(color: PushokPalette.muted))
      else if (clearing != null) ...[
        Text(switch ((clearing, _busy)) {
          (_LocalAccountClear.logout, true) => 'Выходим из аккаунта…',
          (_LocalAccountClear.logout, false) => 'Выход ещё не подтверждён.',
          (_LocalAccountClear.cancelLogin, true) => 'Отменяем вход…',
          (_LocalAccountClear.cancelLogin, false) => 'Отмена входа ещё не подтверждена.',
          (_LocalAccountClear.recoverAccount, true) => 'Восстанавливаем вход…',
          (_LocalAccountClear.recoverAccount, false) => 'Восстановление ещё не подтверждено.',
        },
          key: const Key('flow_account_clearing'), style: const TextStyle(color: PushokPalette.muted)),
        if (!_busy && (!recoveryAvailable || clearing == _LocalAccountClear.recoverAccount)) TextButton(
          key: const Key('retry_flow_account_clear'),
          onPressed: canClear ? () => unawaited(_clearAccount(clearing)) : null,
          child: Text(switch (clearing) {
            _LocalAccountClear.logout => 'Повторить выход',
            _LocalAccountClear.cancelLogin => 'Повторить отмену',
            _LocalAccountClear.recoverAccount => 'Повторить восстановление',
          })),
      ]
      else if (recoveryAvailable)
        const Text('Чтобы снова подключить аккаунт MTProxy, восстановите вход на этом устройстве.',
          key: Key('flow_account_recovery_needed'), style: TextStyle(color: PushokPalette.muted))
      else if (status == null && _busy)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()))
      else if (connected) ...[
        if (status!.profile != null) _profile(status.profile!)
        else const Text('Аккаунт подключён. Обновите профиль, чтобы получить данные кабинета.'),
        if (stale) const Padding(padding: EdgeInsets.only(top: 10),
          child: Text('Показаны сохранённые данные. Требуется обновление.',
            key: Key('account_stale'), style: TextStyle(color: PushokPalette.muted))),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 6, children: [
          OutlinedButton.icon(key: const Key('refresh_flow_account'),
            onPressed: enabled ? () => unawaited(_run(_account.refresh)) : null,
            icon: const Icon(Icons.refresh), label: const Text('Обновить профиль')),
          TextButton.icon(key: const Key('logout_flow_account'),
            onPressed: canClear ? () => unawaited(_clearAccount(_LocalAccountClear.logout)) : null,
            icon: const Icon(Icons.logout), label: const Text('Выйти')),
        ]),
        if (status.profile != null) _shopControls(enabled),
      ] else if (pending != null) ...[
        const Text('Подтвердите вход в кабинете MTProxy и вернитесь в Flow.'),
        const SizedBox(height: 12),
        const Text('Код должен совпадать в обоих приложениях:', style: TextStyle(color: PushokPalette.muted)),
        const SizedBox(height: 6),
        SelectableText(pending.displayCode, key: const Key('flow_account_code'),
          style: const TextStyle(color: PushokPalette.teal, fontSize: 21,
            fontWeight: FontWeight.w700, letterSpacing: 1)),
        const SizedBox(height: 10),
        const Text('Ожидаем подтверждения…', key: Key('flow_account_waiting'),
          style: TextStyle(color: PushokPalette.muted)),
        const SizedBox(height: 10),
        OutlinedButton.icon(key: const Key('reopen_flow_login'),
          onPressed: enabled ? () => unawaited(_openLogin()) : null,
          icon: const Icon(Icons.open_in_new), label: const Text('Открыть подтверждение')),
        TextButton(key: const Key('cancel_flow_login'),
          onPressed: canClear ? () => unawaited(_clearAccount(
            _LocalAccountClear.cancelLogin, userCode: pending.userCode)) : null,
          child: const Text('Отменить вход')),
      ] else ...[
        const Text('Войдите через Telegram, чтобы видеть свой профиль и баланс кабинета MTProxy.',
          style: TextStyle(color: PushokPalette.muted)),
        const SizedBox(height: 12),
        FilledButton.icon(key: const Key('begin_flow_login'),
          onPressed: enabled && status != null ? () => unawaited(_run(_account.beginLogin)) : null,
          icon: const Icon(Icons.login), label: const Text('Войти через Telegram')),
      ],
      if (recoveryAvailable && clearing != _LocalAccountClear.recoverAccount) ...[
        const SizedBox(height: 12),
        FilledButton.icon(key: const Key('recover_flow_account'),
          onPressed: _foreground && !_busy && !_recoveryDialogOpen && !(status?.busy ?? false)
            ? () => unawaited(_confirmRecovery()) : null,
          icon: const Icon(Icons.restart_alt), label: const Text('Восстановить вход')),
      ],
      if (_busy && status != null) const Padding(padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(minHeight: 2)),
      if (error != null) ...[
        const SizedBox(height: 10),
        Text(error, key: const Key('flow_account_error'), style: const TextStyle(color: PushokPalette.orange)),
        if (status == null) TextButton(onPressed: enabled ? () => unawaited(_read()) : null,
          child: const Text('Повторить')),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(key: const Key('open_pushok_account'),
        onPressed: _foreground ? widget.onOpenCabinet : null,
        icon: const Icon(Icons.open_in_new), label: const Text('Открыть кабинет MTProxy')),
      TextButton.icon(key: const Key('open_pushok_hub'),
        onPressed: _foreground ? widget.onOpenHub : null,
        icon: const Icon(Icons.hub_outlined),
        label: const Text('Pushok · ${FlowSubscriptions.hubUsername}')),
    ]));
  }
}
