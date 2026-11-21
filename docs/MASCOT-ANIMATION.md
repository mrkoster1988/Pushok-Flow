# Pushok Flow — происхождение кадра моргания

## Исходник и результат

Для v0.30.0 используется прежний фирменный котёнок из `assets/mascot/pushok.png`. Его файл сохранён побайтово. Дополнительный кадр `assets/mascot/pushok_blink.png` создан встроенным инструментом `image_gen` редактированием исходника с запросом закрыть только глаза и сохранить прозрачность. Сгенерированные байты скопированы в проект без ресайза, обрезки или перерисовки.

| Свойство | Исходный кадр | Закрытые глаза |
| --- | --- | --- |
| Путь | `assets/mascot/pushok.png` | `assets/mascot/pushok_blink.png` |
| Размер | 400 × 422 | 1221 × 1288 |
| Формат | RGBA | RGBA |
| Диапазон alpha | 0–255 | 0–254 |
| Размер файла | 223 825 байт | 1 543 305 байт |
| SHA-256 | `8e90c424e4cdf7a1ce9c36481364237df90e7d9f2861a0e5a52499e8d229b55c` | `c8aa33104c64b20ff38070b6cb27b1ba03be9c1dcd9836552e951745223d5c90` |

Ключевые ограничения использованного промпта: изменить только два глаза до естественно закрытых век; сохранить улыбку, нос, усы, наклон головы, пропорции, шерсть, худи, эмблему, шнурки, лапы и хвост; сохранить масштаб, положение и прозрачный фон; не добавлять предметы, текст или водяной знак. Генератору отдельно сообщалось, что кадр предназначен для моргания и требуется регистрация с исходным изображением.

Режим: встроенный `image_gen`, редактирование существующего изображения с `transparent_background: true`. Полный промпт:

```text
Use case: precise-object-edit.
Asset type: closed-eyes animation frame for an existing transparent mobile-app mascot. The supplied image is the edit target, not a style reference.
Primary request: change ONLY the two eyes of this exact orange kitten so both eyelids are naturally fully closed for a brief calm, happy blink. Use gentle curved closed eyelid lines with the existing orange fur; no visible green iris or pupil in either eye. Keep the existing tiny open smile, nose, eyebrows, whiskers, ears, head angle, and facial proportions unchanged.
Pixel registration is essential: preserve the original 400 x 422 pixel canvas if possible, the exact subject scale and position, its silhouette and every part outside the two eyes. This frame will crossfade with the source, so there must be no camera movement, recentering, repositioning, zoom, crop, stretch, or pose change.
Keep the precise original fluffy orange fur texture, markings, lighting, teal hoodie, hoodie shield-and-lock emblem, drawstrings, seated body, paws, curled tail, and all transparent margins unchanged. Keep the background genuinely transparent with alpha, including delicate fur and whisker edges. Preserve existing branding on the hoodie. No new shadow, ground, background, objects, text, frame, or watermark. Do not redraw or reinterpret the whole kitten. Only close its eyelids.
```

## Почему используется только область глаз

Генератор сохранил персонажа визуально, но увеличил разрешение и немного изменил геометрию. При alpha ≥128 нормализованная рамка исходника равна `(0.15250, 0.00948, 0.84000, 0.97393)`, нового кадра — `(0.15233, 0.00854, 0.84275, 0.96506)`. При полном переключении кадров нижняя граница лап может перемещаться примерно на 3,7 пикселя при высоте изображения 422 пикселя.

Поэтому исходный PNG остаётся постоянным базовым слоем с пропорциями 400 × 422. Новый кадр служит текстурой для двух локальных областей глаз: две `ShaderMask` с мягким краем показывают закрытые веки без подмены тела, хвоста и одежды. Оба изображения предзагружаются, а моргание включается только после успешной загрузки. Дыхание и реакция на касание применяются к маскоту целиком отдельными преобразованиями; они не исправляют и не скрывают проблему регистрации полного кадра.

## Параметры движения

| Элемент | Параметры |
| --- | --- |
| Общий цикл маскота | 20 секунд |
| Моргание | По 160 мс на отметках 3,6; 9,4; 9,68 и 16,8 секунды; средние два образуют двойное моргание |
| Дыхание | Масштаб ±0,3%, период 4 секунды |
| Парение | Смещение ±1,2 px при высоте маскота 160 px, период 5 секунд |
| Наклон | До 0,014 радиана на участке 12–14,4 секунды цикла |
| Реакция | Подскок 480 мс по касанию и при переходе переданного статуса соединения из `false` в `true` |

В `lib/main.dart` маскоту передаётся подтверждённое состояние туннеля. Появление анимации само по себе не служит доказательством доступности сайтов, DNS или правильности маршрутов.

Фон имеет отдельный 24-секундный цикл: три мягкие световые области cyan/blue/violet, три тонкие волны и девять редких частиц. Анимация обновляет `CustomPainter`, не перестраивая по кадрам содержимое экрана.

## Доступность и проверка

Маскот получает одно семантическое описание. `MediaQuery.disableAnimations` оставляет статичный маскот и фон. Неактивный жизненный цикл приложения или отключённый `TickerMode` останавливает контроллеры без сброса фазы; после возвращения движение продолжается. При удалении виджета контроллеры и связанные ресурсы освобождаются. Касание маскота при разрешённой анимации управляет только визуальной реакцией; подключение остаётся отдельным действием.

Код сопоставлен с этими ограничениями, оба PNG визуально просмотрены и проверены на прозрачность. Их байты в итоговом APK совпадают с исходниками. Flutter smoke-тест подтвердил остановку и возобновление контроллеров и освобождение ресурсов; весь набор из 149 Flutter-тестов прошёл. Визуальное качество наложения век в движении, плавность и поведение на конкретном телефоне остаются проверкой устройства.
