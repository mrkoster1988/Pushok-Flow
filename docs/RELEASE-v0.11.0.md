# Pushok Flow v0.11.0

- Поле WireGuard закрыто по умолчанию; явная кнопка просмотра. Приватный ключ не выводится в диагностические сообщения UI.
- Сетевые ошибки исключений не отображают содержимое исключения/исходное исключение метода.
- После сборки APK проверяется, что объединённый Manifest содержит один сервис WireGuard с `android:exported=false`. Формат `aapt` может меняться, тогда CI остановится безопасным образом.
- Сборка APK и физическое тестирование всё ещё не проведены.

## Применение

```bash
python -m unittest discover -s tests -v
bash tools/bootstrap_android.sh
flutter pub get
flutter analyze lib
flutter build apk --debug
python tools/verify_android_apk.py build/app/outputs/flutter-apk/app-debug.apk
```

Не публиковать debug APK как релиз и не использовать реальный приватный ключ в журналах CI.