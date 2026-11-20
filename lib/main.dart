import 'package:flutter/material.dart';
import 'design/pushok_theme.dart';
import 'dart:io' show Platform;
import 'dart:async' show Timer;
import 'platform/android_app_routes.dart';
import 'ai/pushok_ai.dart';
import 'ai/pushok_ai_memory.dart';
import 'platform/wireguard_tunnel.dart';

void main() => runApp(const PushokFlowApp());

class PushokFlowApp extends StatelessWidget {
  const PushokFlowApp({super.key});
  static const bg = PushokPalette.background;
  static const panel = PushokPalette.surface;
  static const teal = PushokPalette.teal;
  static const secondary = PushokPalette.muted;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pushok Flow', debugShowCheckedModeBanner: false,
        theme: buildPushokTheme(),
        home: const FlowHome(),
      );
}

class FlowHome extends StatefulWidget {
  const FlowHome({super.key});
  @override
  State<FlowHome> createState() => _FlowHomeState();
}

class _FlowHomeState extends State<FlowHome> {
  int tab = 0;
  List<InstalledApp> installed = [];
  Set<String> bypassPackages = {};
  bool loadingApps = false;
  String? routeError;
  bool savedProfile = false;
  String? lastErrorCode;
  int uptimeSeconds = 0;
  Timer? _healthPoll;
  bool connected = false;
  bool connecting = false;
  bool showWireGuardSecrets = false;
  Map<String, int> feedback = {};
  String? feedbackMessage;
  final wireGuardConfig = TextEditingController();

  Future<void> _toggleTunnel() async {
    if (!Platform.isAndroid || connecting) return;
    setState(() { connecting = true; routeError = null; });
    try {
      if (connected) {
        await WireGuardTunnel.disconnect();
        if (mounted) setState(() => connected = false);
      } else {
        final ok = await WireGuardTunnel.connect(wireGuardConfig.text);
        if (mounted) setState(() => connected = ok);
      }
    } catch (_) {
      if (mounted) setState(() => routeError = 'Не удалось подключиться. Проверьте WireGuard-профиль и разрешение VPN.');
    } finally {
      if (mounted) setState(() => connecting = false);
      await _refreshProfileStatus();
    }
  }

