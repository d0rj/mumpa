# Queue prefetch and unavailable-track skipping — 1.2.18+26

Settings → Offline and cache → Prepare following tracks controls a persisted
`prefetchTracks` count from 0 (disabled) to 10, default 3. This prepares full
offline files for the next missing torrent tracks in the actual playback queue.
It works independently of `autoCache`, which controls saving the playing track.

The window ignores existing local/shared copies after checking the filesystem,
local tracks, repeated IDs and aliases of the same torrent hash/path. It refreshes
on selection, queue replacement/reordering/shuffle, resume or a count change.
Completing a download does not extend it through the entire remaining playlist.
Queue revisions avoid rescanning large queues on position/volume updates.

Prefetch uses the existing download worker pool and quota. The playing track
retains its priority. Pause, Stop, a replacement queue and disabling prefetch
pause only transfers owned by prefetch; manual downloads continue. Completed
files and resumable partials remain. A manual pause or failed transfer is not
automatically retried by subsequent progress/metadata notifications.

Missing files, source metadata/audio deadlines, synchronous decoder rejection,
later stream errors and decoder startup watchdog failures advance to the next
queue occurrence. Repeat-one cannot trap an unavailable file; repeat-all visits
each failed occurrence at most once until real audio progress or an explicit
new playback action. An entirely unavailable queue stops. Saved playlist
membership remains unchanged. Pause/Stop invalidate pending traversal, and late
decoder completion/errors after Pause cannot restart the queue. The existing
prepared-radio continuation retains its bounded discovery/decoder attempts.

Small cover controls are invisible while idle. Hovering shows Play; an active
playing track shows Pause, including a selected alternative in a grouped row.
The cover remains tappable without hover on touch devices. Clicking the rest of
a grouped row retains the version picker.

## Evidence

- **443 unit/widget tests passed**, three existing opt-in checks skipped, on a
  source snapshot containing this change and committed baseline 569f44e.
  `test-output/prefetch-isolated-full-tests.log` records the complete run.
- Analysis passed for lib/test/integration_test on that snapshot:
  `test-output/prefetch-isolated-analyze.log`.
- Native Windows/libmpv with generated WAVs and loopback HTTP passed: a missing
  local file is skipped; exactly the requested window starts; natural completion
  skips HTTP 503 and plays the previously completed local file without resolving
  its stream again; bytes, playlist membership and Pause are checked.
  `test-output/prefetch-native-test.log` and `prefetch-native.json`.
- Mouse enter/leave, active alternative, Pause and no-hover cover taps are
  checked at 320 and 1200 px. Settings persistence, restore-without-network,
  shared copies, duplicates, failed jobs, manual ownership, order changes and
  repeat-all startup failure bounds have automated coverage.

The snapshot isolates concurrent uncommitted file-location UI changes. A mixed
workspace run found an album-column alignment failure in that concurrent change;
it is outside the prefetch patch. Public swarms and physical Android playback
were not tested. Native transfer evidence uses controlled loopback sources.

`graphify query` and `graphify update .` were attempted; the installed executable
reported `uv trampoline failed to canonicalize script path`, so the graph could
not be refreshed.
