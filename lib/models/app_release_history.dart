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
    'В маршрутах есть 15 рекомендованных приложений и выбор прямого подключения для 12 сайтов в браузере.',
    'Если Telegram не выходит на связь, на главной можно получить гостевое подключение на семь суток.',
    'Кнопка MTProxy открывает действующий прокси Pushok в Telegram. Подтвердите подключение после возврата в Flow.',
  ]),
  AppReleaseNotes(versionName: '2.0.5', versionCode: 70, changes: [
    'В настройках видны IP-адреса телефона и расход трафика по приложениям за 24 часа.',
    'Системный жест «Назад» возвращает из раздела в настройки, затем на главную.',
  ]),
  AppReleaseNotes(versionName: '2.0.4', versionCode: 69, changes: [
    'На плитке быстрых настроек Android теперь мордочка Пушка.',
  ]),
  AppReleaseNotes(versionName: '2.0.3', versionCode: 68, changes: [
    'Вход открывает Telegram на телефоне. Без Telegram кнопка подключения получает гостевой доступ на семь суток.',
  ]),
  AppReleaseNotes(versionName: '2.0.2', versionCode: 67, changes: [
    'Виджет показывает цветного Пушка при подключении и серого при отключении.',
    'На главной увеличена кнопка, усилено свечение волн и изменено расположение показателей и сообщений.',
  ]),
  AppReleaseNotes(versionName: '2.0.1', versionCode: 66, changes: [
    'Новая иконка Пушка, компактный виджет и подключение из шторки Android.',
    'Обновлена главная, добавлены замер задержки и подключение свайпом вверх.',
  ]),
  AppReleaseNotes(versionName: '2.0.0', versionCode: 65, changes: [
    'Личное подключение Flow. Вход через кабинет MTProxy в браузере.',
  ]),
  AppReleaseNotes(versionName: '0.64.0', versionCode: 64, changes: [
    'Теперь большая кнопка «Подключить» сама запускает вход через Telegram, проверку личной подписки Shop и подключение после её выдачи.',
    'При повторном входе в тот же подтверждённый аккаунт Flow проверяет сохранённую личную подписку без лишнего обмена одноразовыми ключами.',
    'Убраны отдельная кнопка входа и «Добавить сервер» с главной; продление подписки перенесено ниже статуса соединения.',
    'Повторные обращения к Shop ограничены после ответа 429; ручные профили доступны через настройки.',
  ]),
  AppReleaseNotes(versionName: '0.63.0', versionCode: 63, changes: [
    'Добавлен виджет домашнего экрана для подключения и отключения выбранного профиля.',
    'В шторке Android отображается состояние подключения с кнопкой отключения.',
    'В настройках аккаунта можно разрешить уведомления о балансе и кампаниях после подключения Firebase на сервере.',
  ]),
  AppReleaseNotes(versionName: '0.62.0', versionCode: 62, changes: [
    'Личная подписка Shop привязана к подтверждённому аккаунту Pushok, а не телефону: передаётся только одноразовый билет входа.',
    'На главной появились «Продлить» и «Удалить конфиг». Продление открывает Shop; удаление отключает автоимпорт, сохраняя аккаунт и доступ.',
    'Добавлены безопасные проверки удаления, повторного входа и сохранения остальных профилей.',
  ]),
  AppReleaseNotes(versionName: '0.61.0', versionCode: 61, changes: [
    'Исправлена диагностика подключения Shop: другой телефон, повторное подтверждение входа и конфликт аккаунта теперь различаются.',
    'Неизвестный ответ Shop больше не выдаётся за чужое устройство. Секретные коды подтверждения и ссылки остаются внутри Android.',
    'Получение личного профиля, маршруты и остальные настройки сохраняют прежнее поведение.',
  ]),
  AppReleaseNotes(versionName: '0.60.0', versionCode: 60, changes: [
    'Оставлена одна главная: кнопка подключения, вход через MTProxy, получение личного конфига, состояние подписки и туннеля.',
    'Маршруты, серверы, аккаунт, обновления и Pushok ИИ перенесены в настройки по шестерёнке; справка размещена первой.',
    'Главная показывает реальный трафик и возраст обмена ключами. Пинг не выдаётся за измеренный, если замер недоступен.',
  ]),
];

AppReleaseNotes? bundledAppRelease(String version, int build) {
  for (final release in bundledAppReleaseHistory) {
    if (release.matches(version, build)) return release;
  }
  return null;
}
