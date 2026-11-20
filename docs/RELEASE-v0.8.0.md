# Pushok Flow v0.8.0 — Android-сборка и защита VPN-сервиса

Дата: 2026-11-20

## Изменения

- Удалено повторное объявление `GoBackend$VpnService` из приложения: официальная WireGuard Tunnel AAR уже предоставляет service через manifest merger с `android:exported="false"`.
- `tools/patch_android_project.py` автоматически удаляет опасное старое объявление из ранее созданного Android Manifest.
- Добавлена проверка `tools/check_android_manifest.py`, блокирующая повторное объявление сервиса и включённый Auto Backup.
- В Android CI проверка Manifest выполняется до компиляции Kotlin.
- Версия обновлена до `0.8.0+8` и отображается на экране профиля.

## Проверки

- 34/34 Python unit tests — успешно.
- Проверка идемпотентности Android Gradle/Manifest патчера — два запуска успешно.
- `python -m compileall` и `bash -n` — успешно.
- **Не выполнены:** Flutter analyze / Gradle compile / APK build / физический Android-тест. Flutter SDK и Android SDK отсутствуют в данном окружении. Ни подключение WireGuard, ни обход приложений не подтверждены.

## Следующий обязательный рубеж

1. Создать отдельный GitHub-репозиторий Pushok Flow и загрузить исходники.
2. Запустить `.github/workflows/android-debug-apk.yml` и исправить реальные ошибки Gradle/Kotlin/Dart.
3. Скачать debug APK из CI и испытать на Android с тестовым WireGuard-сервером.
4. Убедиться, что исключённые приложения используют IP провайдера (с учётом DNS, IPv6 и Android lockdown mode).
5. Не включать автоматическую установку обновлений VPN-движка до реальных регрессионных испытаний.