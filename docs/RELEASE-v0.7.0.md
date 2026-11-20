# Pushok Flow v0.7.0 — Android build readiness

## Исправления
- Исправлено несоответствие `applicationId` / `namespace` и пакета Kotlin `MainActivity`.
- Генерируемая Flutter заглушка `shop.pushok.pushok_flow.MainActivity` удаляется при bootstrap; основная Activity — `shop.pushok.flow.MainActivity`.
- Сохранение исключений подтверждается только после синхронной записи в SharedPreferences.
- В Android CI добавлена отдельная проверка компиляции Kotlin и Android Manifest перед `flutter build apk --debug`.
- В CI запускаются Python-тесты регрессий и проверяется наличие непустого APK.

## Что не подтверждено
- Flutter и Android SDK отсутствуют в локальной среде: реальная компиляция здесь **не выполнена**.
- Не выполнена установка APK на устройство, не проверены Android-разрешения, сеть, WireGuard и прямой трафик исключённых приложений.
- GitHub Actions начнёт работать только после загрузки исходников в репозиторий.

## Проверка на Android (после публикации)
1. Запустить workflow `Android debug APK`, убедиться в успехе `compileDebugKotlin` и `flutter build apk --debug`.
2. Установить артефакт APK на тестовый Android.
3. Импортировать тестовый WireGuard-профиль, разрешить VPN, проверить публичный IP через туннель.
4. Выбрать установленное приложение для исключения, отключить/подключить туннель и проверить прямой IP при активном VPN.
5. Проверить мобильный интернет, Wi-Fi, DNS, IPv6, Always-on VPN и режим `Block connections without VPN`.
6. Никогда не публиковать приватные WireGuard-ключи в логах и issue.