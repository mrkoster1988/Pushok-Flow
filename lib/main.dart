import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'design/pushok_theme.dart';
import 'dart:io' show Platform;
import 'dart:async' show Timer, unawaited;
import 'platform/android_app_routes.dart';
import 'ai/pushok_ai.dart';
import 'ai/pushok_ai_memory.dart';
import 'platform/wireguard_tunnel.dart';
import 'platform/profile_privacy.dart';
import 'platform/tunnel_diagnostics.dart';
import 'ui/wireguard_profile_editor.dart';
import 'ui/app_updates_card.dart';
import 'ui/tunnel_diagnostics_card.dart';

void main() => runApp(const PushokFlowApp());

class PushokFlowApp extends StatelessWidget {
  const PushokFlowApp({super.key, this.isAndroid});
  // Tests exercise the real Android channel flow without requiring an emulator.
  final bool? isAndroid;
  static const bg = PushokPalette.background;
  static const panel = PushokPalette.surface;
  static const teal = PushokPalette.teal;
  static const secondary = PushokPalette.muted;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pushok Flow', debugShowCheckedModeBanner: false,
        theme: buildPushokTheme(),
        home: FlowHome(isAndroid: isAndroid),
      );
}

class FlowHome extends StatefulWidget {
  const FlowHome({super.key, this.isAndroid});
  final bool? isAndroid;
  @override
  State<FlowHome> createState() => _FlowHomeState();
}

