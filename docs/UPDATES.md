# Pushok Flow — обновления и безопасность

## Источники

- WireGuard tunnel: Maven Central (`com.wireguard.android:tunnel`).
- Flutter stable: официальный релиз Flutter (GitHub / Flutter SDK archive).
- Dart/Flutter зависимости: Renovate (`pub`).
- Android Gradle Plugin, Kotlin, Gradle wrapper: Renovate (`gradle`, `gradle-wrapper`).
- GitHub Actions: Renovate (`github-actions`).
- В будущем для iOS: CocoaPods/SwiftPM, после создания настоящего iOS-проекта.

## Автоматическая проверка

Workflow `.github/workflows/dependency-audit.yml` проверяет версии ежедневно по cron; запуск вручную доступен через `workflow_dispatch`. Время GitHub cron — UTC, поэтому на переходе летнего времени может быть сдвиг. Для точного 21:00 по часовому поясу устройства нужен отдельный планировщик на стороне приложения/сервера.

Результат: отчёт Markdown в GitHub Actions Summary и артефакт `pushok-flow-dependency-report`.
Renovate создаёт dependency dashboard и PR при наличии обновлений. Для этого **нужно активировать GitHub App Renovate в репозитории**; один конфигурационный файл не запускает Renovate.

## Что НЕЛЬЗЯ обновлять автоматически

- WireGuard tunnel, GoBackend, Android VPN API, правила DNS/IPv6 и обход приложений — только после review и испытаний на устройстве.
- Серверные изменения — после health-check и проверки отката.
- Подписанные правила маршрутизации — только после внедрения проверки Ed25519 подписи, защиты от rollback и staged rollout.
- APK и iOS клиент — через разрешённые платформой способы распространения, с подтверждением пользователя.

## Проверки после обновления

1. CI сборка + unit tests.
2. Действительная связь с WireGuard-сервером.
3. Проверка прямого IP у исключённого Android-приложения.
4. IPv4/IPv6/DNS и Wi-Fi↔mobile handover.
5. Поведение always-on VPN/lockdown и восстановление соединения.
6. Отчёт Pushok ИИ; никакого автоматического изменения исключений пользователя.

## Текущее состояние

Это исходный проект: GitHub workflow начнёт работать после помещения проекта в репозиторий. Реальная установка обновлений и подписанная доставка правил ещё не реализованы.