  @override
  void dispose() {
    _healthPoll?.cancel();
    wireGuardConfig.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadRoutes();
    _refreshProfileStatus();
    _loadAiFeedback();
    _healthPoll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (connected && !connecting && mounted) _refreshProfileStatus();
    });
    if (Platform.isAndroid) WireGuardTunnel.connected.then((value) { if (mounted) setState(() => connected = value); }).catchError((_) {});
  }

  Future<void> _loadAiFeedback() async {
    if (!Platform.isAndroid) return;
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
    } catch (_) { if (mounted) setState(() => feedbackMessage = 'Не удалось очистить память.'; }
  }

  Future<void> _refreshProfileStatus() async {
    if (!Platform.isAndroid) return;
    try {
      final exists = await WireGuardTunnel.savedProfileExists;
      final info = await WireGuardTunnel.diagnostics();
      if (mounted) setState(() {
        savedProfile = exists;
        lastErrorCode = info['lastErrorCode'] as String?;
        uptimeSeconds = (info['uptimeSeconds'] as num?)?.toInt() ?? 0;
      });
    } catch (_) { // No secrets in UI diagnostics.
    }
  }

  Future<void> _saveProfile() async {
    try {
      await WireGuardTunnel.saveProfile(wireGuardConfig.text);
      await _refreshProfileStatus();
      if (mounted) setState(() => routeError = null);
    } catch (_) {
      if (mounted) setState(() => routeError = 'Не удалось сохранить профиль. Проверьте конфигурацию.');
    }
  }

  Future<void> _restoreProfile() async {
    try {
      final value = await WireGuardTunnel.loadProfile();
      if (value != null) wireGuardConfig.text = value;
    } catch (_) {
      if (mounted) setState(() => routeError = 'Не удалось открыть защищённый профиль.');
    }
  }

  Future<void> _deleteProfile() async {
    try {
      await WireGuardTunnel.deleteProfile();
      wireGuardConfig.clear();
      await _refreshProfileStatus();
    } catch (_) {
      if (mounted) setState(() => routeError = 'Не удалось удалить профиль.');
    }
  }

  Future<void> _loadRoutes() async {
    if (!Platform.isAndroid) return;
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
    final updated = {...bypassPackages};
    if (value) { updated.add(packageName); } else { updated.remove(packageName); }
    try {
      await AndroidAppRoutes.setBypass(updated);
      if (mounted) setState(() { bypassPackages = updated; routeError = null; });
    } catch (_) {
      if (mounted) setState(() => routeError = 'Не удалось сохранить исключение. Отключите туннель и попробуйте ещё раз.');
    }
  }


  Widget card(Widget child) => PushokPanel(child: child);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Pushok Flow', style: const TextStyle(fontWeight: FontWeight.w700)), actions: [IconButton(icon: const Icon(Icons.info_outline), tooltip: 'Информация', onPressed: () => showAboutDialog(context: context, applicationName: 'Pushok Flow', applicationVersion: '0.21.0'))]),
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
        onTap: connecting || !Platform.isAndroid ? null : _toggleTunnel,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(connected ? Icons.check_circle_outline : Icons.power_settings_new,
            color: connected ? PushokPalette.mint : PushokPalette.glowCyan, size: 54),
          const SizedBox(height: 10),
          Text(connecting ? 'Подключение' : connected ? 'Отключить' : 'Подключить',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.w800, fontSize: 20)),
          if (!connected && !connecting) const Text('трафик',
            style: TextStyle(color: PushokPalette.muted, fontSize: 13)),
        ]),
      )),
    )),
    const SizedBox(height: 18),
    Center(child: PushokStatusChip(
      label: connecting ? 'Соединение устанавливается' : connected ? 'Трафик подключён' : 'Статус: отключено',
      icon: connecting ? Icons.sync : connected ? Icons.verified_user_outlined : Icons.circle,
      color: connecting ? PushokPalette.glowCyan : connected ? PushokPalette.mint : PushokPalette.orange)),
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
    ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: const Text('Профиль WireGuard', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: const Text('Защищённое хранение конфигурации',
        style: TextStyle(color: PushokPalette.muted, fontSize: 12)),
      children: [
        TextField(controller: wireGuardConfig,
          obscureText: !showWireGuardSecrets,
          maxLines: showWireGuardSecrets ? 4 : 1,
          enableInteractiveSelection: showWireGuardSecrets,
          autocorrect: false, enableSuggestions: false,
          decoration: InputDecoration(labelText: 'Конфигурация WireGuard',
            suffixIcon: IconButton(tooltip: showWireGuardSecrets ? 'Скрыть ключ' : 'Показать конфигурацию',
              icon: Icon(showWireGuardSecrets ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => showWireGuardSecrets = !showWireGuardSecrets)))),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: Platform.isAndroid ? _saveProfile : null,
            icon: const Icon(Icons.save_outlined), label: const Text('Сохранить')),
          OutlinedButton.icon(onPressed: Platform.isAndroid && savedProfile ? _restoreProfile : null,
            icon: const Icon(Icons.folder_open_outlined), label: const Text('Открыть')),
          OutlinedButton.icon(onPressed: Platform.isAndroid && savedProfile ? _deleteProfile : null,
            icon: const Icon(Icons.delete_outline), label: const Text('Удалить')),
        ]),
      ],
    ),
    if (lastErrorCode != null) Padding(padding: const EdgeInsets.all(8),
      child: Text('Pushok ИИ · код диагностики: $lastErrorCode',
        style: const TextStyle(color: PushokPalette.muted))),
    if (routeError != null) Padding(padding: const EdgeInsets.all(8),
      child: Text(routeError!, style: const TextStyle(color: PushokPalette.orange))),
  ]));

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
    card(Text(PushokAi.routingAdvice(isAndroid: Platform.isAndroid, excluded: bypassPackages.length))),
    if (loadingApps) const Center(child: CircularProgressIndicator()),
    if (routeError != null) Padding(padding: const EdgeInsets.all(12), child: Text(routeError!, style: const TextStyle(color: Colors.orangeAccent))),
    if (Platform.isAndroid && !loadingApps) ...installed.map((app) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: card(SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero, title: Text(app.label), subtitle: Text(app.packageName),
        value: bypassPackages.contains(app.packageName),
        onChanged: (v) => _setBypass(app.packageName, v),
      )),
    )),
    if (!Platform.isAndroid) card(const Text('iOS: исключение приложений в обычном VPN недоступно.')),
  ]);
  Widget servers() => card(const Column(mainAxisSize: MainAxisSize.min, children: [
    ListTile(leading: Icon(Icons.lock_outline), title: Text('WireGuard'), subtitle: Text('Android: библиотека GoBackend')), 
    ListTile(leading: Icon(Icons.layers_outlined), title: Text('VLESS и другие'), subtitle: Text('Следующие этапы')),
  ]));
  Widget assistant() => ListView(children: [
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ListTile(leading: Icon(Icons.smart_toy_outlined, color: PushokFlowApp.teal),
        title: Text('Pushok ИИ'), subtitle: Text('Локальная память результатов')),
      const Text('Оцените последнее подключение. Сохраняются только счётчики результатов; IP, сайты, конфигурации и ключи не собираются.',
        style: TextStyle(color: PushokFlowApp.secondary)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: Platform.isAndroid ? () => _rateConnection(true) : null,
          icon: const Icon(Icons.thumb_up_alt_outlined), label: const Text('Помогло')),
        OutlinedButton.icon(onPressed: Platform.isAndroid ? () => _rateConnection(false) : null,
          icon: const Icon(Icons.thumb_down_alt_outlined), label: const Text('Не помогло')),
      ]),
      const SizedBox(height: 12),
      Text('Положительных оценок: ${feedback['connection_helpful'] ?? 0}'),
      Text('Отрицательных оценок: ${feedback['connection_unhelpful'] ?? 0}'),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: Platform.isAndroid ? _clearAiFeedback : null,
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
      subtitle: Text('0.21.0 · тестовая версия; аудит библиотек через GitHub Actions'))),
  ]);
}