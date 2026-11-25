import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import 'flow_connection_vitals.dart';

class DeviceTrafficPage extends StatefulWidget {
  const DeviceTrafficPage({super.key});

  @override
  State<DeviceTrafficPage> createState() => _DeviceTrafficPageState();
}

class _DeviceTrafficPageState extends State<DeviceTrafficPage> with WidgetsBindingObserver {
  static const channel = MethodChannel('shop.pushok.flow/device_traffic');
  late Future<Map<String, dynamic>?> reading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reading = channel.invokeMapMethod<String, dynamic>('read');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void refresh() => setState(() {
    reading = channel.invokeMapMethod<String, dynamic>('read');
  });

  Future<void> openSettings() async {
    bool opened = false;
    try {
      opened = await channel.invokeMethod<bool>('settings') ?? false;
    } on PlatformException {
      opened = false;
    } on MissingPluginException {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(
        'В настройках Android откройте «Специальный доступ» → «Доступ к статистике использования» → Pushok Flow.')));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>?>(
    future: reading,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final data = snapshot.data;
      final addresses = (data?['addresses'] as List?) ?? const [];
      final apps = (data?['apps'] as List?) ?? const [];
      final sources = (data?['sources'] as List?) ?? const [];
      final status = data?['status'];
      return ListView.builder(
        itemCount: 1 + apps.length,
        itemBuilder: (context, index) {
          if (index > 0) {
            final row = apps[index - 1] as Map;
            return ListTile(
              title: Text(row['label'] as String),
              subtitle: Text('Получено ${FlowConnectionVitals.formatBytes(row['received'] as int)}'
                '  ·  Отправлено ${FlowConnectionVitals.formatBytes(row['sent'] as int)}'),
            );
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PushokPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('IP-адреса телефона', style: TextStyle(fontWeight: FontWeight.bold))),
                IconButton(onPressed: refresh, tooltip: 'Обновить', icon: const Icon(Icons.refresh)),
              ]),
              if (addresses.isEmpty) const Text('Адреса сетевых интерфейсов недоступны.'),
              for (final row in addresses) SelectableText('${row['network']} · ${row['ip']}'),
            ])),
            const SizedBox(height: 16),
            Text('Трафик приложений за 24 часа', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('Расход телефона с учётом прямых подключений. Данные остаются на устройстве.'),
            const SizedBox(height: 8),
            if (status == 'permission') ...[
              const Text('Разрешите Pushok Flow читать статистику использования в настройках Android.'),
              Align(alignment: Alignment.centerLeft, child: TextButton(
                onPressed: openSettings, child: const Text('Открыть доступ'))),
            ] else if (status == 'ready') ...[
              Text('Учтённые сети · ${sources.join(' и ')}'),
              if (apps.isEmpty) const Text('Android пока не зарегистрировал расход за этот период.'),
            ] else const Text('Статистика Android сейчас недоступна. Попробуйте обновить.'),
          ]);
        },
      );
    },
  );
}
