# Known track versions — 1.2.12

Mumpa groups files already in the library, including tracks from opened torrent
collections. It does not search trackers for duplicates, fetch audio for
comparison or build a global index.

Click a grouped row or `×N` to choose a version. The popup shows format, known
duration, album, source collection, filename, size, offline status and censorship
hints. A star saves the default. Play on the small cover starts immediately:
an available offline default first, then an offline collection member, then
another known offline copy, then the saved online default or original member.
Ordinary collection playback checks that the local file still exists. Selecting a popup row plays that exact
file for this queue occurrence. Up to two offset covers sit behind the front;
hidden layers use cached artwork/fallbacks without extra cover requests.

## Matching and uncertainty

This is **metadata matching**, not verified audio identity. Normalized track
artist and title must match (case, punctuation and ё/е ignored). Exact artist
prefixes and an allowlist of bracketed/delimited format, censorship and remaster
annotations are ignored for matching; original labels remain visible. Featured
artist credits stay significant. Unknown/compilation artists and generic
numbered filenames stay separate.

Live, acoustic, remix, radio edit, instrumental and other performance suffixes
remain significant. Performance labels in album names/physical torrent album
folders also separate otherwise identical titles. Intro/outro/skit/interlude
names require the same album and disc. Unlabelled alternate recordings with
similar names/durations can still match.

Known durations allow 5% difference, bounded at 5–15 seconds. Explicit censorship
hints in track/album/file/source metadata allow 10%, bounded at 8–30 seconds.
Every pair satisfies its bound; an intermediate length cannot bridge very
different versions. Unknown lengths join only an unambiguous single duration
partition. Most unplayed torrent files lack duration, so those matches rely on
names and album hints until cached-file tags enrich them.

**«Это другой трек»** separates a false match and survives restart. The track
action **«Снова объединять похожие версии»** reverses it. Substantially different
spellings, artist aliases and translations are not resolved acoustically. Audio
fingerprints and manual joins remain future work.

Format hints come from extensions. M4A/OGG/WMA/WebM do not imply a known codec
or lossless status. Clean/Explicit labels describe metadata only; the application
does not verify audio censorship or the quality of a purported lossless source.

## Storage and queue behavior

`TrackMatchIndex` caches immutable groups and row projections per library
revision. Large imports normalize new identities outside the UI isolate.
Sorted duration partitions intersect upper bounds in constant time per member,
avoiding quadratic comparisons. Position/history/likes retain the index.

Optional JSON fields `trackMatchExcluded` and `preferredTrackVariants` store
existing file IDs. Legacy profiles need no destructive migration. Track changes,
removal and source-title edits invalidate groups; removed preference IDs are
pruned. The most recent default wins if enriched groups later join.

Rows retain original collection members separately from the playable version.
Play collection queues one representative per group and remaps selection while
keeping the full unfiltered collection and playlist context. Choosing another
known source never rewrites the saved playlist. Removing a grouped playlist row
removes its visible members, not its external default. Group hearts reflect any
liked variant; unlike clears those likes, while like saves the displayed file.
Existing likes remain until the user acts. Manual queue additions/reorders still
support repeated occurrences.

## Checks

Domain/repository tests cover formats/censorship, length bounds and bridges,
missing metadata, alternate/generic titles, 10k-copy scaling, invalidation,
restart, exclusions/defaults and grouped favorites. Widget tests at 320/1200 px
cover the picker, exact file selection, cover play, defaults, split/rejoin and
unfiltered queues with unchanged playlist membership and zero source requests.

The opt-in Windows test renders the UI and plays original generated silent WAVs
with real libmpv in an isolated profile (21-second selected version, 20-second
cover default). It records screenshots and asserts zero network calls. Optional
production audit reads metadata only and verifies the profile stays identical.

```powershell
flutter test --no-pub
flutter analyze --no-pub lib test integration_test
flutter drive -d windows --driver=integration_test/driver.dart --target=integration_test/track_matching_test.dart --dart-define=TRACK_MATCHING_NATIVE=true --dart-define=REAL_TRACK_MATCH_AUDIT=true
```

Evidence: `test-output/track-matching-*`. Native proof covers local Windows
decoding/selection, not public swarms or physical Android devices.
