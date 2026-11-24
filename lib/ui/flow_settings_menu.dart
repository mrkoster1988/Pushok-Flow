import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';

/// One visible Home and an intentionally flat Settings directory.
class FlowSettingsMenu extends StatelessWidget {
  const FlowSettingsMenu({super.key, required this.onSelect});

  /// 1 Routes, 2 Servers, 3 Pushok ИИ, 4 Account, 5 Help.
  final ValueChanged<int> onSelect;

  Widget _entry(String keyName, String title, String caption,
      IconData icon, int section) => PushokPanel(
    child: ListTile(
      key: ValueKey(keyName),
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      leading: Icon(icon, color: PushokPalette.glowCyan, size: 26),
      title: Text(title, style: const TextStyle(fontSize: 16,
        fontWeight: FontWeight.w700)),
      subtitle: Text(caption, style: const TextStyle(
        color: PushokPalette.muted, fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, color: PushokPalette.muted),
      onTap: () => onSelect(section),
    ),
  );

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('flow_settings_menu'),
    children: [
      const Padding(padding: EdgeInsets.fromLTRB(4, 4, 4, 13),
        child: Text('На главной осталось только подключение. '
          'Все остальные функции доступны здесь.',
          style: TextStyle(color: PushokPalette.muted, fontSize: 13))),
      _entry('settings_help','Справка',
        'Как начать, управление доступом и диагностика', Icons.help_outline,5),
      const SizedBox(height: 9),
      _entry('settings_routes','Маршруты',
        'Прямой трафик приложений и исключения',Icons.alt_route_outlined,1),
      const SizedBox(height: 9),
      _entry('settings_servers','Серверы и подписки',
        'Профили, QR, импорт и выбор сервера',Icons.dns_outlined,2),
      const SizedBox(height: 9),
      _entry('settings_profile','Аккаунт и обновления',
        'MTProxy, баланс и новая версия Flow',Icons.person_outline,4),
      const SizedBox(height: 9),
      _entry('settings_assistant','Pushok ИИ',
        'Оценка связи и локальная память',Icons.auto_awesome_outlined,3),
    ],
  );
}

/// Help comes first in Settings. Do not claim an RTT when only a WireGuard
/// handshake timestamp is available in the native diagnostics.
class FlowHelpPage extends StatelessWidget {
  const FlowHelpPage({super.key, this.onDiagnostics});
  final VoidCallback? onDiagnostics;

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('flow_help_screen'),
    children: [
      PushokPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Как подключиться',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          const Text('1. На главной нажмите «Войти через Telegram». '
            'Подтвердите код в MTProxy.'),
          const SizedBox(height: 8),
          const Text('2. Нажмите «Получить конфиг». '
            'Shop выдаст личное подключение, когда оно будет готово.'),
          const SizedBox(height: 8),
          const Text('3. Нажмите «Подключить» и подтвердите '
            'системное разрешение Android.'),
          const SizedBox(height: 12),
          const Text('Ручные профили, QR и подписки перенесены в '
            '«Настройки → Серверы и подписки», прямой трафик — в «Маршруты».',
            style: TextStyle(color: PushokPalette.muted)),
        ],
      )),
      const SizedBox(height: 11),
      PushokPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Показатели и диагностика',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 9),
          const Text('Пинг на главной не показывается числом, пока '
            'его реально не измерили. Возраст последнего '
            'WireGuard-рукопожатия — не пинг. Срок доступа относится '
            'только к выбранному профилю.',
            style: TextStyle(color: PushokPalette.muted)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('open_diagnostics_from_help'),
            onPressed: onDiagnostics,
            icon: const Icon(Icons.info_outline),
            label: const Text('Открыть диагностику'),
          ),
        ],
      )),
    ],
  );
}
