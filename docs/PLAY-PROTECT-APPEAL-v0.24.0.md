# Запрос на пересмотр Play Protect — Pushok Flow 0.24.0

**Статус: подготовлен для проверки владельцем, не отправлен.**

Адресат — команда Google Play Protect, через [официальную форму](https://support.google.com/googleplay/android-developer/contact/protectappeals). Текст ниже предназначен для поля объяснения; это не воспроизведение неизвестного набора обязательных полей формы. Владелец указывает свою контактную информацию только в официальной форме. Модель телефона и версия Android не известны и не выдуманы.

## Subject

Request for Play Protect classification review and detection details — shop.pushok.flow 0.24.0

## Message

Hello Google Play Protect team,

Please review the Play Protect classification of Pushok Flow 0.24.0 and identify the detection category, affected component or behavior, and any required remediation.

On 21 November 2026, a tester reported that installation was blocked with the Russian message “Вредоносное приложение заблокировано” (“Harmful app blocked”). The expanded explanation says the app may pose a threat to the device but provides no category, component or detection identifier. The tester confirmed the filename Pushok-Flow-v0.24.0.apk. We have not independently obtained the SHA-256 of the copy on the tester's phone; the identifiers below describe the published file that was provided for this test.

Published artifact:

- App: Pushok Flow
- Package: shop.pushok.flow
- Version: 0.24.0; versionCode: 24
- minSdk: 24; targetSdk: 36
- Filename: Pushok-Flow-v0.24.0.apk
- Size: 60332830 bytes
- APK SHA-256: fb7c45e7bfdf2fb804a3b92cc2f4d7acb9af9173aa093307cbad975fdcf6f228
- Signing certificate SHA-256: 8b4114881116a920c3351b503052ac27078fdbbfcae1ace27f1af8245ebb7047
- APK URL: https://github.com/mrkoster1988/Pushok-Flow/releases/download/v0.24.0/Pushok-Flow-v0.24.0.apk
- Source commit: https://github.com/mrkoster1988/Pushok-Flow/commit/355813cbf74a8f69a9cdf4c83869faa9d7b46b13

Pushok Flow is a Flutter Android WireGuard client. Users supply their own WireGuard configuration, confirm Android's VPN permission, and choose which applications should bypass the tunnel. The application also checks its own GitHub Releases channel for updates when the user requests a check.

The merged APK manifest requests INTERNET, REQUEST_INSTALL_PACKAGES, and the application's own signature-level DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION. It does not declare SMS, contacts, camera, microphone, location, broad external-storage, QUERY_ALL_PACKAGES, Accessibility Service, Notification Listener, or Device Admin access.

REQUEST_INSTALL_PACKAGES is used only for user-initiated updates of this application. The updater accepts HTTPS release URLs for the project's repository and allowed GitHub delivery hosts. It verifies the downloaded file's size, SHA-256, package name, version, SDK compatibility and signing certificate before offering installation. A separate user action opens Android's system installer; the application does not silently install APKs. Its non-exported FileProvider is restricted to the update cache directory.

WireGuard configuration is stored locally using Android Keystore and AES-GCM. In the own-source paths reviewed, the configuration is used by the internal Flutter bridge and WireGuard backend, and is not submitted with updater requests.

Our limited verification confirmed the published file's hash, APK v2/v3 signature and signing certificate, ZIP integrity and header consistency. All executable code and resource payloads match the CI candidate before permanent signing. These checks do not constitute an independent malware assessment. We have not completed a full audit of all third-party dependencies or a dynamic security analysis, and we do not claim that a false positive has been established.

We have advised the tester to keep Play Protect enabled and pause installation. Please provide details of the behavior or component that requires correction and reassess the classification if review determines that the app was incorrectly classified.

Thank you,
Pushok Flow project

## Дополнительные сведения для формы

В форме можно использовать опубликованный APK и его открытые реквизиты. Закрытый ключ подписи, пароли и WireGuard-конфигурации для этого не нужны. Скриншот пользователя не публиковался и не отправлялся; для приложения к обращению следует использовать только согласованный снимок самого предупреждения без лишних данных экрана.

[Отчёт об ограниченной проверке](PLAY-PROTECT-v0.24.0.md) фиксирует подтверждённые результаты и ограничения. Подготовка этого текста не означает, что обращение уже отправлено или что Google согласился пересмотреть классификацию.
