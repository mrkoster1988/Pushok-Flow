# Pushok Flow 0.10.0 — проверка жизненного цикла WireGuard

## Изменения

- Process-scoped `GoBackend` and `Tunnel` singleton for Activity recreation safety.
- Mutex-style guard against concurrent connection mutations.
- Route-edit lock during VPN permission prompt and state transitions.
- Five new structural regression checks.

## Ограничения

Проверки структуры исходников не заменяют Android компиляцию, интеграционные испытания и тесты на устройстве. При завершении процесса ОС сохранение работающего туннеля пока не гарантировано.

## Проверка на устройстве

1. Собрать debug APK через GitHub Actions.
2. Подключиться к тестовому WireGuard серверу.
3. Перевернуть устройство или пересоздать Activity, проверить статус и отключение.
4. Включить исключение для одного тестового приложения, убедиться в прямом внешнем IP.
5. Проверить, что смена маршрутов при активном туннеле запрещена.
6. Перезапустить процесс приложения, оценить поведение VPN-сервиса.