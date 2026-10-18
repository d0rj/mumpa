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

После успешных проверок и сборки workflow автоматически публикует
**[GitHub Release](https://github.com/d0rj/mumpa/releases)** с тегом `v<version>`
(например, `v1.2.7`). ZIP и APK скачиваются из раздела **Assets** прямо в браузере.
Состав выпуска:

- Windows ZIP с приложением, помощниками и документацией;
- три Android APK;
- отдельный ZIP с символами Dart для диагностики Android;
- соответствующие исходники Mumpa, исправленного TorrServer, Jackett и FlareSolverr;
- `SHA256.json` для пакетов и `BUILD.json` с версией и commit.

Релиз сначала создаётся как draft: он публикуется только после загрузки всех
12 файлов и проверки их размеров/серверных SHA-256. `SHA256.json` в Releases
использует плоские имена Assets; в Actions Artifacts сохранён исходный layout
с папкой `sources`. `BUILD.json` содержит полный `version+build`, исходный commit,
номер workflow и тип Android-подписи.

Android собирается через `tools/build-android.ps1` с `--split-debug-info`, без
обфускации. `package-release.ps1` сохраняет все три соответствующих файла
`app.android-*.symbols` в `Mumpa-<version>-android-symbols.zip`; публикация требует
этот архив. Для разбора Android stack trace скачай символы именно этого выпуска
и выполни `flutter symbolize -i trace.txt -d app.android-arm64.symbols`
(для ARMv7 — `app.android-arm.symbols`, для x86_64 — `app.android-x64.symbols`).
[Документация Flutter](https://docs.flutter.dev/deployment/obfuscate).

Повторный запуск для того же commit проверяет существующий опубликованный
выпуск и сохраняет его файлы. Различия нового rebuild из-за времён архивов или
подписи не заменяют опубликованные байты. Незавершённый draft можно продолжить;
конфликт тега с другим commit или неполный опубликованный выпуск останавливает
публикацию. Для следующего выпуска увеличивай версию **до `+`** и Android build
number **после `+`** в `pubspec.yaml`.

Копия **Actions → Build release → Artifacts → Mumpa-<version>-<run-id>**
по-прежнему хранится 30 дней, coverage — 14 дней. Release assets не зависят от
этого срока хранения. Приватный репозиторий сохраняет прежний доступ к выпускам.

Проверки и сборка используют `contents: read`; только отдельный Linux publish
job получает `contents: write`. Он скачивает artifact по ID из текущей сборки,
сверяет полный version/commit/run ID и SHA-256 всех девяти ZIP/APK до обращения
к API публикации. Обычный push по-прежнему не запускает сборку или публикацию.

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
Релиз после слияния использует `pull_request_target: closed` с проверкой
`merged == true`, целевой ветки `main` и непустого merge SHA. Checkout выполняется
только для уже принятого merge commit, включая PR из fork; непроверенный PR head
не используется. Узкий opt-in checkout нужен закреплённому action, который иначе
отклоняет и fork merge SHA. Обычные PR-проверки остаются на `pull_request` без
секретов; signing secrets доступны только принятой релизной сборке или ручному
запуску. [Описание события GitHub](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target).
Инструкция по созданию своего ключа: [документация Flutter](https://docs.flutter.dev/deployment/android#sign-the-app).

## Воспроизводимость и стоимость

### Локальный выпуск без GitHub Actions

Готовые локальные ZIP/APK можно загрузить прямо в GitHub Releases: runner и
минуты Actions для этого не нужны. Установленный Mumpa использует те же
`BUILD.json`, `SHA256.json` и имена пакетов независимо от места сборки.

Сначала увеличь версию и build number, выполни локальные проверки и закоммить
все изменения. На Windows с Flutter, Go и Android SDK/NDK:

```powershell
pwsh -File tools/ci/build-release.ps1 -Local `
  -GoExecutable 'C:\Program Files\Go\bin\go.exe' `
  -AndroidNdk "$env:LOCALAPPDATA\Android\sdk\ndk\28.2.13676358"
git push origin main
node tools/publish-local-release.mjs
```

Сборка проверяет чистое дерево Git, пересобирает закреплённые движки,
Windows из `lib/main.dart` и три Android APK, проверяет установщик, прикладывает
исходники точного commit, символы и контрольные суммы. Результат сохраняется
в `artifacts/release-<version>`; прежние локальные версии и кэши очищаются
обычным `package-release.ps1`. Изменение исходников во время сборки запрещено.
Если NuGet отсутствует в `PATH`, локальная сборка скачивает официальный CLI
7.9.0, проверяет закреплённый SHA-256 и хранит его только в очищаемом `build/`.

Публикация требует, чтобы build commit оставался текущим `HEAD` и уже был
отправлен в ветку `origin`. `BUILD.json` указывает `buildSource: local` и
`githubRun: null`; описание ссылается на commit без вымышленного запуска CI.
Проверки SHA-256, draft до завершения всех 12 загрузок, восстановление
незавершённого draft и защита опубликованных версий общие с CI. Повторная
публикация той же версии/commit проверяет существующий выпуск.

Нужен локальный вход `gh auth login` с доступом к репозиторию. Публикатор
читает авторизацию через `gh` в память процесса и не записывает её в файлы.
Без release keystore используется `local-debug-key`: обновление Android
поверх ранее установленного APK возможно только при совпадении сертификата.
Debug-ключ локального компьютера обычно отличается от временного ключа
GitHub runner. Для постоянных обновлений настрой release signing, описанный выше.

### Локальное место на диске

`pwsh -File tools/package-release.ps1` сохраняет один полный выпуск в
`artifacts/release-<version>`; CI использует тот же скрипт с постоянной папкой
`artifacts/ci-release`. Упаковка идёт в отдельном временном каталоге. Только после
создания всех пяти ZIP/APK и проверки SHA-256 новый комплект заменяет прежний,
а более старые локальные выпуски удаляются. Исходники в `sources`, символы и
манифест нового выпуска сохраняются. Более новые версии при упаковке старой
версии не удаляются. Hosted GitHub Releases эта политика не меняет.

После успешной упаковки автоматически удаляются `build`, `.dart_tool` и
платформенные кэши этого checkout. Для последовательной отладки можно явно
указать `-KeepBuildCache`. Прямой вызов `flutter build` сохраняет текущий кэш до
следующей упаковки или ручной очистки.

Проверка плана без удаления и полная ручная уборка (PowerShell 7):

```powershell
pwsh -File tools/clean-workspace.ps1 -WhatIf
pwsh -File tools/clean-workspace.ps1
```

Переключатели `-BuildCaches`, `-Temporary`, `-Releases` выбирают отдельные
категории; без них выбраны все три. Запускай ручную очистку после завершения
сборок, приложения и эмулятора, использующих этот checkout. `-Temporary` удаляет
всю `.local`, включая AVD; постоянные данные там не хранятся. Если в любом
удаляемом дереве найдены `library.json`, его `.bak`/`.tmp` или Jackett
`ServerConfig.json`, очистка останавливается до первого удаления. Собственные
изолированные тестовые профили удаляет создавший их тест в `finally`.
Небольшие результаты проверок в `test-output` сохраняются, а скопированные
бинарники/архивы, незавершённые загрузки и инсталляционные fixtures удаляются.
Генерируемый `graphify-out` относится к кэшам. Профиль установленной программы и музыка
пользователя находятся вне списка очистки.

`build-managed-engine.ps1` удаляет свой `run-*` в `finally`, в том числе при
ошибке распаковки или компиляции. `-KeepWorkDirectory` оставляет его для явной
отладки. Инсталляционный тест также убирает fixtures в `finally`.
Проверки удаления, границ пути/junction, хэшей, порядка версий, сбоя упаковки и
повторной упаковки запускаются командой
`pwsh -File tools/test-workspace-maintenance.ps1` и в Windows CI.

### Toolchains и границы проверок

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

Логика публикации дополнительно проверяется командой
`node --test tools/ci/publish-release.test.mjs` (Node 22). Тесты используют
временные файлы и имитацию GitHub API: неполные/повреждённые пакеты, неверный
commit/run, отказ авторизации, частичная загрузка и повторная публикация.

GitHub описывает событие закрытия PR с проверкой `merged` и ручной запуск в
[справочнике событий Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).