class _FlowHomeState extends State<FlowHome> with WidgetsBindingObserver {
  int tab = 0;
  List<InstalledApp> installed = [];
  Set<String> bypassPackages = {};
  bool loadingApps = false;
  String? routeError;
  String? connectionError;
  bool savedProfile = false;
  String? lastErrorCode;
  TunnelDiagnostics _diagnostics = const TunnelDiagnostics.unavailable();
  bool _diagnosticsStale = true;
  Timer? _healthPoll;
  bool connected = false;
  bool connecting = false;
  bool _profileBusy = false;
  bool _profileEditorOpen = false;
  bool _statusRefreshing = false;
  bool _savingRoute = false;
  int _statusEpoch = 0;
  int _profileRequestEpoch = 0;
  bool _foreground = true;
  Map<String, int> feedback = {};
  String? feedbackMessage;
  bool get _isAndroid => widget.isAndroid ?? Platform.isAndroid;
  bool get _nativeBusy => _diagnostics.isKnown &&
      _diagnostics.transitioning && !_diagnosticsStale;
  bool get _tunnelConfirmed => connected && _diagnostics.isKnown &&
      !_diagnosticsStale && !_nativeBusy && !connecting;

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), showCloseIcon: true));
  }

  String _connectionMessage(Object error, {bool disconnecting = false}) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'VPN_DENIED':
          return 'Разрешение VPN отклонено. Нажмите «Подключить» и разрешите VPN.';
        case 'VPN_REQUEST_INTERRUPTED':
          return 'Запрос разрешения VPN прерван. Повторите подключение.';
        case 'VPN_BUSY':
          return 'Подключение уже изменяется. Дождитесь завершения.';
        case 'INVALID_CONFIG':
          return 'Профиль WireGuard некорректен. Откройте его настройки и проверьте данные.';
        case 'PROFILE_LOAD_FAILED':
          return 'Не удалось открыть сохранённый профиль. Вставьте конфигурацию заново.';
        case 'WG_DISCONNECT_FAILED':
          return 'Не удалось отключить VPN. Повторите попытку.';
      }
    }
    return disconnecting
        ? 'Не удалось отключить VPN. Повторите попытку.'
        : 'Не удалось установить WireGuard-туннель. Проверьте профиль и доступность сервера.';
  }

  Future<void> _toggleTunnel({String? profile}) async {
    if (!_isAndroid || !_foreground || connecting || _nativeBusy || _profileBusy || _profileEditorOpen) return;
    final disconnecting = connected;
    final requestEpoch = _profileRequestEpoch;
    var needsProfile = false;
    _statusEpoch++;
    setState(() {
      connecting = true;
      connectionError = null;
      _diagnosticsStale = true;
    });
    try {
      if (disconnecting) {
        await WireGuardTunnel.disconnect();
        if (mounted) setState(() {
          connected = false;
          _diagnostics = const TunnelDiagnostics(isKnown: true, connected: false,
              statistics: TunnelStatistics.inactive());
        });
      } else {
        // Read the protected profile only after the user's Connect action.
        final config = profile ?? await WireGuardTunnel.loadProfile();
        if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
        if (config == null || config.trim().isEmpty) {
          needsProfile = true;
          setState(() => savedProfile = false);
        } else {
          final ok = await WireGuardTunnel.connect(config);
          if (!mounted) return;
          setState(() {
            connected = ok;
            savedProfile = true;
            _diagnostics = TunnelDiagnostics(isKnown: true, connected: ok);
          });
          if (!ok) {
            final message = _connectionMessage(StateError('not connected'));
            setState(() => connectionError = message);
            _showNotice(message);
          }
        }
      }
    } catch (error) {
      if (mounted) {
        final message = _connectionMessage(error, disconnecting: disconnecting);
        setState(() => connectionError = message);
        _showNotice(message);
      }
    } finally {
      if (mounted) {
        setState(() => connecting = false);
        await _refreshProfileStatus();
      }
    }
    if (needsProfile && mounted && _foreground && requestEpoch == _profileRequestEpoch) {
      await _editProfile(connectAfterSave: true, initialConfig: '');
    }
  }

  @override
  void dispose() {
    _healthPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _loadRoutes();
    _refreshProfileStatus();
    _loadAiFeedback();
    _startHealthPolling();
  }

  void _startHealthPolling() {
    _healthPoll?.cancel();
    if (!_isAndroid || !_foreground) return;
    _healthPoll = Timer.periodic(const Duration(seconds: 10), (_) {
      if ((connected || _nativeBusy || !_diagnostics.isKnown) &&
          !connecting && mounted && _foreground) _refreshProfileStatus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _startHealthPolling();
      _refreshProfileStatus();
    } else {
      // A request made before losing focus must not open the editor later,
      // even if the user returns before a native response arrives.
      _profileRequestEpoch++;
      // A sample requested before app switching is no longer a fresh reading.
      _statusEpoch++;
      setState(() => _diagnosticsStale = true);
      _healthPoll?.cancel();
    }
  }

  Future<void> _loadAiFeedback() async {
    if (!_isAndroid) return;
    try {
      final data = await PushokAiMemory.summary();
      if (mounted) setState(() => feedback = data);
    } catch (_) { if (mounted) setState(() => feedbackMessage = 'Память недоступна на этом устройстве.'); }
  }

  Future<void> _rateConnection(bool helpful) async {
    try {
      final data = await PushokAiMemory.record(category: 'connection', helpful: helpful);
      if (mounted) setState(() { feedback = data; feedbackMessage = 'Ответ сохранён только на устройстве.'; });
    } catch (_) { if (mounted) setState(() => feedbackMessage = 'Не удалось сохранить оценку.'); }
  }

  Future<void> _clearAiFeedback() async {
    try {
      await PushokAiMemory.clear();
      if (mounted) setState(() { feedback = {}; feedbackMessage = 'Локальная память очищена.'; });
    } catch (_) {
      if (mounted) setState(() => feedbackMessage = 'Не удалось очистить память.');
    }
  }

  Future<void> _refreshProfileStatus() async {
    if (!_isAndroid || !mounted || !_foreground || connecting || _statusRefreshing) return;
    setState(() => _statusRefreshing = true);
    final epoch = _statusEpoch;
    try {
      try {
        final exists = await WireGuardTunnel.savedProfileExists
            .timeout(const Duration(seconds: 5));
        if (mounted && _foreground && epoch == _statusEpoch) {
          setState(() => savedProfile = exists);
        }
      } catch (_) { // A profile-store error must not prevent status refresh.
      }
      if (!mounted || !_foreground || epoch != _statusEpoch) return;
      try {
        final info = await WireGuardTunnel.diagnostics()
            .timeout(const Duration(seconds: 5));
        if (mounted && _foreground && epoch == _statusEpoch) setState(() {
          _diagnostics = info;
          _diagnosticsStale = !info.isKnown;
          if (info.isKnown) {
            connected = info.connected;
          } else if (info.connected) {
            // Retain an explicit last-known UP state for the Disconnect action.
            // An unknown read must never claim a successful disconnect.
            connected = true;
          }
          lastErrorCode = info.lastErrorCode;
        });
      } catch (_) {
        if (mounted && _foreground && epoch == _statusEpoch) setState(() {
          _diagnostics = TunnelDiagnostics.unavailable(connected: connected);
          _diagnosticsStale = true;
          lastErrorCode = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _statusRefreshing = false);
        // Coalesce a resume/connect refresh behind an older in-flight sample.
        if (_foreground && !connecting && epoch != _statusEpoch) {
          unawaited(_refreshProfileStatus());
        }
      }
    }
  }

  Future<void> _editProfile({bool connectAfterSave = false, String? initialConfig}) async {
    if (!_isAndroid || !_foreground || connecting || _nativeBusy || connected || _profileBusy || _profileEditorOpen) return;
    setState(() => _profileBusy = true);
    final requestEpoch = _profileRequestEpoch;
    ProfilePrivacy? protection;
    String? saved;
    int? saveIntentEpoch;
    try {
      try {
        protection = await ProfilePrivacy.acquire();
      } catch (_) {
        // Never expose platform messages/details or open an unprotected editor.
        if (mounted && _foreground && requestEpoch == _profileRequestEpoch) {
          _showNotice('Не удалось защитить экран профиля. Закройте и снова откройте приложение.');
        }
        return;
      }
      if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
      var draft = initialConfig ?? '';
      String? initialError;
      try {
        if (initialConfig == null) draft = await WireGuardTunnel.loadProfile() ?? '';
      } catch (error) {
        initialError = _connectionMessage(error);
      }
      if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
      if (connected || connecting || _nativeBusy) {
        _showNotice('Для изменения профиля отключите VPN.');
        return;
      }
      setState(() { _profileBusy = false; _profileEditorOpen = true; });
      final navigator = Navigator.of(context);
      final localizations = MaterialLocalizations.of(context);
      final route = ModalBottomSheetRoute<String>(
        capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
        settings: const RouteSettings(name: 'wireguard-profile'),
        barrierLabel: localizations.scrimLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
        isScrollControlled: true,
        useSafeArea: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: PushokPalette.midnight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: PushokPalette.glowCyan),
        ),
        builder: (context) => WireGuardProfileEditor(
          initialConfig: draft,
          initialError: initialError,
          connectAfterSave: connectAfterSave,
          onImport: WireGuardTunnel.importProfile,
          onCancelImport: WireGuardTunnel.cancelProfileImport,
          onSave: (config) async {
            if (!mounted || !_foreground) {
              throw PlatformException(code: 'PROFILE_SAVE_INTERRUPTED');
            }
            // Choosing a file leaves the app temporarily. A new explicit Save
            // after returning authorizes connect-after-save for that foreground
            // session, while later app switching still invalidates the intent.
            saveIntentEpoch = _profileRequestEpoch;
            await WireGuardTunnel.saveProfile(config);
            if (mounted) {
              _statusEpoch++;
              setState(() { savedProfile = true; connectionError = null; });
            }
          },
        ),
      );
      // Route.completed also resolves when the Navigator is disposed. Unlike
      // push()/popped, it waits until the closing animation and overlay are gone.
      // Do not disable protection while the last frame of the key is visible.
      unawaited(navigator.push<String>(route));
      saved = await route.completed;
      // Also submit a frame without the editor before unprotecting the window
      // when the Navigator was removed without a closing animation.
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (protection != null) {
        try {
          await protection.release();
        } catch (_) {
          // Fail closed: native protection stays enabled if cleanup cannot finish.
          if (mounted && _foreground) {
            _showNotice('Защита экрана осталась включённой. Для снимков других экранов перезапустите приложение.');
          }
        }
      }
      if (mounted) setState(() { _profileBusy = false; _profileEditorOpen = false; });
    }
    if (!mounted || saved == null) return;
    if (connectAfterSave) {
      // A slow save must not start VPN permission UI after app switching.
      if (!_foreground || saveIntentEpoch != _profileRequestEpoch) {
        if (_foreground) _showNotice('Профиль сохранён. Нажмите «Подключить», когда будете готовы.');
        return;
      }
      await _toggleTunnel(profile: saved);
    } else {
      _showNotice('Профиль сохранён на устройстве. Можно подключаться.');
    }
  }

  Future<void> _deleteProfile() async {
    if (!_isAndroid || connected || connecting || _nativeBusy || _profileBusy || _profileEditorOpen) return;
    _statusEpoch++;
    setState(() => _profileBusy = true);
    try {
      await WireGuardTunnel.deleteProfile();
      if (mounted) {
        _statusEpoch++;
        setState(() { savedProfile = false; connectionError = null; });
        _showNotice('Сохранённый профиль удалён.');
      }
    } catch (_) {
      _showNotice('Не удалось удалить профиль. Повторите попытку.');
    } finally {
      if (mounted) setState(() => _profileBusy = false);
    }
  }

  Future<void> _loadRoutes() async {
    if (!_isAndroid) return;
    setState(() { loadingApps = true; routeError = null; });
    try {
      final apps = await AndroidAppRoutes.installedApps();
      final selected = await AndroidAppRoutes.getBypass();
      if (mounted) setState(() { installed = apps; bypassPackages = selected; });
    } catch (_) {
      if (mounted) setState(() { routeError = 'Список приложений недоступен. Проверьте Android-модуль.'; });
    } finally {
      if (mounted) setState(() => loadingApps = false);
    }
  }

  Future<void> _setBypass(String packageName, bool value) async {
    if (connected || connecting || _nativeBusy || _savingRoute) return;
    final updated = {...bypassPackages};
    if (value) { updated.add(packageName); } else { updated.remove(packageName); }
    setState(() => _savingRoute = true);
    try {
      await AndroidAppRoutes.setBypass(updated);
      if (mounted) setState(() { bypassPackages = updated; routeError = null; });
    } catch (_) {
      if (mounted) setState(() => routeError = 'Не удалось сохранить исключение. Отключите туннель и попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _savingRoute = false);
    }
  }


  Widget card(Widget child) => PushokPanel(child: child);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Pushok Flow', style: const TextStyle(fontWeight: FontWeight.w700)), actions: [IconButton(icon: const Icon(Icons.info_outline), tooltip: 'Информация', onPressed: () => showAboutDialog(context: context, applicationName: 'Pushok Flow', applicationVersion: '0.27.0'))]),
      body: PushokNeonBackdrop(child: SafeArea(child: Padding(
        padding: const EdgeInsets.all(14),
        child: [home(), routes(), servers(), assistant(), profile()][tab],
      ))),
      bottomNavigationBar: NavigationBar(
        backgroundColor: PushokFlowApp.bg,
        indicatorColor: PushokFlowApp.panel,
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Главная'),
          NavigationDestination(icon: Icon(Icons.alt_route_outlined), label: 'Маршруты'),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Серверы'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Pushok ИИ'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Профиль'),
        ],
      ),
    );
  }

  Widget home() => LayoutBuilder(builder: (context, constraints) => ListView(children: [
    const SizedBox(height: 6),
    // Маскот — оригинальное изображение, предоставленное владельцем бренда.
    Center(child: Column(children: [
      Image.asset('assets/mascot/pushok.png', height: constraints.maxHeight < 540 ? 126 : 160,
        fit: BoxFit.contain, semanticLabel: 'Фирменный рыжий котёнок Pushok'),
      const SizedBox(height: 2),
      const Text('Твой интернет. Твои правила.', textAlign: TextAlign.center,
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
    ])),
    const SizedBox(height: 18),
    Center(child: AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      width: constraints.maxWidth < 340 ? 176 : 202,
      height: constraints.maxWidth < 340 ? 176 : 202,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(shape: BoxShape.circle,
        gradient: LinearGradient(colors: _tunnelConfirmed
          ? [PushokPalette.mint, PushokPalette.glowCyan]
          : [PushokPalette.glowCyan, PushokPalette.electricBlue, PushokPalette.glowViolet]),
        boxShadow: [BoxShadow(color: (_tunnelConfirmed ? PushokPalette.mint : PushokPalette.glowCyan)
          .withValues(alpha: .45), blurRadius: 30, spreadRadius: 3)]),
      child: Material(color: PushokPalette.midnight, shape: const CircleBorder(), child: InkWell(
        key: const Key('pushok_connect_button'),
        customBorder: const CircleBorder(),
        onTap: connecting || _nativeBusy || _profileBusy || _profileEditorOpen || !_isAndroid
            ? null : () => _toggleTunnel(),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(_tunnelConfirmed ? Icons.check_circle_outline
              : connected ? Icons.info_outline : Icons.power_settings_new,
            color: _tunnelConfirmed ? PushokPalette.mint : PushokPalette.glowCyan, size: 54),
          const SizedBox(height: 10),
          Text(connecting ? (connected ? 'Отключение' : 'Подключение') : connected ? 'Отключить' : 'Подключить',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.w800, fontSize: 20)),
          if (!connected && !connecting) const Text('трафик',
            style: TextStyle(color: PushokPalette.muted, fontSize: 13)),
        ]),
      )),
    )),
    const SizedBox(height: 18),
    Center(child: PushokStatusChip(
      label: connecting ? (connected ? 'Отключение туннеля' : 'Соединение устанавливается')
          : _nativeBusy ? 'Состояние изменяется'
          : _isAndroid && (_diagnosticsStale || !_diagnostics.isKnown)
              ? 'Статус уточняется'
              : connected ? 'Туннель включён' : 'Статус: отключено',
      icon: connecting || _nativeBusy ? Icons.sync
          : _diagnosticsStale ? Icons.info_outline
          : connected ? Icons.shield_outlined : Icons.circle,
      color: connecting || _nativeBusy ? PushokPalette.glowCyan
          : _diagnosticsStale ? PushokPalette.muted
          : connected ? PushokPalette.mint : PushokPalette.orange)),
    if (connectionError != null) Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(liveRegion: true, child: Text(connectionError!,
        key: const Key('connection_error'), textAlign: TextAlign.center,
        style: const TextStyle(color: PushokPalette.orange))),
    ),
    if (!connected && !connecting) Center(child: TextButton.icon(
      key: const Key('configure_wireguard_profile'),
      onPressed: !_isAndroid || _nativeBusy || _profileBusy || _profileEditorOpen ? null : () => _editProfile(),
      icon: Icon(savedProfile ? Icons.check_circle_outline : Icons.add_circle_outline, size: 18),
      label: Text(savedProfile ? 'Профиль сохранён · изменить' : 'Добавить профиль WireGuard'),
    )),
    if (_isAndroid) ...[
      const SizedBox(height: 14),
      TunnelDiagnosticsCard(
        diagnostics: _diagnostics,
        refreshing: _statusRefreshing,
        stale: _diagnosticsStale,
        onRefresh: connecting || _profileBusy || _profileEditorOpen || !_foreground
            ? null : _refreshProfileStatus,
      ),
    ],
    const SizedBox(height: 14),
    PushokPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.shield_outlined, color: PushokPalette.glowCyan),
        SizedBox(width: 10), Expanded(child: Text('Умный маршрут',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))]),
      const SizedBox(height: 7),
      Text('Приложений напрямую: ${bypassPackages.length}. Изменения действуют при следующем подключении.',
        style: const TextStyle(color: PushokPalette.muted, fontSize: 13)),
      Align(alignment: Alignment.centerRight,
        child: TextButton.icon(onPressed: () => setState(() => tab = 1),
          icon: const Icon(Icons.arrow_forward_ios, size: 14), label: const Text('Настроить'))),
    ])),
    const SizedBox(height: 12),
    _profileCard(),
    if (lastErrorCode != null) Padding(padding: const EdgeInsets.all(8),
      child: Text('Pushok ИИ · код диагностики: $lastErrorCode',
        style: const TextStyle(color: PushokPalette.muted))),
  ]));

  Widget _profileCard() => PushokPanel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Row(children: [
        Icon(Icons.lock_outline, color: PushokPalette.glowCyan),
        SizedBox(width: 10),
        Expanded(child: Text('Профиль WireGuard', style: TextStyle(fontWeight: FontWeight.w700))),
      ]),
      const SizedBox(height: 8),
      Text(_profileBusy ? 'Открываем защищённый профиль…'
          : savedProfile ? 'Профиль сохранён на устройстве и готов к подключению.'
          : 'Вставьте конфигурацию от вашего VPN-провайдера. Ключ хранится только на устройстве.',
        style: const TextStyle(color: PushokPalette.muted, fontSize: 13)),
      if (connected) const Padding(padding: EdgeInsets.only(top: 8),
        child: Text('Для изменения профиля отключите VPN.',
          style: TextStyle(color: PushokPalette.muted, fontSize: 12))),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const Key('edit_wireguard_profile'),
          onPressed: !_isAndroid || connected || connecting || _nativeBusy || _profileBusy || _profileEditorOpen
              ? null : () => _editProfile(),
          icon: const Icon(Icons.edit_outlined),
          label: Text(savedProfile ? 'Изменить профиль' : 'Добавить профиль')),
        if (savedProfile) OutlinedButton.icon(
          key: const Key('delete_wireguard_profile'),
          onPressed: !_isAndroid || connected || connecting || _nativeBusy || _profileBusy || _profileEditorOpen
              ? null : _deleteProfile,
          icon: const Icon(Icons.delete_outline), label: const Text('Удалить')),
      ]),
    ],
  ));

  Widget routes() => ListView(children: [
    card(const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Приложения без туннеля', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Настройки действуют при следующем подключении. Перед изменением исключений отключите туннель.',
        style: TextStyle(color: PushokFlowApp.secondary)),
    ])),
    const SizedBox(height: 12),
    card(Text(PushokAi.routingAdvice(isAndroid: _isAndroid, excluded: bypassPackages.length))),
    if (loadingApps) const Center(child: CircularProgressIndicator()),
    if (routeError != null) Padding(padding: const EdgeInsets.all(12), child: Text(routeError!, style: const TextStyle(color: Colors.orangeAccent))),
    if (_isAndroid && !loadingApps) ...installed.map((app) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: card(SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero, title: Text(app.label), subtitle: Text(app.packageName),
        value: bypassPackages.contains(app.packageName),
        onChanged: connected || connecting || _nativeBusy || _savingRoute ? null : (v) => _setBypass(app.packageName, v),
      )),
    )),
    if (!_isAndroid) card(const Text('iOS: исключение приложений в обычном VPN недоступно.')),
  ]);
  Widget servers() => ListView(children: [
    card(const ListTile(leading: Icon(Icons.lock_outline), title: Text('WireGuard'),
      subtitle: Text('Подключение к серверу из вашего профиля'))),
    const SizedBox(height: 12),
    _profileCard(),
    const SizedBox(height: 12),
    card(const ListTile(leading: Icon(Icons.layers_outlined), title: Text('VLESS и другие'),
      subtitle: Text('Следующие этапы'))),
  ]);
  Widget assistant() => ListView(children: [
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ListTile(leading: Icon(Icons.smart_toy_outlined, color: PushokFlowApp.teal),
        title: Text('Pushok ИИ'), subtitle: Text('Локальная память результатов')),
      const Text('Оцените последнее подключение. Сохраняются только счётчики результатов; IP, сайты, конфигурации и ключи не собираются.',
        style: TextStyle(color: PushokFlowApp.secondary)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: _isAndroid ? () => _rateConnection(true) : null,
          icon: const Icon(Icons.thumb_up_alt_outlined), label: const Text('Помогло')),
        OutlinedButton.icon(onPressed: _isAndroid ? () => _rateConnection(false) : null,
          icon: const Icon(Icons.thumb_down_alt_outlined), label: const Text('Не помогло')),
      ]),
      const SizedBox(height: 12),
      Text('Положительных оценок: ${feedback['connection_helpful'] ?? 0}'),
      Text('Отрицательных оценок: ${feedback['connection_unhelpful'] ?? 0}'),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _isAndroid ? _clearAiFeedback : null,
        icon: const Icon(Icons.delete_outline), label: const Text('Очистить память Pushok ИИ')),
      if (feedbackMessage != null) Text(feedbackMessage!, style: const TextStyle(color: PushokFlowApp.secondary)),
      const SizedBox(height: 12),
      const Text('Статистика WireGuard доступна на главной. Автоматическое обучение '
        'и проверка доступности сайтов — следующие этапы.',
        style: TextStyle(color: PushokFlowApp.secondary)),
    ])),
  ]);
  Widget profile() => ListView(children: [
    card(const ListTile(leading: Icon(Icons.person_outline), title: Text('Pushok ID'),
      subtitle: Text('Единая авторизация — в разработке'))),
    const SizedBox(height: 12),
    AppUpdatesCard(isAndroid: _isAndroid),
  ]);
}
