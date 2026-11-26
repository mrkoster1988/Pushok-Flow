import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class TunnelInternetCheck extends StatefulWidget {
  const TunnelInternetCheck({super.key});

  @override
  State<TunnelInternetCheck> createState() => _TunnelInternetCheckState();
}

class _TunnelInternetCheckState extends State<TunnelInternetCheck> {
  static const channel = MethodChannel('shop.pushok.flow/app_routes');
  bool checking = false;
  String? outcome;
  DateTime? measured;
  String? feedback;

  Future<void> check() async {
    setState(() { checking = true; outcome = null; feedback = null; });
    String? result;
    try {
      result = await channel.invokeMethod<String>('checkTunnelInternet')
          .timeout(const Duration(seconds: 18));
    } catch (_) { result = 'unknown'; }
    if (mounted) setState(() {
      checking = false;
      outcome = result;
      measured = DateTime.now();
    });
  }

  Future<void> share() async {
    final stamp = measured;
    if (stamp == null) return;
    try {
      await channel.invokeMethod<void>('openInternetCheckSupport', {
        'code': outcome, 'epoch': stamp.millisecondsSinceEpoch ~/ 1000,
      });
    } catch (_) {
      if (mounted) setState(() { feedback = 'Не удалось открыть поддержку. Попробуйте ещё раз.'; });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(onPressed: checking ? null : check,
        icon: const Icon(Icons.network_check),
        label: Text(checking ? 'Проверяем связь…' : 'Проверить интернет через туннель')),
      if (outcome != null) ExpansionTile(
        title: Text(switch (outcome) {
          'ok' => 'Сайт через VPN доступен',
          'dns' || 'https' => 'Сайт через VPN недоступен',
          _ => 'Маршрут через Flow не подтверждён',
        }),
        children: [ListTile(title: Text(switch (outcome) {
          'ok' => 'DNS и HTTPS · example.com ответил',
          'dns' => 'DNS · адрес не получен. HTTPS не проверялся.',
          'https' => 'DNS · адрес получен. HTTPS · проверка не прошла.',
          _ => 'Включите Flow и повторите проверку.',
        })), TextButton(onPressed: share, child: const Text('Обсудить результат с Пушком'))],
      ),
      if (feedback != null) Text(feedback!),
    ],
  );
}
