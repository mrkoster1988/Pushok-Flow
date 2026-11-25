import 'app_version.dart';

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
  AppReleaseNotes(versionName: appVersionName, versionCode: appVersionCode, changes: [
    'Исправлена диагностика подключения Shop: другой телефон, повторное подтверждение входа и конфликт аккаунта теперь различаются.',
    'Неизвестный ответ Shop больше не выдаётся за чужое устройство. Секретные коды подтверждения и ссылки остаются внутри Android.',
    'Получение личного WireGuard-профиля, маршруты и остальные настройки сохраняют прежнее поведение.',
  ]),
  AppReleaseNotes(versionName: '0.60.0', versionCode: 60, changes: [
    'Оставлена одна главная: кнопка подключения, вход через MTProxy, получение личного конфига, состояние подписки и туннеля.',
    'Маршруты, серверы, аккаунт, обновления и Pushok ИИ перенесены в настройки по шестерёнке; справка размещена первой.',
    'Главная показывает реальный трафик и возраст WireGuard-рукопожатия. Пинг не выдаётся за измеренный, если замер недоступен.',
  ]),
  AppReleaseNotes(versionName: '0.59.0', versionCode: 59, changes: [
    'Добавлено получение личной WireGuard-подписки через аккаунт Pushok и Shop без QR. Подключение не запускается автоматически.',
    'Нативный обмен проверяет короткоживущий билет, текущий аккаунт и закреплённый телефон. Ключи и личные ссылки скрыты от интерфейса.',
    'Доступны автоматическая проверка с отдельным согласием и ручное обновление. При выходе из аккаунта личное подключение защищено.',
  ]),
  AppReleaseNotes(versionName: '0.58.0', versionCode: 58, changes: [
    'Установленные рекомендуемые приложения для прямого доступа включаются по умолчанию при первом запуске маршрутов.',
    'Встроенный список рекомендаций доступен без интернета. Автообновление рекомендаций включено на новых установках.',
    'Недоступные приложения не добавляются в исключения. Правила маршрутизации применяются при следующем подключении.',
  ]),
  AppReleaseNotes(versionName: '0.57.0', versionCode: 57, changes: [
    'Добавлена поддержка персональных WireGuard-подписок в совместимом формате Flow. Магазин должен поддерживать выдачу этого формата.',
    'В карточке WireGuard-подписки видны срок и состояние доступа. После истечения срока новое подключение недоступно до продления и обновления.',
    'Продление сохраняет выбранный сервер по его идентификатору. Подтверждённый отзыв удаляет только серверы этой подписки; ошибка загрузки сохраняет прежние настройки.',
  ]),
];

AppReleaseNotes? bundledAppRelease(String version, int build) {
  for (final release in bundledAppReleaseHistory) {
    if (release.matches(version, build)) return release;
  }
  return null;
}
