const englishMessages = <String, String>{
  'Проверь наличие новой версии.': 'Check for a new version.',
  'Для этого устройства нет пакета обновления.':
      'No update package for this device.',
  'Некорректная версия выпуска.': 'Invalid release version.',
  'Опубликованный выпуск пока недоступен.':
      'The published release is not available yet.',
  'Сервер обновлений ответил HTTP {0}.': 'Update server returned HTTP {0}.',
  'Слишком большой файл сведений об обновлении.':
      'The update metadata file is too large.',
  'Приватный выпуск требует авторизации GitHub. На Windows используется gh auth login.':
      'Private releases require GitHub authentication. On Windows, use gh auth login.',
  'Нет доступа к приватному выпуску. Выполни gh auth login и повтори проверку.':
      'No access to the private release. Run gh auth login and check again.',
  'Для приватных выпусков установи GitHub CLI и выполни gh auth login.':
      'For private releases, install GitHub CLI and run gh auth login.',
  'Нет файлов приватного выпуска.': 'No private release assets.',
  'Файл приватного выпуска отсутствует.': 'Private release asset missing.',
  'Проверяем обновления…': 'Checking for updates…',
  'Приватный выпуск ещё не опубликован.':
      'The private release is not published yet.',
  'Некорректные сведения о выпуске.': 'Invalid release metadata.',
  'Версия приватного выпуска не совпадает с тегом.':
      'The private release version does not match the tag.',
  'Установлена актуальная версия.': 'You are up to date.',
  'Установленная версия новее опубликованной ({0}).':
      'The installed version is newer than the published release ({0}).',
  'Некорректные контрольные суммы.': 'Invalid checksums.',
  'Пакет устройства отсутствует в выпуске.':
      'The release has no package for this device.',
  'Некорректные размер или SHA-256 пакета.': 'Invalid package size or SHA-256.',
  'Обновление скачано и проверено. Можно установить.':
      'Update downloaded and verified. Ready to install.',
  'Доступна Mumpa {0} ({1} МБ).': 'Mumpa {0} is available ({1} MB).',
  'Не удалось проверить обновления.': 'Could not check for updates.',
  'Скачиваем обновление…': 'Downloading update…',
  'HTTP {0} при скачивании.': 'Download returned HTTP {0}.',
  'Размер скачиваемого пакета не совпадает.': 'Download package size mismatch.',
  'Загрузка отменена.': 'Download canceled.',
  'Пакет больше заявленного размера.': 'The package exceeds its declared size.',
  'Проверка SHA-256 или размера не прошла. Повтори скачивание.':
      'SHA-256 or size verification failed. Download again.',
  'Не удалось скачать обновление.': 'Could not download the update.',
  'Готовим установку…': 'Preparing installation…',
  'Пакет изменён. Скачай обновление снова.':
      'The package has changed. Download the update again.',
  'Подтверди установку в системном окне Android.':
      'Confirm installation in the Android system dialog.',
  'Установка не поддерживается.': 'Installation is not supported.',
  'Перезапускаем Mumpa для установки…': 'Restarting Mumpa to install…',
  'Не удалось установить обновление.': 'Could not install the update.',
  'Проверь подключение к интернету и повтори попытку.':
      'Check your internet connection and try again.',
  'Файл трека не найден на диске.': 'The track file was not found on disk.',
  'Загрузка: HTTP {0}.': 'Download: HTTP {0}.',
  'Сервер вернул неверный диапазон.':
      'The server returned an invalid byte range.',
  'Сервер передал больше данных, чем размер трека.':
      'The server sent more data than the track size.',
  'Файл получен не полностью. Можно продолжить загрузку.':
      'The file is incomplete. You can resume the download.',
  'Лимит офлайн-кеша достигнут. Увеличьте лимит в настройках или удалите скачанные треки.':
      'Offline storage limit reached. Increase the limit in settings or remove downloaded tracks.',
  'Сетевой интерфейс «{0}» недоступен. Подключите его или измените выбор в настройках Mumpa.':
      'Network interface “{0}” is unavailable. Connect it or change the selection in Mumpa settings.',
  'У выбранного интерфейса нет подходящего IPv4-адреса.':
      'The selected interface has no suitable IPv4 address.',
  'Топ-50 на этом устройстве': 'Top 50 on this device',
  '{0} КБ': '{0} KB',
  '{0} ГБ': '{0} GB',
  ' · {0} файлов': ' · {0} files',
  ' · {0} сидов': ' · {0} seeders',
  ' · Доступен офлайн': ' · Available offline',
  ' · Офлайн': ' · Offline',
  '+ Новый плейлист': '+ New playlist',
  '1 · по очереди': '1 · sequential',
  'FlareSolverr подключён · проверить': 'FlareSolverr connected · check',
  'FlareSolverr подключён. Повтори сохранение или проверку RuTracker.org в Jackett.':
      'FlareSolverr connected. Save or test RuTracker.org in Jackett again.',
  'Jackett · добавь RuTracker.org, затем закрой окно':
      'Jackett · add RuTracker.org, then close this window',
  'Jackett · дополнительный каталог': 'Jackett · additional catalog',
  'Jackett готов. Добавь индексатор RuTracker.org и сохрани настройки аккаунта.':
      'Jackett is ready. Add the RuTracker.org indexer and save your account settings.',
  'Jackett запущен, но окно настройки не открылось. Адрес: {0}':
      'Jackett started, but setup could not open. Address: {0}',
  'Jackett подключён. Поиск ограничен музыкальными раздачами.':
      'Jackett connected. Search is limited to music torrents.',
  'Knaben и RuTor · MP3 и FLAC · выбери альбом или найди исполнителя':
      'Knaben and RuTor · MP3 and FLAC · choose an album or find an artist',
  'ListenBrainz · по совместным прослушиваниям':
      'ListenBrainz · based on shared listening',
  'MP3, FLAC, M4A, OGG, WAV и другие': 'MP3, FLAC, M4A, OGG, WAV and more',
  'MusicBrainz · выбери альбом, чтобы найти его в источниках':
      'MusicBrainz · choose an album to find it in your sources',
  'MusicBrainz помогает сопоставлять исполнителей и альбомы. Cover Art Archive предоставляет обложки. Данные сохраняются на диске; при заполнении кеша удаляются самые старые записи.':
      'MusicBrainz matches artists and albums. Cover Art Archive provides artwork. Data is cached on disk; the oldest entries are removed when the cache is full.',
  'RuTracker и другие подключённые музыкальные трекеры':
      'RuTracker and other connected music trackers',
  'RuTracker напрямую': 'Direct RuTracker access',
  'RuTracker подключён через Jackett.': 'RuTracker connected through Jackett.',
  'magnet:?xt=urn:btih:… или https://…/album.torrent':
      'magnet:?xt=urn:btih:… or https://…/album.torrent',
  '{0} / {1} МБ': '{0} / {1} MB',
  '{0} · {1} альбомов в медиатеке': '{0} · {1} albums in your library',
  '{0} · {1} треков': '{0} · {1} tracks',
  '{0} · параллельно': '{0} · in parallel',
  '{0} МБ': '{0} MB',
  '{0} аудиофайлов · {1}': '{0} audio files · {1}',
  '{0} записей': '{0} entries',
  '{0} из {1} · {2} записей': '{0} of {1} · {2} entries',
  '{0} найдено': '{0} found',
  '{0} раздач': '{0} torrents',
  '{0} с': '{0} s',
  '{0} сидов': '{0} seeders',
  '{0} скачанных треков · {1}': '{0} downloaded tracks · {1}',
  '{0} треков': '{0} tracks',
  '{0} треков · {1} альбомов': '{0} tracks · {1} albums',
  '{0} треков · обновляется автоматически':
      '{0} tracks · updated automatically',
  '{0}Только треки, скачанные Mumpa. Добавленная с диска музыка не учитывается. Незавершённые загрузки также используют лимит.':
      '{0}Only tracks downloaded by Mumpa. Imported music is excluded. Partial downloads also count toward the limit.',
  '«Автоматически» ищет музыку в Knaben и RuTor без аккаунта, Jackett и FlareSolverr. Поисковые запросы отправляются этим каталогам. Наличие раздачи в поиске не гарантирует доступных пиров.':
      'Automatic searches Knaben and RuTor without an account, Jackett or FlareSolverr. Search queries are sent to these catalogs. A search result does not guarantee available peers.',
  '±12 дБ · Настройки полос сохраняются при отключении.':
      '±12 dB · Band settings are retained when disabled.',
  'АЛЬБОМ': 'ALBUM',
  'Автоматически': 'Automatic',
  'Автоматически сохранять торрент-треки для офлайн':
      'Automatically save torrent tracks for offline listening',
  'Автоскачивание, параллельные загрузки и лимит места':
      'Automatic downloads, parallel transfers and storage limit',
  'Адрес Jackett или URL Torznab API': 'Jackett address or Torznab API URL',
  'Альбом': 'Album',
  'Альбом / коллекция': 'Album / collection',
  'Альбом добавлен · {0} треков': 'Album added · {0} tracks',
  'Альбом удалён': 'Album removed',
  'Альбомы': 'Albums',
  'Альбомы · {0}': 'Albums · {0}',
  'Альбомы и дискографии': 'Albums and discographies',
  'Альбомы и коллекции': 'Albums and collections',
  'Аудиоданные получены, но воспроизведение не началось. Повтори попытку или выбери другой источник.':
      'Audio data received, but playback did not start. Try again or choose another source.',
  'Аудиофокус занят другим приложением.': 'Another app is using audio focus.',
  'Без звука': 'Mute',
  'Библиотека: {0}': 'Library: {0}',
  'Больше баса': 'Bass boost',
  'В Mumpa доступны музыкальные разделы RuTracker. Поиск по всему каталогу требует аккаунт RuTracker.':
      'Mumpa provides the music sections of RuTracker. Searching the entire catalog requires a RuTracker account.',
  'В коллекцию «{0}»': 'Go to collection “{0}”',
  'В конец очереди': 'Move to end of queue',
  'В локальной медиатеке пока ничего не найдено.':
      'Nothing found in your local library yet.',
  'В любимое': 'Add to favorites',
  'В любимом': 'In favorites',
  'В музыкальном каталоге': 'In the music catalog',
  'В очереди': 'In queue',
  'В плейлист': 'Add to playlist',
  'В подключённых источниках ничего не найдено. Проверь название или подключи другой музыкальный трекер.':
      'Nothing found in connected sources. Check the name or connect another music tracker.',
  'В проверенных коллекциях подходящих аудиофайлов не найдено. Попробуй поиск по альбому: база и имена файлов могут различаться.':
      'No matching audio files found in checked collections. Try searching for the album: database entries and filenames may differ.',
  'В твоей медиатеке': 'In your library',
  'В текущий плейлист «{0}»': 'Add to current playlist “{0}”',
  'В трекерах Jackett': 'In Jackett trackers',
  'В этой коллекции нет аудиотреков.': 'This collection has no audio tracks.',
  'В этом торренте нет поддерживаемых аудиофайлов.':
      'This torrent has no supported audio files.',
  'Введи название трека и исполнителя': 'Enter a track title and artist',
  'Версии «{0}»': 'Versions of “{0}”',
  'Версия по умолчанию': 'Default version',
  'Включи альбом или добавь треки через меню.':
      'Play an album or add tracks from the menu.',
  'Включи трек из каталога или выбери папку с локальной музыкой.':
      'Play a track from the catalog or choose a local music folder.',
  'Включи трек, добавь музыку или выбери другой фильтр.':
      'Play a track, add music or choose another filter.',
  'Включить звук': 'Unmute',
  'Внешний TorrServer (необязательно)': 'External TorrServer (optional)',
  'Войди в свой аккаунт для поиска исполнителей и альбомов.':
      'Sign in to search for artists and albums.',
  'Войти в RuTracker': 'Sign in to RuTracker',
  'Вокал': 'Vocal',
  'Воспроизведение': 'Playback',
  'Все альбомы': 'All albums',
  'Все треки': 'All tracks',
  'Все треки исполнителя': 'All tracks by this artist',
  'Все форматы': 'All formats',
  'Встроенный движок работает автоматически. Можно подключить свой TorrServer — например, на домашнем сервере.':
      'The built-in engine runs automatically. You can connect your own TorrServer, for example on a home server.',
  'Всё, что хочется слушать': 'Everything you want to hear',
  'Вход в RuTracker': 'RuTracker sign-in',
  'Выбери музыку': 'Choose your music',
  'Выбери первый трек': 'Choose your first track',
  'Выбери раздел, чтобы изменить нужные параметры.':
      'Choose a section to change its settings.',
  'Выбери свой первый трек': 'Choose your first track',
  'Выбери трек': 'Choose a track',
  'Выбери трек для поиска доступных версий':
      'Choose a track to find available versions',
  'Выбери формат и раздачу. Метки Clean и «без цензуры» взяты из описания версии.':
      'Choose a format and torrent. Clean and uncensored labels come from the version description.',
  'Выберите музыку': 'Choose music',
  'Выберите папку с альбомами': 'Choose a folder with albums',
  'Выбор Wi-Fi или Ethernet может отправлять торрент-трафик напрямую: трекеры и пиры увидят IP провайдера. Системный маршрут учитывает VPN. Настройка применяется после перезапуска Mumpa. Другой интерфейс не будет выбран автоматически.':
      'Choosing Wi-Fi or Ethernet may send torrent traffic directly: trackers and peers will see your ISP address. The system route respects your VPN. Restart Mumpa to apply changes. Another interface will not be selected automatically.',
  'Выбор среди уже известных версий того же трека. Если подходящей нет, скачивается выбранная версия. Файлы сохраняются без перекодирования; битрейт задаёт источник. Автокеш и предзагрузка сохраняют версию для воспроизведения.':
      'Selects among known versions of the same track. If none match, the selected version is downloaded. Files are saved without conversion; the source determines the bitrate. Automatic caching and preloading keep the playback version.',
  'Выбранная версия · оригинал': 'Selected version · original',
  'Выбрать версию': 'Choose version',
  'Выбрать всё': 'Select all',
  'Выбрать по умолчанию': 'Set as default',
  'Выйти': 'Sign out',
  'Выключить через 15 мин': 'Stop after 15 min',
  'Выключить через 30 мин': 'Stop after 30 min',
  'Выключить через час': 'Stop after one hour',
  'Выполнен вход: {0}': 'Signed in: {0}',
  'Выравнивать воспринимаемую громкость во время воспроизведения':
      'Balance perceived loudness during playback',
  'Высокие частоты': 'Treble boost',
  'Выше в очереди': 'Move up in queue',
  'Выше в плейлисте': 'Move up in playlist',
  'Где искать': 'Where to search',
  'Главная': 'Home',
  'Готовим продолжение · готово: {0}': 'Preparing more music · {0} ready',
  'Готово для офлайн': 'Ready offline',
  'Готовый каталог, RuTracker и дополнительные источники':
      'Built-in catalog, RuTracker and additional sources',
  'Громкость': 'Volume',
  'Группа': 'Band',
  'Данные будут добавлены к текущей медиатеке. Повторный импорт не создаёт дубликатов. Текущая очередь воспроизведения сохранится.':
      'Data will be added to your library. Repeated imports do not create duplicates. Your current playback queue is preserved.',
  'Движок, TorrServer и сетевой интерфейс':
      'Engine, TorrServer and network interface',
  'Действия с альбомом': 'Album actions',
  'Действия с версией': 'Version actions',
  'Действия с треком': 'Track actions',
  'Демо': 'Demo',
  'Дискография': 'Discography',
  'Длительность неизвестна': 'Unknown duration',
  'Длительность перехода: {0} с': 'Crossfade duration: {0} s',
  'Для поиска файлов треков подключи Jackett. Раздачи напрямую можно открыть в режиме «Альбомы и коллекции».':
      'Connect Jackett to find track files. Open torrents directly in Albums and collections mode.',
  'Для собственных трекеров и серверов': 'For your own trackers and servers',
  'До 50 треков по числу прослушиваний в Mumpa на этом устройстве. Статистика накапливается с этого обновления.':
      'Up to 50 tracks ranked by plays in Mumpa on this device. Statistics are collected from this update onward.',
  'Добавить {0} треков': 'Add {0} tracks',
  'Добавить альбом в любимое': 'Add album to favorites',
  'Добавить в очередь': 'Add to queue',
  'Добавить в плейлист': 'Add to playlist',
  'Добавить музыку': 'Add music',
  'Добавлено в «{0}»': 'Added to “{0}”',
  'Добавлено треков: {0}': 'Tracks added: {0}',
  'Добавляем альбом': 'Adding album',
  'Добавь RuTracker.org в Jackett и сохрани аккаунт. Можно использовать встроенный Jackett на Windows или подключить свой сервер Jackett/Prowlarr по адресу и API key.':
      'Add RuTracker.org to Jackett and save your account. Use the built-in Jackett on Windows or connect a Jackett/Prowlarr server using its address and API key.',
  'Добавь первые треки': 'Add your first tracks',
  'Дополнительно: свой Jackett / Prowlarr':
      'Advanced: your own Jackett / Prowlarr',
  'Доступен офлайн': 'Available offline',
  'Если Jackett сообщает Empty cookies returned by FlareSolverr, выбери «Автоматически» или войди в RuTracker напрямую ниже. Для поиска через Mumpa не нужно настраивать cookies вручную.':
      'If Jackett reports Empty cookies returned by FlareSolverr, choose Automatic or sign in to RuTracker directly below. Searching through Mumpa does not require manual cookie setup.',
  'Если текст песни записан в тегах файла, он появится здесь. Для торрент-трека теги читаются после полной загрузки.':
      'Lyrics embedded in file tags appear here. Torrent track tags are read after the download completes.',
  'Есть несколько похожих названий. Уточни запрос:':
      'Several similar names found. Refine your search:',
  'Жанры RuTracker': 'RuTracker genres',
  'Ждём соединения с пирами · подключено: 0 · {0}/{1} с':
      'Waiting for peers · connected: 0 · {0}/{1} s',
  'Завершить Mumpa': 'Quit Mumpa',
  'Загружать следующие треки заранее': 'Preload upcoming tracks',
  'Загрузи каталог музыки': 'Load the music catalog',
  'Загрузить каталог': 'Load catalog',
  'Загрузки': 'Downloads',
  'Загрузки и офлайн': 'Downloads and offline',
  'Закрыть': 'Close',
  'Закрыть плеер': 'Close player',
  'Закрыть уведомление': 'Dismiss notification',
  'Запускаем Jackett…': 'Starting Jackett…',
  'Запускаем воспроизведение…': 'Starting playback…',
  'Запусти Jackett, добавь RuTracker.org и укажи свой аккаунт. После этого здесь появятся реальные музыкальные раздачи.':
      'Start Jackett, add RuTracker.org and enter your account details. Music torrents will then appear here.',
  'Запустить Jackett и настроить RuTracker':
      'Start Jackett and set up RuTracker',
  'Здесь пока тихо': 'Nothing playing yet',
  'Зеркало RuTracker': 'RuTracker mirror',
  'ИСПОЛНИТЕЛЬ': 'ARTIST',
  'Избранное и настройки сохраняются отдельно от приложения. Резервные копии за последние 7 дней находятся в подпапке backups. Обновление и очистка кеша сохраняют эти данные.':
      'Favorites and settings are stored separately from the app. Backups for the last 7 days are in the backups folder. Updates and cache cleanup preserve this data.',
  'Импорт на Android сохраняет копии в приватной папке приложения.':
      'Android imports save copies in the private app folder.',
  'Импорт объединяет данные с текущей медиатекой. Существующие треки, локальные файлы и порядок в плейлистах сохраняются. Перед импортом автоматически создаётся резервная копия профиля.':
      'Import merges data into your library. Existing tracks, local files and playlist order are preserved. A profile backup is created automatically before importing.',
  'Импорт: {0} из {1}': 'Importing: {0} of {1}',
  'Импортировать': 'Import',
  'Импортировать все аудиофайлы из папки':
      'Import all audio files from a folder',
  'Импортировать профиль': 'Import profile',
  'Импортировать профиль Mumpa': 'Import Mumpa profile',
  'Импортировать профиль?': 'Import profile?',
  'Импортируем профиль…': 'Importing profile…',
  'Интерфейс встроенного торрент-движка': 'Built-in torrent engine interface',
  'Искать музыку': 'Search music',
  'Искать на RuTracker': 'Search RuTracker',
  'Искать треки': 'Search tracks',
  'Искать через Jackett': 'Search through Jackett',
  'Исполнители': 'Artists',
  'Исполнитель': 'Artist',
  'Исполнитель {0}': 'Artist {0}',
  'Исполнитель пока не найден в MusicBrainz.':
      'Artist not found in MusicBrainz yet.',
  'Использовать Jackett для поиска': 'Use Jackett for search',
  'Источник не ответил вовремя. Попробуй другую раздачу или повтори запрос.':
      'The source did not respond in time. Try another torrent or repeat the search.',
  'Источники музыки': 'Music sources',
  'Ищем запись в MusicBrainz, затем проверяем файлы в раздачах твоего источника.':
      'Finding the recording in MusicBrainz, then checking files in torrents from your source.',
  'Ищем пиров и ждём первые аудиоданные…':
      'Finding peers and waiting for the first audio data…',
  'Ищем…': 'Searching…',
  'КОЛЛЕКЦИЯ': 'COLLECTION',
  'Каталог RuTracker · выбери жанр или найди исполнителя':
      'RuTracker catalog · choose a genre or find an artist',
  'Качество скачивания': 'Download quality',
  'Кеш обложек и метаданных очищен.': 'Artwork and metadata cache cleared.',
  'Кнопки мультимедиа, панель задач и работа в трее':
      'Media keys, taskbar and system tray',
  'Коллекция': 'Collection',
  'Конец трека затихает, пока начинается следующий':
      'Fade out the current track as the next one starts',
  'Крестик скрывает Mumpa в трее, и музыка продолжает играть. Нажми значок в трее, чтобы вернуть окно. Кнопки на колонках и под превью на панели задач управляют плеером.':
      'Closing the window hides Mumpa in the system tray and keeps music playing. Click the tray icon to restore it. Speaker buttons and taskbar preview controls operate the player.',
  'ЛОКАЛЬНЫЙ ФАЙЛ': 'LOCAL FILE',
  'Лайкнутые и скачанные треки не удаляются автоматически или при удалении альбома. Офлайн-копию можно удалить только вручную с подтверждением. Лимит места останавливает новые загрузки, сохраняя существующие файлы.':
      'Liked and downloaded tracks are kept when an album is removed. Offline copies can only be deleted manually with confirmation. The storage limit stops new downloads and preserves existing files.',
  'Лайкнутые и скачанные треки, избранные альбомы и треки избранных плейлистов останутся в библиотеке. Исходные музыкальные файлы сохранятся.':
      'Liked and downloaded tracks, favorite albums and tracks from favorite playlists stay in your library. Original music files are preserved.',
  'Лимит кеша обложек и метаданных': 'Artwork and metadata cache limit',
  'Лимит офлайн-загрузок, МБ': 'Offline download limit, MB',
  'Лицензии компонентов': 'Component licenses',
  'Локальный файл': 'Local file',
  'Локальных треков без аудиофайлов: {0}. Для прослушивания потребуется отдельно добавить музыку.':
      'Local tracks without audio files: {0}. Add the music files separately to play them.',
  'Любимое': 'Favorites',
  'Любимые альбомы': 'Favorite albums',
  'Любимые по числу прослушиваний': 'Favorites by play count',
  'Любимые треки': 'Liked songs',
  'Любимый трек': 'Liked song',
  'Любимых треков пока нет': 'No liked songs yet',
  'МУЗЫКА В ТВОЁМ РИТМЕ': 'MUSIC AT YOUR PACE',
  'МУЗЫКА ВСЕГДА РЯДОМ': 'MUSIC ALWAYS WITH YOU',
  'Медиатека': 'Library',
  'Место для метаданных и обложек, очистка кеша':
      'Artwork and metadata storage, cache cleanup',
  'Метаданные: MusicBrainz · обложки: Cover Art Archive':
      'Metadata: MusicBrainz · artwork: Cover Art Archive',
  'Можно указать сейчас; теги прочитаются после скачивания':
      'You can enter it now; tags are read after downloading',
  'Монозвук': 'Mono audio',
  'Моя музыка с диска': 'My local music',
  'Музыка': 'Music',
  'Музыка без настройки': 'Music without setup',
  'Музыка всегда рядом': 'Music always with you',
  'Музыка и обложки в файл не входят. Торрент-треки можно скачать заново при наличии пиров. Для локальной музыки сохраняются названия и избранное; сами файлы нужно перенести отдельно. Адреса серверов, сетевой интерфейс, пароли и данные входа на новом устройстве настраиваются отдельно.':
      'Music and artwork are not included. Torrent tracks can be downloaded again when peers are available. Local music titles and favorites are retained; transfer the files separately. Configure server addresses, network interface, passwords and sign-in on the new device.',
  'Музыка из твоих файлов и источников.\nДемо Mumpa Sessions — оригинальные синтезированные фрагменты.\nFlutter · media_kit · TorrServer MatriX.145.2':
      'Music from your files and sources.\nMumpa Sessions demos are original synthesized samples.\nFlutter · media_kit · TorrServer MatriX.145.2',
  'Музыка сразу после установки': 'Music from the first launch',
  'Музыка через Jackett': 'Music through Jackett',
  'Музыкальная база сейчас недоступна.':
      'The music database is currently unavailable.',
  'Музыкальные раздачи RuTracker': 'RuTracker music torrents',
  'Музыкальные файлы': 'Music files',
  'Музыкальных раздач пока нет': 'No music torrents yet',
  'НА ЭТОМ УСТРОЙСТВЕ': 'ON THIS DEVICE',
  'НАСТРОЙКИ': 'SETTINGS',
  'На RuTracker': 'On RuTracker',
  'На паузе': 'Paused',
  'На этом устройстве': 'On this device',
  'Нажми «Искать», чтобы найти альбомы в каталоге.':
      'Press Search to find albums in the catalog.',
  'Нажми на сердечко или добавь музыку через меню трека.':
      'Tap the heart or add music from the track menu.',
  'Нажми сердечко у трека, чтобы сохранить его здесь.':
      'Tap a track’s heart to save it here.',
  'Назад': 'Back',
  'Назад к жанрам': 'Back to genres',
  'Название': 'Title',
  'Название плейлиста': 'Playlist name',
  'Найдено: {0}': 'Found: {0}',
  'Найдено: {0} из {1}': 'Found: {0} of {1}',
  'Найди его альбом в подключённых источниках или добавь локальные файлы.':
      'Find their album in connected sources or add local files.',
  'Найди свой звук': 'Find your sound',
  'Найти в источниках': 'Find in sources',
  'Настраиваем проверку Cloudflare…': 'Setting up Cloudflare verification…',
  'Настроить FlareSolverr для Cloudflare': 'Set up FlareSolverr for Cloudflare',
  'Настроить Jackett и RuTracker': 'Set up Jackett and RuTracker',
  'Настроить RuTracker.org': 'Set up RuTracker.org',
  'Настроить трекеры': 'Set up trackers',
  'Настрой Jackett: добавь RuTracker и войди в свой аккаунт. На Windows можно запустить Jackett из Mumpa.':
      'Set up Jackett: add RuTracker and sign in. On Windows you can start Jackett from Mumpa.',
  'Настрой баланс низких, средних и высоких частот':
      'Adjust bass, mids and treble',
  'Настройки': 'Settings',
  'Настройки поиска': 'Search settings',
  'Начни вводить запрос': 'Start typing to search',
  'Начни слушать — топ соберётся автоматически':
      'Start listening to build your top tracks',
  'Не удалось дождаться аудиоданных. Повтори попытку или выбери другой источник.':
      'Timed out waiting for audio data. Try again or choose another source.',
  'Не удалось завершить Mumpa. Попробуй ещё раз.':
      'Could not quit Mumpa. Try again.',
  'Не удалось загрузить RuTracker. Проверь соединение и повтори попытку.':
      'Could not load RuTracker. Check your connection and try again.',
  'Не удалось запустить воспроизведение. Повтори попытку или выбери другой источник.':
      'Could not start playback. Try again or choose another source.',
  'Не удалось изменить размер кеша.': 'Could not change the cache size.',
  'Не удалось найти версии трека.': 'Could not find track versions.',
  'Не удалось открыть альбом за минуту. Проверь источник или выбери другую раздачу.':
      'The album did not open within a minute. Check the source or choose another torrent.',
  'Не удалось открыть расположение трека в проводнике.':
      'Could not show the track in the file manager.',
  'Не удалось очистить кеш.': 'Could not clear the cache.',
  'Не удалось подготовить продолжение': 'Could not prepare more music',
  'Не удалось применить настройки звука. Попробуй ещё раз.':
      'Could not apply audio settings. Try again.',
  'Не удалось прочитать размер загрузок': 'Could not read download size',
  'Не удалось прочитать сетевые интерфейсы: {0}':
      'Could not read network interfaces: {0}',
  'Недавно добавленные': 'Recently added',
  'Недавно слушал': 'Recently played',
  'Нет версий выбранного формата. Измени фильтр в настройках поиска.':
      'No versions in the selected format. Change the search format filter.',
  'Нет соединения с пирами: раздача не передаёт аудиоданные. Повтори попытку, проверь поддержку P2P у VPN или выбери другой источник.':
      'No peers connected: the torrent is not sending audio data. Try again, check whether your VPN supports P2P or choose another source.',
  'Ниже в очереди': 'Move down in queue',
  'Ниже в плейлисте': 'Move down in playlist',
  'Ничего не найдено': 'Nothing found',
  'Ничего не найдено в этом разделе': 'Nothing found in this section',
  'Ничего не найдено у этого исполнителя': 'Nothing found for this artist',
  'Новый плейлист': 'New playlist',
  'Новых доступных треков пока нет': 'No new tracks available yet',
  'О приложении': 'About',
  'Об исполнителе': 'About the artist',
  'Обложки и кеш': 'Artwork and cache',
  'Обложки и музыкальные метаданные': 'Artwork and music metadata',
  'Обновить': 'Refresh',
  'Обновить каталог': 'Refresh catalog',
  'Обновить раздачи': 'Refresh torrents',
  'Обновить размер': 'Refresh size',
  'Обновить размер загрузок': 'Refresh download size',
  'Обновить список интерфейсов': 'Refresh interfaces',
  'Обновления Mumpa': 'Mumpa updates',
  'Обновления, лицензии и расположение медиатеки':
      'Updates, licenses and library location',
  'Общий поиск': 'Global search',
  'Общий поиск: треки, альбомы, исполнители':
      'Search tracks, albums and artists',
  'Одинаковая громкость треков': 'Normalize volume',
  'Одновременные загрузки треков': 'Simultaneous track downloads',
  'Оркестр': 'Orchestra',
  'Отключено': 'Off',
  'Отключить таймер': 'Turn off timer',
  'Открой другой альбом в медиатеке.': 'Open another album in your library.',
  'Открой новую музыку': 'Discover new music',
  'Открой торрент-альбом и нажми «Скачать альбом». Завершённые загрузки играют без сети.':
      'Open a torrent album and press Download album. Completed downloads play offline.',
  'Открываем альбом…': 'Opening album…',
  'Открываем выбранную версию…': 'Opening selected version…',
  'Открываем коллекцию…': 'Opening collection…',
  'Открытие альбома отменено.': 'Opening the album was canceled.',
  'Открыть RuTracker': 'Open RuTracker',
  'Открыть альбом {0}': 'Open album {0}',
  'Открыть всё': 'Open all',
  'Открыть коллекцию': 'Open collection',
  'Открыть коллекцию и слушать без полной загрузки':
      'Open the collection and stream without downloading it all',
  'Открыть плейлист «{0}»': 'Open playlist “{0}”',
  'Открыть сайт': 'Open website',
  'Открыть торрент': 'Open torrent',
  'Отмена': 'Cancel',
  'Отменить': 'Cancel',
  'Отменить загрузку': 'Cancel download',
  'Офлайн': 'Offline',
  'Офлайн и кеш': 'Offline and cache',
  'Очередь': 'Queue',
  'Очередь пуста': 'The queue is empty',
  'Очистить кеш': 'Clear cache',
  'Очистить общий поиск': 'Clear global search',
  'Очистить поиск': 'Clear search',
  'Очистить поиск в разделе': 'Clear section search',
  'Ошибка загрузки': 'Download failed',
  'ПЛЕЙЛИСТ': 'PLAYLIST',
  'ПЛЕЙЛИСТЫ': 'PLAYLISTS',
  'Папка загрузок: {0}': 'Download folder: {0}',
  'Папка с альбомами': 'Album folder',
  'Папка с музыкой': 'Music folder',
  'Пауза': 'Pause',
  'Перезапуск недоступен. Заверши Mumpa и повтори установку.':
      'Restart unavailable. Quit Mumpa and try installing again.',
  'Переименовать': 'Rename',
  'Перейти к альбому': 'Go to album',
  'Перейти к исполнителю': 'Go to artist',
  'Переместить трек': 'Move track',
  'Перемешать': 'Shuffle',
  'Перенести настройки плеера': 'Import player settings',
  'Перенос профиля': 'Profile transfer',
  'Плавные переходы': 'Crossfade',
  'Плеер': 'Player',
  'Плеер в Windows': 'Windows player',
  'Плейлист': 'Playlist',
  'Плейлисты': 'Playlists',
  'Плейлисты и коллекции': 'Playlists and collections',
  'Плейлисты и коллекции по числу прослушиваний треков':
      'Playlists and collections by track plays',
  'По запросу «{0}» ничего не найдено. Показаны результаты для «{1}».':
      'No results for “{0}”. Showing results for “{1}”.',
  'По исполнителю': 'By artist',
  'По исходному запросу ничего не найдено. Проверяем «{0}»…':
      'No results for the original query. Checking “{0}”…',
  'По названию': 'By title',
  'По умолчанию 3 следующих незагруженных трека из текущей очереди. Офлайн-копии пропускаются. При паузе подготовка приостанавливается; готовые файлы сохраняются.':
      'Preloads 3 upcoming tracks by default. Offline copies are skipped. Pausing playback pauses preloading; completed files are kept.',
  'По умолчанию 3. Прослушиваемый трек получает место в очереди первым. Пауза сохраняет загруженную часть файла.':
      'Default: 3. The playing track gets the first available slot. Pausing keeps the downloaded portion.',
  'Повтор выключен': 'Repeat off',
  'Повтор очереди': 'Repeat queue',
  'Повтор трека': 'Repeat track',
  'Повторить': 'Retry',
  'Повторить загрузку': 'Retry download',
  'Подбирать треки тех же и похожих исполнителей':
      'Find tracks by the same and similar artists',
  'Подключаем раздачу…': 'Connecting to torrent…',
  'Подключи Jackett с RuTracker на ПК или сервере: укажи его адрес и API key в настройках.':
      'Connect Jackett with RuTracker on a PC or server: enter its address and API key in settings.',
  'Подключи музыкальный каталог': 'Connect a music catalog',
  'Подключить FlareSolverr': 'Connect FlareSolverr',
  'Подключить Jackett': 'Connect Jackett',
  'Подключён RuTracker.RU. Это другой сайт, чем RuTracker.org. Для каталога RuTracker.org добавь именно этот индексатор в Jackett и войди в свой аккаунт.':
      'RuTracker.RU is connected. It is a different site from RuTracker.org. Add the RuTracker.org indexer to Jackett and sign in to use that catalog.',
  'Подключён: {0}': 'Connected: {0}',
  'Подсчитываем скачанные треки…': 'Calculating downloaded tracks…',
  'Позиция воспроизведения': 'Playback position',
  'Поиск': 'Search',
  'Поиск MusicBrainz недоступен.': 'MusicBrainz search unavailable.',
  'Поиск в альбоме': 'Search album',
  'Поиск в коллекции': 'Search collection',
  'Поиск в любимом: треки, альбомы, плейлисты':
      'Search favorites: tracks, albums, playlists',
  'Поиск в медиатеке: исполнитель, альбом, трек':
      'Search library: artist, album, track',
  'Поиск в офлайн-музыке и загрузках': 'Search offline music and downloads',
  'Поиск в плейлисте': 'Search playlist',
  'Поиск версий занял больше двух минут.':
      'Version search took more than two minutes.',
  'Поиск версий занял больше двух минут. Уже найденные варианты доступны.':
      'Version search took more than two minutes. Versions already found are available.',
  'Поиск продолжения временно недоступен':
      'Finding more music is temporarily unavailable',
  'Поиск у исполнителя: альбом или трек': 'Search artist: album or track',
  'Пока нет треков этого исполнителя': 'No tracks by this artist yet',
  'Показать в проводнике': 'Show in file manager',
  'Показать ещё': 'Show more',
  'Получаем torrent-файл из {0}…': 'Fetching torrent file from {0}…',
  'Получаем аудиоданные · пиров: {0} · {1}/с':
      'Receiving audio · peers: {0} · {1}/s',
  'Получаем файлы альбома…': 'Fetching album files…',
  'Попробуй другое название трека, альбома или исполнителя.':
      'Try another track, album or artist name.',
  'Попробуй другой запрос или очисти поиск.':
      'Try another query or clear the search.',
  'Попробуй поискать исполнителя или альбом. Каталог доступен без аккаунта; доступность музыки зависит от пиров.':
      'Try searching for an artist or album. The catalog needs no account; music availability depends on peers.',
  'Порядок трека': 'Track order',
  'Поток недоступен. Проверьте подключение и наличие сидов; можно выбрать другой источник.':
      'Stream unavailable. Check your connection and seeders, or choose another source.',
  'Похожие исполнители': 'Similar artists',
  'Похожие исполнители после окончания очереди':
      'Similar artists after the queue ends',
  'Предпочитать lossless': 'Prefer lossless',
  'Предпочитать компактный формат': 'Prefer compact format',
  'Предыдущий трек': 'Previous track',
  'Пресет': 'Preset',
  'При автоматическом переходе к следующему готовому треку. Если файл ещё загружается, играет обычный переход. Повтор одного трека сохраняется.':
      'Used when advancing automatically to the next ready track. If the file is still loading, playback advances normally. Repeat-one keeps its usual behavior.',
  'Приостановить': 'Pause',
  'Приостановлено · {0}': 'Paused · {0}',
  'Проверить движок': 'Check engine',
  'Проверить обновления': 'Check for updates',
  'Проверка доступа к RuTracker': 'Checking RuTracker access',
  'Проверяем Jackett…': 'Checking Jackett…',
  'Проверяем RuTracker в Jackett': 'Checking RuTracker in Jackett',
  'Проверяем торрент-движок': 'Checking torrent engine',
  'Проверять обновления при запуске': 'Check for updates at startup',
  'Продолжать музыку после очереди': 'Keep playing after the queue ends',
  'Продолжение готово · треков: {0}': 'More music ready · {0} tracks',
  'Продолжить': 'Resume',
  'Прослушиваний треков: {0}': 'Track plays: {0}',
  'Профиль импортирован: {0} любимых треков, {1} плейлистов. Данные объединены с медиатекой.':
      'Profile imported: {0} liked songs, {1} playlists. Data merged into your library.',
  'Профиль на другом устройстве': 'Profile on another device',
  'Профиль сохранён. Перенеси файл на другое устройство и импортируй его в Mumpa.':
      'Profile saved. Transfer the file to another device and import it in Mumpa.',
  'Прямой доступ к RuTracker': 'Direct RuTracker access',
  'Публичные релизы скачиваются без авторизации. Для приватных релизов используется вход в GitHub CLI этого пользователя.':
      'Public releases download without authentication. Private releases use this user’s GitHub CLI sign-in.',
  'Радио после плейлиста': 'Radio after playlist',
  'Ровный': 'Flat',
  'Рок': 'Rock',
  'Русский': 'Русский',
  'С тобой без интернета': 'With you offline',
  'СЕЙЧАС ИГРАЕТ': 'NOW PLAYING',
  'Сбросить поиск': 'Reset search',
  'Сбросить эквалайзер': 'Reset equalizer',
  'Свой': 'Custom',
  'Сделай Mumpa своей': 'Make Mumpa yours',
  'Сейчас играет': 'Now playing',
  'Сердечко у трека, альбома, плейлиста или коллекции добавит их сюда.':
      'Tap the heart on a track, album, playlist or collection to add it here.',
  'Сетевой интерфейс сохранён. Перезапустите Mumpa для применения.':
      'Network interface saved. Restart Mumpa to apply it.',
  'Сиды неизвестны': 'Unknown seeders',
  'Системный маршрут (по умолчанию)': 'System route (default)',
  'Скачанные треки': 'Downloaded tracks',
  'Скачанные треки: {0} из {1} · {2}%': 'Downloaded tracks: {0} of {1} · {2}%',
  'Скачать альбом': 'Download album',
  'Скачать для офлайн': 'Download for offline',
  'Скачать коллекцию': 'Download collection',
  'Скачать обновление': 'Download update',
  'Скачиваем': 'Downloading',
  'Скачивать прослушиваемые треки': 'Download tracks while listening',
  'Скопировать название': 'Copy title',
  'Следующие треки готовятся заранее. Недоступные раздачи пропускаются. Исходный плейлист сохраняется; повтор и таймер сна имеют приоритет.':
      'Upcoming tracks are prepared in advance. Unavailable torrents are skipped. Your original playlist is preserved; repeat and the sleep timer take priority.',
  'Следующий трек': 'Next track',
  'Слушай музыку в Mumpa — самые частые треки появятся здесь автоматически.':
      'Listen in Mumpa and your most played tracks will appear here automatically.',
  'Слушать': 'Play',
  'Слушать {0}': 'Play {0}',
  'Слушать альбом': 'Play album',
  'Слушать без Jackett': 'Play without Jackett',
  'Слушать любимые треки исполнителя': 'Play liked songs by this artist',
  'Слушать следующим': 'Play next',
  'Слушать эту версию': 'Play this version',
  'Смешивать левый и правый каналы в обоих наушниках':
      'Mix left and right channels into both headphones',
  'Снова объединять похожие версии': 'Group similar versions again',
  'Снять всё': 'Deselect all',
  'Собери свою коллекцию из локальных альбомов и торрент-ссылок.':
      'Build your collection from local albums and torrent links.',
  'Создать': 'Create',
  'Сортировка': 'Sort',
  'Сохрани музыку в любимое': 'Save music to favorites',
  'Сохрани музыку для дороги': 'Save music for the road',
  'Сохрани профиль в файл и открой его в Mumpa на другом устройстве. В файл попадут любимые треки, альбомы, плейлисты и их порядок, метаданные и источники музыки, история, статистика, выбранные версии треков, очередь и настройки плеера.':
      'Save your profile to a file and open it in Mumpa on another device. It includes liked songs, albums, playlists and their order, metadata, music sources, history, statistics, preferred track versions, queue and player settings.',
  'Сохранить': 'Save',
  'Сохранить и проверить': 'Save and check',
  'Сохранить и проверить подключение': 'Save and test connection',
  'Сохранить лимит': 'Save limit',
  'Сохранить профиль Mumpa': 'Save Mumpa profile',
  'Сохраняем настройки загрузок': 'Saving download settings',
  'Сохраняем профиль…': 'Saving profile…',
  'Сохраняем сетевой интерфейс': 'Saving network interface',
  'Сохраняется для офлайн': 'Saving for offline',
  'Сохранённая очередь восстановится, если текущая пуста.':
      'The saved queue is restored if the current queue is empty.',
  'Список файлов раздачи изменился. Повтори поиск версий.':
      'The torrent file list has changed. Search for versions again.',
  'ТВОИ ФАЙЛЫ. ТВОЙ РИТМ.': 'YOUR FILES. YOUR RHYTHM.',
  'ТВОЯ КОЛЛЕКЦИЯ': 'YOUR COLLECTION',
  'ТОРРЕНТ-ПОТОК': 'TORRENT STREAM',
  'Таймер сна': 'Sleep timer',
  'Также известен как: {0}': 'Also known as: {0}',
  'Также проверили «{0}»: раздачи не найдены.':
      'Also checked “{0}”: no torrents found.',
  'Твои альбомы': 'Your albums',
  'Твой топ на устройстве': 'Your top tracks on this device',
  'Твой топ пока пуст': 'Your top tracks are empty',
  'Твоя медиатека': 'Your library',
  'Твоя медиатека и готовый музыкальный каталог':
      'Your library and the built-in music catalog',
  'Твоя медиатека и музыкальные трекеры Jackett':
      'Your library and Jackett music trackers',
  'Твоя медиатека и музыкальный каталог RuTracker':
      'Your library and the RuTracker music catalog',
  'Твоя музыка всегда рядом': 'Your music is always with you',
  'Текст': 'Lyrics',
  'Текст песни': 'Lyrics',
  'Текста пока нет': 'No lyrics yet',
  'Только уже известные файлы. Совпадение по метаданным; аудио не сравнивалось. Звёздочка запоминает версию для play на обложке. Без выбора приоритет у офлайн-копии.':
      'Only known files. Matched by metadata; audio has not been compared. The star saves the version used by the cover Play button. Offline copies take priority unless you choose a version.',
  'Торрент и сеть': 'Torrent and network',
  'Торрент-движок': 'Torrent engine',
  'Торрент-движок готов: {0}': 'Torrent engine ready: {0}',
  'Торренты': 'Torrents',
  'Трек добавлен в очередь.': 'Track added to queue.',
  'Трек отсутствует в коллекции.': 'Track missing from collection.',
  'Трек сохранится в библиотеке и избранном, но для прослушивания потребуется сеть.':
      'The track stays in your library and favorites, but playback will require a network connection.',
  'Треки': 'Tracks',
  'Треки в MusicBrainz': 'Tracks in MusicBrainz',
  'Треки в твоей медиатеке': 'Tracks in your library',
  'Треки из каталога': 'Catalog tracks',
  'Треки из торрента': 'Torrent tracks',
  'Треки не найдены. Попробуй добавить имя исполнителя или поискать альбом в источниках.':
      'No tracks found. Try adding the artist name or searching for the album in your sources.',
  'Треки, альбомы, плейлисты и коллекции, к которым хочется возвращаться':
      'Tracks, albums, playlists and collections you keep coming back to',
  'Треков: {0}\nЛюбимых треков: {1}\nЛюбимых альбомов: {2}\nПлейлистов и коллекций: {3}':
      'Tracks: {0}\nLiked songs: {1}\nFavorite albums: {2}\nPlaylists and collections: {3}',
  'Убедись, что RuTracker.org добавлен и проверка трекера в Jackett проходит. Можно также поискать исполнителя по имени.':
      'Make sure RuTracker.org is added and passes its Jackett test. You can also search by artist name.',
  'Убрать': 'Remove',
  'Убрать альбом из любимого': 'Remove album from favorites',
  'Убрать альбом из медиатеки?': 'Remove album from library?',
  'Убрать из любимого': 'Remove from favorites',
  'Убрать из медиатеки': 'Remove from library',
  'Убрать из очереди': 'Remove from queue',
  'Убрать из плейлиста': 'Remove from playlist',
  'Удалить копию': 'Delete copy',
  'Удалить офлайн-копию': 'Delete offline copy',
  'Удалить офлайн-копию?': 'Delete offline copy?',
  'Удалить плейлист': 'Delete playlist',
  'Узнаём исполнителя': 'Looking up artist',
  'Укажи URL Torznab и API key Jackett на ПК или сервере. Для телефона нужен доступный сетевой адрес.':
      'Enter the Torznab URL and Jackett API key for your PC or server. A phone needs a reachable network address.',
  'Укажи корректный HTTP/HTTPS адрес Jackett.':
      'Enter a valid HTTP/HTTPS Jackett address.',
  'Укажите корректный HTTP/HTTPS URL.': 'Enter a valid HTTP/HTTPS URL.',
  'Управление через Windows сейчас недоступно.':
      'Windows controls are currently unavailable.',
  'Установить и перезапустить': 'Install and restart',
  'Установить обновление': 'Install update',
  'Установка завершит воспроизведение и перезапустит Mumpa. Медиатека и настройки сохраняются.':
      'Installation stops playback and restarts Mumpa. Your library and settings are preserved.',
  'Файл .torrent': '.torrent file',
  'Файл перемещён или удалён. Импортируйте его снова.':
      'The file was moved or deleted. Import it again.',
  'Файл профиля больше 64 МБ.': 'The profile file exceeds 64 MB.',
  'Файл: {0}': 'File: {0}',
  'Файлов: {0} · ': 'Files: {0} · ',
  'Формат найденных версий': 'Track version format',
  'Хор': 'Choir',
  'Часто слушаешь': 'On repeat',
  'Читаем профиль…': 'Reading profile…',
  'Что искать': 'What to search',
  'Что сегодня слушаем?': 'What are we listening to today?',
  'Эквалайзер': 'Equalizer',
  'Эквалайзер, переходы, громкость, моно и радио':
      'Equalizer, crossfade, loudness, mono and radio',
  'Экспорт и импорт избранного, плейлистов и настроек':
      'Export and import favorites, playlists and settings',
  'Экспортировать профиль': 'Export profile',
  'Электроника': 'Electronic',
  'Это другой трек': 'This is a different track',
  'Этот выпуск подписан временным ключом CI. Android может отклонить обновление поверх текущей установки. Для совместимых обновлений нужен постоянный ключ релиза.':
      'This release uses a temporary CI signing key. Android may reject an update over your current installation. Compatible updates require a permanent release key.',
  'Язык': 'Language',
  'Язык интерфейса': 'Interface language',
  'Язык интерфейса приложения': 'App interface language',
  'Язык меняется сразу. Названия музыки и поисковые запросы сохраняются.':
      'Language changes immediately. Music titles and search queries are preserved.',
};
