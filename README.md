# Pushok Flow v0.21.0 — Android debug APK

Мобильное приложение Pushok Flow: WireGuard, выборочный прямой трафик приложений Android, фирменный неоновый интерфейс и локальная основа Pushok ИИ.

**Состояние:** Android debug APK успешно собран и проверен в GitHub Actions. Установка, реальное WireGuard-подключение и маршрутизация на физическом телефоне пока **не подтверждены**.

## Подтверждённая сборка

- Исходники: [`47b90d6`](https://github.com/mrkoster1988/Pushok-Flow/commit/47b90d6b1acd1bdc878a1d581315458f2f506aae), версия `0.21.0+21`.
- [Успешная Android-сборка и APK](https://github.com/mrkoster1988/Pushok-Flow/actions/runs/44811840135).
- [Успешные проверки исходников и Flutter](https://github.com/mrkoster1988/Pushok-Flow/actions/runs/44811840109).
- Проверены: 100 Python-тестов, исполняемые Kotlin-тесты маршрутов и диагностики, анализ Dart, 3 Flutter-теста, компиляция Android и итоговый манифест APK.
- APK: `app-debug.apk`, 168 984 920 байт; SHA-256: `85030b4370b2cca2b3dd070e0f22290f6b64a240cce6fa4420e33692843dfb61`.

Артефакт `pushok-flow-debug-apk` содержит APK; `pushok-flow-android-build-diagnostics` содержит журналы и `apk-sha256.txt`. Срок хранения в Actions — 7 дней. Это debug-сборка для тестирования. Порядок воспроизведения и проверки на телефоне: [docs/BUILD-AND-RELEASE.md](docs/BUILD-AND-RELEASE.md).

## Текущее состояние
- Flutter UI и фирменный дизайн Pushok с оригинальным маскотом.
- Android WireGuard GoBackend и мост Flutter ↔ Kotlin компилируются в полноценной APK-сборке.
- Исключения выбранных Android-приложений из туннеля.
- Локальная память обратной связи Pushok ИИ.
- Проверка обновлений зависимостей и CI.
- iPhone пока не реализован.

## Проверки

CI использует Flutter `3.50.0`, Material UI `1.11.1`, Java 17 и WireGuard `1.0.20260102`. Локально нужны Flutter и Android SDK; для самостоятельных Kotlin-проверок — `kotlinc`.

```bash
python -m unittest discover -s tests -v
bash tools/check_kotlin_routing.sh
flutter pub get
flutter analyze lib test
flutter test
```

Сборка APK: **Actions → Android debug APK (unverified on device) → Run workflow**. При сбое открыть артефакт `pushok-flow-android-build-diagnostics`.

## Безопасность

Никогда не публикуйте WireGuard PrivateKey, токены Pushok ID и реальные пользовательские конфигурации. Любые маршруты банков требуют проверки на устройстве. На iOS исключение произвольных приложений недоступно в обычном потребительском VPN.

## Визуальный стандарт

Согласованные неоновые бирюзово-фиолетовые макеты Pushok Flow; упрощение внешнего вида не допускается. Детали: [docs/DESIGN-SYSTEM.md](docs/DESIGN-SYSTEM.md).

## Обновления

Предусмотрен аудит зависимостей в 21:00 по Хельсинки, но расписание GitHub Actions может запускаться с задержкой. Обновления WireGuard не сливаются автоматически без проверки.

## План

P0: APK собран → установка и WireGuard на Android → проверка исключений → диагностика Pushok ИИ. Результаты устройства отслеживаются в [задаче #1](https://github.com/mrkoster1988/Pushok-Flow/issues/1). Позже iOS и Pushok Сейф с явным согласием пользователя.
