import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'design/pushok_theme.dart';
import 'dart:io' show Platform;
import 'dart:async' show Timer;
import 'platform/android_app_routes.dart';
import 'ai/pushok_ai.dart';
import 'ai/pushok_ai_memory.dart';
import 'platform/wireguard_tunnel.dart';
import 'ui/wireguard_profile_editor.dart';

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
  int uptimeSeconds = 0;
  Timer? _healthPoll;
  bool connected = false;
  bool connecting = false;
  bool _profileBusy = false;
  bool _profileEditorOpen = false;
  bool _statusRefreshing = false;
  bool _savingRoute = false;
  int _statusEpoch = 0;
  Map<String, int> feedback = {};
  String? feedbackMessage;
  bool get _isAndroid => widget.isAndroid ?? Platform.isAndroid;

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
    if (!_isAndroid || connecting || _profileBusy || _profileEditorOpen) return;
    final disconnecting = connected;
    var needsProfile = false;
    _statusEpoch++;
    setState(() { connecting = true; connectionError = null; });
    try {
      if (disconnecting) {
        await WireGuardTunnel.disconnect();
        if (mounted) setState(() { connected = false; uptimeSeconds = 0; });
      } else {
        // Read the protected profile only after the user's Connect action.
        final config = profile ?? await WireGuardTunnel.loadProfile();
        if (!mounted) return;
        if (config == null || config.trim().isEmpty) {
          needsProfile = true;
          setState(() => savedProfile = false);
        } else {
          final ok = await WireGuardTunnel.connect(config);
          if (!mounted) return;
          setState(() { connected = ok; savedProfile = true; });
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
    if (needsProfile && mounted) {
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
    WidgetsBinding.instance.addObserver(this);
    _loadRoutes();
    _refreshProfileStatus();
    _loadAiFeedback();
    _startHealthPolling();
  }

  void _startHealthPolling() {
    _healthPoll?.cancel();
    if (!_isAndroid) return;
    _healthPoll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (connected && !connecting && mounted) _refreshProfileStatus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startHealthPolling();
      _refreshProfileStatus();
    } else {
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
    if (!_isAndroid || !mounted || connecting || _statusRefreshing) return;
    _statusRefreshing = true;
    final epoch = _statusEpoch;
    try {
      try {
        final exists = await WireGuardTunnel.savedProfileExists;
        if (mounted && epoch == _statusEpoch) {
          setState(() => savedProfile = exists);
        }
      } catch (_) { // A profile-store error must not prevent status refresh.
      }
      if (!mounted) return;
      try {
        final info = await WireGuardTunnel.diagnostics();
        if (mounted && epoch == _statusEpoch) setState(() {
          connected = info['connected'] == true;
          lastErrorCode = info['lastErrorCode'] as String?;
          uptimeSeconds = (info['uptimeSeconds'] as num?)?.toInt() ?? 0;
        });
      } catch (_) { // No secrets in UI diagnostics.
      }
    } finally {
      _statusRefreshing = false;
    }
  }

  Future<void> _editProfile({bool connectAfterSave = false, String? initialConfig}) async {
    if (!_isAndroid || connecting || connected || _profileBusy || _profileEditorOpen) return;
    setState(() => _profileBusy = true);
    var draft = initialConfig ?? '';
    String? initialError;
    try {
      if (initialConfig == null) draft = await WireGuardTunnel.loadProfile() ?? '';
    } catch (error) {
      initialError = _connectionMessage(error);
    }
    if (!mounted) return;
    if (connected || connecting) {
      setState(() => _profileBusy = false);
      _showNotice('Для изменения профиля отключите VPN.');
      return;
    }
    setState(() { _profileBusy = false; _profileEditorOpen = true; });
    String? saved;
    try {
      saved = await showModalBottomSheet<String>(
        context: context,
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
          onSave: (config) async {
            await WireGuardTunnel.saveProfile(config);
            if (mounted) {
              _statusEpoch++;
              setState(() { savedProfile = true; connectionError = null; });
            }
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _profileEditorOpen = false);
    }
    if (!mounted || saved == null) return;
    if (connectAfterSave) {
      await _toggleTunnel(profile: saved);
    } else {
      _showNotice('Профиль сохранён на устройстве. Можно подключаться.');
    }
  }

  Future<void> _deleteProfile() async {
    if (!_isAndroid || connected || connecting || _profileBusy || _profileEditorOpen) return;
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
    if (connected || connecting || _savingRoute) return;
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
      appBar: AppBar(title: Text('Pushok Flow', style: const TextStyle(fontWeight: FontWeight.w700)), actions: [IconButton(icon: const Icon(Icons.info_outline), tooltip: 'Информация', onPressed: () => showAboutDialog(context: context, applicationName: 'Pushok Flow', applicationVersion: '0.22.0'))]),
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
        gradient: LinearGradient(colors: connected
          ? [PushokPalette.mint, PushokPalette.glowCyan]
          : [PushokPalette.glowCyan, PushokPalette.electricBlue, PushokPalette.glowViolet]),
        boxShadow: [BoxShadow(color: (connected ? PushokPalette.mint : PushokPalette.glowCyan)
          .withValues(alpha: .45), blurRadius: 30, spreadRadius: 3)]),
      child: Material(color: PushokPalette.midnight, shape: const CircleBorder(), child: InkWell(
        key: const Key('pushok_connect_button'),
        customBorder: const CircleBorder(),
        onTap: connecting || _profileBusy || _profileEditorOpen || !_isAndroid
            ? null : () => _toggleTunnel(),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(connected ? Icons.check_circle_outline : Icons.power_settings_new,
            color: connected ? PushokPalette.mint : PushokPalette.glowCyan, size: 54),
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
      label: connecting ? (connected ? 'Отключение VPN' : 'Соединение устанавливается') : connected ? 'Трафик подключён' : 'Статус: отключено',
      icon: connecting ? Icons.sync : connected ? Icons.verified_user_outlined : Icons.circle,
      color: connecting ? PushokPalette.glowCyan : connected ? PushokPalette.mint : PushokPalette.orange)),
    if (connectionError != null) Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(liveRegion: true, child: Text(connectionError!,
        key: const Key('connection_error'), textAlign: TextAlign.center,
        style: const TextStyle(color: PushokPalette.orange))),
    ),
    if (!connected && !connecting) Center(child: TextButton.icon(
      key: const Key('configure_wireguard_profile'),
      onPressed: !_isAndroid || _profileBusy || _profileEditorOpen ? null : () => _editProfile(),
      icon: Icon(savedProfile ? Icons.check_circle_outline : Icons.add_circle_outline, size: 18),
      label: Text(savedProfile ? 'Профиль сохранён · изменить' : 'Добавить профиль WireGuard'),
    )),
    if (connected && uptimeSeconds > 0) Center(child: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text('Время соединения: ${Duration(seconds: uptimeSeconds).inMinutes} мин ${uptimeSeconds % 60} сек',
        style: const TextStyle(color: PushokPalette.muted, fontSize: 12)))),
    const SizedBox(height: 18),
    Row(children: [
      Expanded(child: _homeShortcut(Icons.dns_outlined, 'Серверы', 2)),
      const SizedBox(width: 9),
      Expanded(child: _homeShortcut(Icons.alt_route_outlined, 'Маршруты', 1)),
      const SizedBox(width: 9),
      Expanded(child: _homeShortcut(Icons.auto_awesome_outlined, 'Pushok ИИ', 3)),
    ]),
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
          onPressed: !_isAndroid || connected || connecting || _profileBusy || _profileEditorOpen
              ? null : () => _editProfile(),
          icon: const Icon(Icons.edit_outlined),
          label: Text(savedProfile ? 'Изменить профиль' : 'Добавить профиль')),
        if (savedProfile) OutlinedButton.icon(
          key: const Key('delete_wireguard_profile'),
          onPressed: !_isAndroid || connected || connecting || _profileBusy || _profileEditorOpen
              ? null : _deleteProfile,
          icon: const Icon(Icons.delete_outline), label: const Text('Удалить')),
      ]),
    ],
  ));

  Widget _homeShortcut(IconData icon, String title, int destination) =>
    InkWell(onTap: () => setState(() => tab = destination),
      borderRadius: BorderRadius.circular(18),
      child: Container(height: 85,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF103858), Color(0xFF04162D)]),
          border: Border.all(color: PushokPalette.glowCyan.withValues(alpha: .55)),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: PushokPalette.electricBlue.withValues(alpha: .16), blurRadius: 12)]),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: PushokPalette.glowCyan, size: 27),
          const SizedBox(height: 5),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        ])));

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
        onChanged: connected || connecting || _savingRoute ? null : (v) => _setBypass(app.packageName, v),
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
      const Text('Автоматическое обучение, диагностика сети и рекомендации на основе результатов — следующие этапы.',
        style: TextStyle(color: PushokFlowApp.secondary)),
    ])),
  ]);
  Widget profile() => ListView(children: [
    card(const ListTile(leading: Icon(Icons.person_outline), title: Text('Pushok ID'),
      subtitle: Text('Единая авторизация — в разработке'))),
    const SizedBox(height: 12),
    card(const ListTile(leading: Icon(Icons.system_update_alt), title: Text('Версия и обновления'),
      subtitle: Text('0.22.0 · тестовая версия; аудит библиотек через GitHub Actions'))),
  ]);
}
