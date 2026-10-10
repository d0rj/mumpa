# GitHub CI и сборки

Вкладка **Actions → Checks** запускает форматирование Dart, `flutter analyze`,
unit/widget-тесты с coverage на Windows и Ubuntu, а также Go-регрессии
торрент-движка. Проверки запускаются при открытии и обновлении PR, повторном
открытии, переводе из draft и вручную. Авторизованный Jackett, RuTracker,
публичные музыкальные раздачи и пользовательская библиотека тестам не нужны.

**Actions → Build release → Run workflow** собирает Windows x64 и Android APK
для ARM64, ARMv7 и x86_64. Этот же workflow запускается после слияния PR в
`main`. Простое закрытие PR и обычный `git push` не запускают релизную сборку.
Перед сборкой проходят те же проверки на том же commit, который затем собирается.
Ручной запуск собирает выбранную в GitHub ветку или тег.

В завершённом запуске открой **Artifacts → Mumpa-<version>-<run-id>**. В архиве:

- Windows ZIP с приложением, помощниками и документацией;
- три Android APK;
- соответствующие исходники Mumpa, исправленного TorrServer, Jackett и FlareSolverr;
- `SHA256.json` для пакетов и `BUILD.json` с версией и commit.

Пакеты хранятся 30 дней, coverage — 14 дней. Сборка не создаёт автоматически
теги или публичные GitHub Releases. Для нового выпуска обнови `version` в
`pubspec.yaml`; Android требует увеличивать число после `+` для обновлений.

## Подпись Android

Без настроенных secrets APK собираются с временным debug-сертификатом runner.
Их можно установить для проверки, но обновление поверх APK с другим сертификатом
Android не разрешит. Для постоянной подписи добавь в **Settings → Secrets and
variables → Actions → Repository secrets** все четыре значения:

| Secret | Значение |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 содержимого своего JKS/keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль хранилища |
| `ANDROID_KEY_ALIAS` | Alias ключа |
| `ANDROID_KEY_PASSWORD` | Пароль ключа |

Приватный ключ не хранится в Git, кеше или артефактах. Workflow создаёт его
только во временной папке runner и удаляет в завершающем шаге. Частичная настройка
secrets останавливает сборку. Локальная сборка поддерживает те же три параметра
пароля/alias и `MUMPA_KEYSTORE_PATH` с путём к файлу вместо Base64.
GitHub не передаёт secrets workflow, запущенному PR из fork. После слияния такого
PR используй ручной запуск в основном репозитории для сборки с постоянной подписью.
Инструкция по созданию своего ключа: [документация Flutter](https://docs.flutter.dev/deployment/android#sign-the-app).

## Воспроизводимость и стоимость

Actions закреплены commit SHA; Flutter — 3.44.4, Java — 21, Go/NDK — по
`engine-patches/managed-engine.lock.json`. `pub get --enforce-lockfile`
запрещает незаметную замену зависимостей. Сборка движка сверяет исходники,
patch overlays и каждый бинарник с SHA-256 из lock-файла; CI не обновляет lock.
Зависимости Flutter, Go, Gradle и проверенные helper-архивы кешируются.
Полные нативные сборки выполняются последовательно в release job на Windows.
Для unit/widget-тестов отдельно создаётся Flutter bundle с настоящими шрифтами
и shaders, отфильтрованный по Android-платформе. Он не требует Windows-архивов
помощников. Анализ покрывает все Dart-файлы в `lib`, `test` и `integration_test`;
отсутствующие на чистом checkout release-архивы проверяются при нативной сборке.

CI не проверяет публичные пиры, VPN, Windows tray или физические медиакнопки.
Нативные интеграционные проверки и их границы описаны в [VALIDATION.md](VALIDATION.md).
Успешный unit suite не заменяет проверку готового приложения на устройстве.

GitHub описывает событие закрытия PR с проверкой `merged` и ручной запуск в
[справочнике событий Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).
