# Listening statistics and offline space — 1.2.23

Settings → Downloads and offline shows completed Mumpa downloads as bytes,
percentage of the saved offline limit, and a progress bar. Sizes come from
existing files, once per normalized path. Imported music, copies in `imports/`,
external paths, symbolic links, missing files and `.part` transfers are excluded.
The indicator refreshes when completed download paths change and on reentry;
its refresh button also picks up external filesystem changes. Ordinary playback
notifications do not rescan files. Incomplete transfers and active reservations
still consume the existing download quota, so the completed-file indicator can
show less than the space required to start another download.

Home places the device top and up to six frequently played playlists before
discovery. The source feed becomes a horizontal shelf with touch scrolling and
a draggable desktop scrollbar. Search result lists retain their existing layout.

`trackPlayCounts` and `playlistPlayCounts` persist in the local `library.json`
and its ordinary atomic backup generations. A listen is counted once for a queue
occurrence when a playing, nonbuffering decoder first reports a position different
from its initial position. There is no minimum-duration threshold. Pause/resume
of the same occurrence, opening a collection, failed files and paused session
restoration add no listens. Starting that track again creates a new occurrence.

Playlist popularity counts actual track listens started in that playlist's
playback context, including offline versions selected from another collection.
Listening elsewhere does not credit every playlist containing the same song.
Autoplay radio credits tracks but does not credit its originating playlist.

The generated **Топ-50 на этом устройстве** is available on Home and in the
library, including library search. It groups known song variants using existing
matching rules, sums their counts, sorts descending, and retains at most 50 songs.
Ties use a stable track ID. The saved queue remains a snapshot while the displayed
ranking updates. The playlist can be played, searched and downloaded; its name,
membership and ranking cannot be edited, and it is excluded from playlist pickers.

Older profiles start with empty counts. The previous 100-item recent-history list
contains distinct IDs, not play events, so it is not used to invent past counts.
Statistics are stored with this device's local profile; they are not synced.

Focused regression coverage lives in `listening_stats_test.dart`,
`offline_storage_usage_test.dart`, `home_listening_ui_test.dart` and the playback
tests. The UI checks use 320 px and 1200 px widths, actual temporary files,
quota changes and removal of a download. `integration_test/listening_stats_test.dart`
adds an opt-in Windows/libmpv check with silent PCM, unavailable-file skipping,
pause/resume and persisted rankings:

```powershell
flutter drive --no-pub --driver integration_test/driver.dart --target integration_test/listening_stats_test.dart -d windows --debug --dart-define=LISTENING_STATS_NATIVE=true
```
