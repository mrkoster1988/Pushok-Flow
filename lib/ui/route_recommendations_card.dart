import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../models/moscow_time.dart';
import '../platform/route_recommendations.dart';

class RouteRecommendationsCard extends StatelessWidget {
  const RouteRecommendationsCard({
    super.key,
    required this.status,
    required this.loading,
    required this.refreshing,
    this.savingAutoUpdate = false,
    this.onRefresh,
    this.onAutoUpdateChanged,
  });

  final RecommendationStatus status;
  final bool loading;
  final bool refreshing;
  final bool savingAutoUpdate;
  final VoidCallback? onRefresh;
  final ValueChanged<bool>? onAutoUpdateChanged;

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Обновление рекомендаций'),
        scrollable: true,
        content: const Text(
          'Автообновление проверяет рекомендации при открытии «Маршрутов» '
          'или возвращении к этому экрану из другого приложения. '
          'После успешной проверки следующая возможна через сутки, '
          'после ошибки — через час. В закрытом приложении проверок нет.\n\n'
          'Кнопка «Обновить рекомендации» позволяет проверить список в любое время. '
          'Новый APK для обновления списка не нужен.\n\n'
          'Ваш выбор исключений, профили и активное подключение не меняются. '
          'Список приложений с телефона никуда не отправляется.',
        ),
        actions: [TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Понятно'),
        )],
      ),
    );
  }

  String _errorMessage(String code) {
    switch (code) {
      case 'RECOMMENDATIONS_NETWORK_ERROR':
        return 'Не удалось обновить рекомендации. Проверьте интернет и повторите попытку.';
      case 'RECOMMENDATIONS_STALE':
        return 'Сервис вернул прежние данные. Сохранённые рекомендации остаются доступны.';
      case 'RECOMMENDATIONS_STORAGE_ERROR':
        return 'Не удалось сохранить изменения. Попробуйте ещё раз.';
      case 'RECOMMENDATIONS_BUSY':
        return 'Рекомендации уже обновляются. Подождите немного.';
      case 'RECOMMENDATIONS_UNAVAILABLE':
        return 'Обновление рекомендаций недоступно в этой версии приложения.';
      case 'RECOMMENDATIONS_INTERRUPTED':
        return 'Проверка рекомендаций прервана. Повторите попытку.';
      default:
        return 'Не удалось проверить рекомендации. Сохранённые данные не изменены.';
    }
  }

  String _lastChecked(int milliseconds) =>
      'Проверено: ' + formatMoscowDate(DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true), includeTime: true);

  @override
  Widget build(BuildContext context) {
    final pending = loading || refreshing || status.busy || savingAutoUpdate;
    return PushokPanel(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Рекомендации',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          IconButton(
            key: const Key('info_recommendations'),
            tooltip: 'Об обновлении рекомендаций',
            onPressed: () => _showHelp(context),
            icon: const Icon(Icons.info_outline),
          ),
        ]),
        const SizedBox(height: 6),
        const Text('Встроенный список доступен сразу. При первом запуске '
            'установленные рекомендованные приложения включаются для прямого доступа. '
            'Вы можете изменить выбор в любой момент.',
          style: TextStyle(color: PushokPalette.muted)),
        const SizedBox(height: 8),
        Text(status.rulesVersion == 0 ? 'Встроенные рекомендации доступны офлайн'
            : 'Версия рекомендаций: ${status.rulesVersion}',
          key: const Key('recommendations_version'),
          style: const TextStyle(color: PushokPalette.muted)),
        if (status.checkedAtMillis != null) Text(
          _lastChecked(status.checkedAtMillis!),
          key: const Key('recommendations_checked_at'),
          style: const TextStyle(color: PushokPalette.muted)),
        SwitchListTile.adaptive(
          key: const Key('recommendations_auto_update'),
          contentPadding: EdgeInsets.zero,
          value: status.autoUpdateEnabled,
          onChanged: loading || savingAutoUpdate ? null : onAutoUpdateChanged,
          title: const Text('Обновлять автоматически'),
          subtitle: Text(savingAutoUpdate ? 'Сохраняем настройку…'
              : 'Раз в сутки при открытии «Маршрутов»',
            style: const TextStyle(color: PushokPalette.muted)),
        ),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
          key: const Key('refresh_recommendations'),
          onPressed: pending ? null : onRefresh,
          icon: pending
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          label: Text(savingAutoUpdate ? 'Сохраняем настройку…'
              : refreshing || status.busy ? 'Обновляем рекомендации…'
              : loading ? 'Читаем рекомендации…' : 'Обновить рекомендации'),
        )),
        if (status.errorCode != null && !pending) Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Semantics(liveRegion: true, child: Text(
            _errorMessage(status.errorCode!),
            key: const Key('recommendations_error'),
            style: const TextStyle(color: PushokPalette.orange),
          )),
        ),
      ]),
    );
  }
}
