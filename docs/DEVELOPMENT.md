# Сборка и проверка Mumpa

[На главную](../README.md) · [CI, подпись и публикация](CI.md)

Все команды выполняются из корня репозитория.

## Окружение

Проверенная среда: Flutter 3.44.4 stable / Dart 3.12.2, Windows Build Tools с C++/Windows SDK, Android SDK и JDK 21. Версии зависимостей закреплены в `pubspec.lock`.

Для сборки движка из исходников нужен Go с разрешённой загрузкой закреплённых toolchain и Android NDK 28.2.13676358. Точные версии и параметры приведены в `engine-patches/README.md`; готовые проверенные engine assets повторно не собираются.

## Подготовка, сборка и упаковка

```powershell
./tools/prepare-engines.ps1
./tools/prepare-jackett.ps1
./tools/prepare-flaresolverr.ps1
flutter pub get
flutter analyze
flutter test
flutter test integration_test/app_test.dart -d windows
flutter test integration_test/app_test.dart -d <android-device-id>
flutter build windows --release --target lib/main.dart
./tools/build-android.ps1
./tools/package-release.ps1
```

Упаковка через PowerShell 7 сохраняет только последний успешный локальный выпуск
в `artifacts/release-<version>` и удаляет кэши сборки. Для отладки с сохранением
кэша: `./tools/package-release.ps1 -KeepBuildCache`. План ручной уборки:
`pwsh -File tools/clean-workspace.ps1 -WhatIf`; применение — та же команда без
`-WhatIf`, после завершения сборок и эмулятора. Подробности и отдельные категории
очистки — в [CI.md](CI.md#локальное-место-на-диске).

Нативные сборки и integration-запуски выполнять последовательно: Flutter обновляет общие файлы регистрации плагинов. Android-пакет включает только Android-движок соответствующей ABI; Windows-движок и архив Jackett — только Windows assets. Android использует AGP 8.13.2 / Gradle 8.13 для совместимости стабильного WebView-плагина; Kotlin 2.3.20.

## Дополнительные проверки

Проверка обложек сохранённой дискографии «Ежемесячных» на Windows: `flutter test integration_test/artwork_navigation_test.dart -d windows --dart-define=REAL_ARTWORK_TEST=true`. Перед ней закрыть обычную Mumpa и задать `MUMPA_TEST_PYTHON` полным путём к Python для проверки нативной кнопки мыши «Назад». Тест использует копию библиотеки, загружает и декодирует все 72 обложки и прогревает только кеш картинок пользовательского профиля; аудио и библиотеку не изменяет. Интерфейс появляется перед сетевой проверкой.

Проверка локального поиска на сохранённой коллекции «Ежемесячные»: `flutter test integration_test/local_search_test.dart -d windows --dart-define=REAL_LOCAL_SEARCH_TEST=true`. Тест читает исходный профиль, исключает настройки и приватные ссылки, импортирует коллекцию в отдельную временную библиотеку и проверяет 72 полных альбома, «Лимбо», «твои уши», фокус общего поля и Back. HTTP и движок запрещены; исходная библиотека остаётся без изменений. Снимок интерфейса: `test-output/real-local-search-1.2.4.png`.

Проверка параллельных загрузок в Windows: `flutter test integration_test/parallel_download_test.dart -d windows --dart-define=PARALLEL_DOWNLOAD_TEST=true`. Отдельная временная библиотека и локальный HTTP-сервер проверяют три активных потока, очередь, реальную кнопку паузы/продолжения и точные байты четырёх оригинальных WAV. Снимок и JSON-проверка сохраняются в `test-output/parallel-downloads-1.2.5.*`. Это проверка загрузчика и интерфейса; публичный BitTorrent-канал здесь не измеряется.

Проверка перемещения очереди в Windows: `flutter test integration_test/queue_reorder_test.dart -d windows --dart-define=QUEUE_REORDER_TEST=true`. Изолированная библиотека с оригинальными WAV и настоящий libmpv проверяют два перетаскивания, сохранение позиции без повторного открытия декодера, возобновление и переход к следующему треку в новом порядке. Снимок и JSON сохраняются в `test-output/queue-reorder-1.2.6.*`; пользовательская библиотека и сетевые источники не используются.

После Android integration-теста запускать release-сборку обычной командой без `--no-pub`: Flutter должен обновить регистрацию плагинов и исключить тестовый `integration_test` из release. Иначе оставшийся с теста Java-регистратор ссылается на отсутствующий release-плагин.

Скрипты `prepare-engines.ps1`, `prepare-jackett.ps1` и `prepare-flaresolverr.ps1` проверяют SHA-256 закреплённых бинарников и сохраняют соответствующие исходники/лицензии. Исправленный движок собирается через `tools/build-managed-engine.ps1`; закреплённые исходники, overlay, Go/NDK и хеши описаны в `engine-patches/README.md` и `managed-engine.lock.json`. Соответствующие исходники включены в `artifacts/TorrServer-MatriX.145.2-mumpa4-source.zip`. Бинарники, выходные сборки и локальные журналы не добавляются в Git. Integration-тест создаёт оригинальную WAV, локальный tracker и BitTorrent-сидер, проверяет настоящий движок/декодер, избранное, HTTP Range, перемотку, полную загрузку по SHA-256, перезапуск движка и офлайн при выключенном движке/сидере. Три отмены потока без сидера дополнительно проверяют освобождение серверных читателей. Публичные музыкальные торренты тесту не нужны.

Для уже настроенного пользовательского RuTracker.org есть отдельная проверка `flutter test integration_test/real_source_test.dart -d windows --dart-define=REAL_SOURCE_TEST=true`: реальный поиск, загрузка метаинформации и открытие коллекции. Дополнительный флаг `--dart-define=REAL_PLAYBACK_TEST=true` проверяет доступность публичного swarm. `flutter test integration_test/favorites_test.dart -d windows --dart-define=REAL_FAVORITES_TEST=true` проверяет существующее избранное в отдельной библиотеке: настоящее воспроизведение либо завершение ожидания с доступной кнопкой повтора. Ключи и cookies в отчёт не записываются.

Флаг `--dart-define=REQUIRE_FAVORITES_PLAYBACK=true` делает проверку избранного строгой: хотя бы один настоящий трек должен открыться из HTTP-потока с ненулевой длительностью и продвижением позиции минимум на 2,5 секунды. Таймаут такую проверку проваливает. Для отдельного диагностического движка тест принимает `FAVORITES_SERVER_URL`, ограниченный `http://127.0.0.1`. Native fixture с `--dart-define=OUTGOING_PEER_TEST=true` дополнительно проверяет исходящий MSE → plaintext на локальном BitTorrent-сидере.
