/// Local rules assistant: no remote prompts, packet inspection, or model training.
class PushokAi {
  static const name = 'Pushok ИИ';

  static String routingAdvice({required bool isAndroid, required int excluded}) {
    if (!isAndroid) {
      return 'На iPhone исключение произвольных приложений недоступно. '
          'Можно настроить поддерживаемые сетевые маршруты.';
    }
    if (excluded == 0) {
      return 'Добавьте приложения в список прямого подключения. '
          'Pushok ИИ сохранит выбранные правила на этом устройстве.';
    }
    return 'Сохранено исключений: $excluded. Для применения к действующему '
        'туннелю потребуется переподключение после интеграции WireGuard.';
  }
}
