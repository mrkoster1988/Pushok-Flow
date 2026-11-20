# Pushok Flow: сборка и проверка Android

## Подтверждённый результат

Debug APK версии `0.21.0+21` собран из коммита [`47b90d6b1acd1bdc878a1d581315458f2f506aae`](https://github.com/mrkoster1988/Pushok-Flow/commit/47b90d6b1acd1bdc878a1d581315458f2f506aae).

[Android Actions run 44811840135](https://github.com/mrkoster1988/Pushok-Flow/actions/runs/44811840135) завершился успешно. Пройдены Python- и Kotlin-проверки, анализ Dart, все 3 Flutter-теста, `:app:compileDebugKotlin`, объединение манифеста и `flutter build apk --debug`.

Итоговый APK проверен через Android SDK `aapt`: пакет `shop.pushok.flow`, разрешение `INTERNET`, ровно один сервис WireGuard с `BIND_VPN_SERVICE` и `exported=false`. В скачанном APK присутствует `libwg-go.so` для `arm64-v8a`, `armeabi-v7a` и `x86_64`; изображение маскота совпадает с исходником.

| Поле | Значение |
| --- | --- |
| Артефакт Actions | `pushok-flow-debug-apk` |
| Файл внутри артефакта | `app-debug.apk` |
| Размер APK | 168 984 920 байт |
| SHA-256 APK | `85030b4370b2cca2b3dd070e0f22290f6b64a240cce6fa4420e33692843dfb61` |
| Диагностика | `pushok-flow-android-build-diagnostics` |
| Хранение артефактов Actions | 7 дней |

## Воспроизведение сборки

CI закрепляет Flutter `3.50.0`, Java 17, Kotlin CLI `2.2.21` для самостоятельных проверок и WireGuard `1.0.20260102`. Пакет интерфейса Material UI закреплён на `1.11.1`. Kotlin-компилятором Android-проекта управляет Gradle-шаблон Flutter.

1. В репозитории открыть **Actions → Android debug APK (unverified on device) → Run workflow**. Workflow также запускается при push в `main` и при pull request.
2. Проверить успешное завершение всех шагов. При сбое изучить `pushok-flow-android-build-diagnostics`.
3. Скачать `pushok-flow-debug-apk` и распаковать APK. Сверить SHA-256 с `apk-sha256.txt` из диагностического артефакта именно этого запуска.

Для локальной сборки с установленными Flutter, Android SDK, Java и Kotlin CLI:

```bash
python3 -m unittest discover -s tests -v
bash tools/bootstrap_android.sh
flutter pub get
bash tools/check_kotlin_routing.sh
flutter analyze lib test
flutter test --reporter expanded
python3 tools/check_android_manifest.py
flutter build apk --debug
python3 tools/verify_android_apk.py build/app/outputs/flutter-apk/app-debug.apk
sha256sum build/app/outputs/flutter-apk/app-debug.apk
```

Bootstrap создаёт временный Flutter-проект и переносит только Android-часть. Существующие исходники приложения, `pubspec.yaml`, тесты и документация сохраняются. Стандартный тест счётчика `MyApp` в проект не добавляется. Манифест сохраняет запрос `PROCESS_TEXT` и получает отдельный `MAIN`/`LAUNCHER` для списка приложений; резервное копирование защищённых профилей отключено.

## Следующий этап: физический Android

Успешная сборка подтверждает компиляцию и содержимое APK. Установка и реальное VPN-соединение ещё не проверены. Результаты фиксируются в [задаче #1](https://github.com/mrkoster1988/Pushok-Flow/issues/1).

1. Установить debug APK на тестовый телефон, записать модель, версию Android и коммит сборки.
2. В приложении импортировать тестовый WireGuard-профиль и выдать системное разрешение VPN. Проверить подключение, отключение, DNS, IPv4 и IPv6.
3. Выбрать приложение для прямого маршрута при выключенном туннеле; после подключения проверить, что его трафик идёт напрямую, а трафик остальных приложений — через туннель.
4. Проверить MAX, VK, банки, Ozon и Wildberries. Сам факт прямого маршрута не гарантирует принятие приложением активного системного VPN.
5. Проверить отказ в разрешении VPN, поворот экрана, возврат из фона и повторное подключение. Сопоставить состояние и uptime интерфейса с реальным туннелем.
6. Сверить внешний вид на телефоне с утверждёнными неоновыми макетами: фон, волны, круглая кнопка, фирменный рыжий маскот, светящиеся карточки и контурные иконки.

Приватные ключи, реальные VPN-конфигурации и персональные данные в Issues и журналы не добавляются. Выпуск подписанной release-сборки и проверка на устройстве остаются отдельными этапами.
