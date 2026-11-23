/// Plain-text descriptions only. Download eligibility and verification remain
/// native responsibilities; invalid optional notes never block an update.
class AppReleaseNotes {
  const AppReleaseNotes({required this.versionName, required this.versionCode,
    required this.changes, this.publishedOn});

  final String versionName;
  final int versionCode;
  final List<String> changes;
  final String? publishedOn;

  bool matches(String version, int build) =>
      versionName == version && versionCode == build;

  static AppReleaseNotes? fromPlatform(Object? value, {
    required String expectedVersion, required int expectedBuild,
  }) {
    if (value is! Map) return null;
    final version = value['versionName'];
    final build = value['versionCode'];
    final changes = value['changes'];
    final publishedOn = value['publishedOn'];
    if (version != expectedVersion || build is! int || build != expectedBuild ||
        changes is! List || changes.isEmpty || changes.length > 8) return null;
    final plainChanges = <String>[];
    var totalLength = 0;
    for (final change in changes) {
      if (change is! String || change.length > 600 || change.trim().isEmpty ||
          !_isPlainReleaseText(change)) return null;
      totalLength += change.length;
      if (totalLength > 4000) return null;
      plainChanges.add(change.trim());
    }
    if (publishedOn != null) {
      if (publishedOn is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(publishedOn)) return null;
      final date = DateTime.tryParse(publishedOn);
      if (date == null || date.year.toString().padLeft(4, '0') != publishedOn.substring(0, 4) ||
          date.month.toString().padLeft(2, '0') != publishedOn.substring(5, 7) ||
          date.day.toString().padLeft(2, '0') != publishedOn.substring(8, 10)) return null;
    }
    return AppReleaseNotes(versionName: expectedVersion, versionCode: expectedBuild,
      changes: List.unmodifiable(plainChanges), publishedOn: publishedOn as String?);
  }
}

bool _isPlainReleaseText(String text) {
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit < 32 || unit == 127 || (unit >= 0x202a && unit <= 0x202e) ||
        (unit >= 0x2066 && unit <= 0x2069)) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= text.length) return false;
      final next = text.codeUnitAt(index);
      if (next < 0xdc00 || next > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

/// Bundled descriptions stay readable offline. Keep the five most recent
/// Android versions; do not turn test results or publication plans into claims.
const bundledAppReleaseHistory = <AppReleaseNotes>[
  AppReleaseNotes(versionName: '0.51.0', versionCode: 51, changes: [
    'Выбранный сервер подписки больше не сбрасывается при перестановке параметров VLESS-ссылки или изменении регистра адреса.',
    'Некорректное обновление с повторяющимися подключениями не заменяет сохранённые серверы.',
    'Ожидание чтения профиля перед подключением ограничено. Если чтение не завершилось, можно повторить попытку; запоздавший ответ не запускает подключение.',
  ]),
  AppReleaseNotes(versionName: '0.50.0', versionCode: 50, changes: [
    'Ошибка одной подписки больше не прерывает автоматическое обновление остальных.',
    'Причина неудачного обновления показана у соответствующей подписки. Повторить проверку можно отдельно.',
    'Успешно обновлённые серверы сразу отображаются в списке. При ошибке провайдера сохраняются прежние серверы этой подписки.',
  ]),
  AppReleaseNotes(versionName: '0.49.0', versionCode: 49, changes: [
    'При сбое локального хранилища аккаунта доступно восстановление входа с подтверждением. После него можно снова войти через существующий кабинет MTProxy.',
    'Запоздавшая ссылка подписки после возврата в приложение сохраняется как скрытый черновик и не открывает редактор автоматически.',
    'Автоматическое обновление подписок можно отключить во время ожидания ответа сервера.',
    'Старое задание загрузки больше не заменяет найденное или скачанное более новое обновление.',
  ]),
  AppReleaseNotes(versionName: '0.48.0', versionCode: 48, changes: [
    'В приложении появился раздел „Что нового“ с изменениями текущей версии и историей выпусков, доступной без сети.',
    'Описание доступного обновления показывается перед загрузкой.',
    'Отмена входа и выход из аккаунта доступны во время ожидания сервера; запоздавший ответ не возвращает отменённый вход.',
    'Камера распознаёт неполные и составные QR-коды и сообщает, что нужен один полный код.',
    'Импорт из зависшего источника файла завершается по тайм-ауту; сканирование камерой остаётся доступным. Исправлена проверка ссылок внутри QR-кодов.',
  ]),
  AppReleaseNotes(versionName: '0.47.0', versionCode: 47, changes: [
    'VLESS использует выбранную сеть Android при переходе между Wi-Fi и мобильным интернетом.',
    'При потере сети отображается ожидание; подключение можно остановить.',
    'Улучшена обработка смены сети на Android 7 и с Private DNS.',
  ]),
];

AppReleaseNotes? bundledAppRelease(String version, int build) {
  for (final release in bundledAppReleaseHistory) {
    if (release.matches(version, build)) return release;
  }
  return null;
}
