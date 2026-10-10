# Windows: медиакнопки, трей и панель задач

Mumpa 1.2.0 использует нативные Windows System Media Transport Controls для Play/Pause/Stop/Previous/Next. Кнопка «Продолжить/Пауза» на устройстве, которое передаёт стандартную медиакоманду Windows, управляет тем же плеером и очередью, что интерфейс приложения. Управление продолжает работать при скрытом окне. Дополнительно поддерживаются обычные оконные `WM_APPCOMMAND` медиакоманды.

Закрытие окна крестиком скрывает его в трей и сохраняет воспроизведение, загрузки и локальные помощники. Нажатие на иконку возвращает окно. Контекстное меню содержит открытие окна, воспроизведение/паузу, предыдущий/следующий трек и **«Выход»**. Кнопка «Завершить Mumpa» также есть в настройках. Выход сохраняет позицию/очередь, завершает загрузчик, плеер и управляемые помощники, затем закрывает процесс.

При наведении на кнопку Mumpa на панели задач Windows под превью окна доступны три кнопки: предыдущий трек, Play/Pause, следующий трек. Состояние и доступность синхронизируются с очередью. Для длинного текущего трека «Предыдущий» сначала возвращает его к началу, как кнопка в интерфейсе. Когда окно скрыто в трей, его нужно восстановить для превью панели задач.

Интеграция реализована в `windows/runner/windows_player_bridge.*` и `lib/data/windows_player_service.dart` без дополнительной службы, глобального перехвата клавиш или изменения сетевых настроек. Она включается только после готовности приложения; тестовые экземпляры могут работать с обычным закрытием окна.

Нативная проверка: `flutter test integration_test/windows_player_test.dart -d windows --no-pub`. Она создаёт изолированную медиатеку, передаёт настоящие оконные команды Play/Pause/Next и уведомления кнопок превью, проверяет создание SMTC/трея/кнопок, скрытие/возврат окна и продвижение позиции аудио в фоне. Конкретное физическое устройство этой проверкой не эмулируется.

Завершение WebView проверяется отдельным release-экземпляром с открытыми обычным и фоновым браузерами во временном профиле:

```powershell
flutter build windows --release --no-pub --target integration_test/fixtures/windows_browser_lifecycle.dart
python tools/check-windows-browser-exit.py --application D:\Projects\mumpa\build\windows\x64\runner\Release\mumpa.exe --evidence D:\Projects\mumpa\test-output\windows-browser-exit-1.2.0.json
flutter build windows --release --no-pub
```

Пути в команде нужно заменить на свой checkout. Проверка закрывает только созданный ею процесс и требует код выхода 0. Последняя команда возвращает обычную сборку приложения перед упаковкой. Исправление освобождения очереди WebView воспроизводимо применяется при сборке; описание и проверенные исходные хеши находятся в `windows/plugin_patches/README.md`.

Первичные API: [SMTC GetForWindow](https://learn.microsoft.com/en-us/windows/win32/api/systemmediatransportcontrolsinterop/nf-systemmediatransportcontrolsinterop-isystemmediatransportcontrolsinterop-getforwindow), [Thumbnail toolbar](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-itaskbarlist3-thumbbaraddbuttons), [Notification area](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area).
