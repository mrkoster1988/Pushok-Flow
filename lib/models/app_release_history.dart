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
  AppReleaseNotes(versionName: '0.54.0', versionCode: 54, changes: [
    'Из смешанной подписки добавляются совместимые серверы VLESS. Количество пропущенных несовместимых записей показано в карточке подписки.',
    'На главной видно, какой сервер выбран для подключения. Нажмите на его название, чтобы перейти к списку серверов.',
    'Если в обновлении подписки нет совместимых серверов или ответ повреждён, сохранённый список остаётся доступен.',
  ]),
  AppReleaseNotes(versionName: '0.53.0', versionCode: 53, changes: [
    'QR подписки можно сканировать камерой или выбрать из фото прямо в форме добавления подписки.',
    'Распознанная ссылка остаётся скрытым черновиком; серверы загружаются после подтверждения добавления.',
  ]),
  AppReleaseNotes(versionName: '0.52.0', versionCode: 52, changes: [
    'Улучшено распознавание серых и малоконтрастных QR-кодов камерой.',
    'Ошибка защищённого соединения при загрузке подписки показана отдельно с подсказкой проверить HTTPS-адрес и сертификат у провайдера.',
  ]),
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
];

AppReleaseNotes? bundledAppRelease(String version, int build) {
  for (final release in bundledAppReleaseHistory) {
    if (release.matches(version, build)) return release;
  }
  return null;
}
