# Pushok Flow v0.13.0 — сборочные проверки и Android Smart Routing

## Изменения
- Добавлен исполняемый тест реального Kotlin-кода `WireGuardRouting.prepare`: добавление, замена и очистка списка исключений, проверка некорректных входных данных.
- `tools/check_kotlin_routing.sh` компилирует Kotlin в отдельном временном каталоге и запускает тесты.
- GitHub Actions Android CI теперь сохраняет логи Flutter doctor, bootstrap, анализа, Gradle/Kotlin и сборки APK в диагностические артефакты, включая неуспешные запуски.
- Сохранена ежедневная проверка обновлений зависимостей в 21:00 Europe/Helsinki с учётом сезонного времени.

## Проверка локально
```bash
python -m unittest discover -s tests -v
bash tools/check_kotlin_routing.sh  # Требуются kotlinc и java
bash tools/bootstrap_android.sh     # Требуется Flutter SDK
flutter pub get
flutter build apk --debug
```

## Ограничения
- Исполняемый Kotlin-тест НЕ компилирует весь Android-проект и не проверяет реальный туннель.
- Android APK не был собран локально: Flutter SDK и Android SDK в данном окружении отсутствуют.
- Workflows начнут выполняться только после публикации в GitHub; публикация пока не выполнена.
- Для реальной проверки маршрутизации нужен Android-телефон и рабочий WireGuard-сервер.