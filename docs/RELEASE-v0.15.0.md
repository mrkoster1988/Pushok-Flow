# Pushok Flow v0.15.0 — Android build gate

- Добавлен Flutter widget smoke test главного экрана.
- Перед Android APK обязательна команда `flutter test` с сохранением диагностического журнала.
- В source checks также запускаются Flutter тесты.
- Удалены неиспользуемые переменные исключений в Dart `catch`.

## Проверки

Локальные Python-тесты и исполняемые проверки Kotlin не подтверждают компиляцию Flutter и Android APK.
Flutter SDK в окружении не установлен; `flutter test` будет исполнен в CI после размещения проекта в GitHub.

## Публикация

Исходники находятся в архиве. Отдельный репозиторий GitHub не создан, CI ещё не запущен.