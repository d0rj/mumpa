# Personal library membership — 1.2.19

Opening search results previously stored every audio file and source collection,
and the library displayed all stored records. Inspecting several discographies
therefore added hundreds of candidate albums without a playback or save action.

The repository now retains known records for source navigation, saved queues,
metadata and version matching, with separate `mediaTracks`, `mediaAlbums` and
`mediaPlaylists` views for the personal library. Home, Library, local library
search, the artist's library section and the sidebar use these views.

A track selects its complete album from the same torrent source when it is:

- played, or explicitly added through the selected-file torrent import;
- liked, included in a liked album or liked source collection;
- downloaded, locally imported, or included in a personal playlist.

Selecting one album does not select other albums in its discography or inspected
mirrors with the same artist/album title. Source collections appear after one of
their tracks qualifies or the collection is liked; personal playlists, including
empty ones, remain visible. Reopening an inspected collection still works and
keeps its existing edits and IDs.

`retainedTrackIds` persists played/explicitly added track IDs independently of
the last 100 recent items. Membership follows the anchor track's latest tags.
Old profiles initialize these IDs from their surviving recent history, while
favorites, offline files and personal playlists qualify directly. Older plays
that have already left recent history cannot be reconstructed if they have no
other saved evidence. The next library write persists the new field. No tracks,
collections, favorites or audio files are deleted by this change.

Radio's existing-library candidates also use `mediaTracks`. Merely opening a
collection cannot add it to this fallback pool. The independent bounded search
for relevant new music through similar artists and the configured catalog still
works, including the possibility of rediscovering a relevant inspected release.
Preparing an unplayed radio candidate alone does not retain it in the library.

## Verification

Tests cover inspection versus playback, a complete selected album across discs,
source-specific mirror exclusion, persistence beyond recent-history eviction,
metadata changes, favorites/downloads/personal playlists, legacy profiles,
collection visibility at 320/390/1200 px, and radio's known-candidate pool.

The opt-in native test uses an original generated WAV and real Windows/libmpv,
with caching/prefetch disabled and no public source request. It verifies the
library before/after playback, hidden mirrors, native position, and restart.

The separate opt-in production audit loads a temporary copy of the current
profile, verifies all stored IDs and playlists remain, checks favorites/offline
and recent tracks stay visible, persists/reloads that copy, and checks the source
file's SHA-256 stayed unchanged. The observed snapshot contained 9,861 known
tracks/819 albums/17 playlists; personal views contained 653 tracks/200 albums/
12 playlists, retaining 45 favorite tracks, three favorite albums and 36 offline
tracks. This snapshot is an audit result, not an update to the running app.

Final unit/widget suite: **458 passed**, three existing opt-in tests skipped.
Static analysis and formatting passed. Windows x64 and Android ARM64/ARMv7/
x86_64 release builds and symbols are packaged as 1.2.19+27.

The native debug launcher once exited before assertions after locating an old
media_kit reference pointer; the successful final run uses an isolated temporary
directory. A live source can also be saved by another running app during the
read-only audit, so its hash equality is diagnostic. In the final audit the
source hash was unchanged and the production repository was never opened.

Evidence: `test-output/library-membership-{full-tests,analyze,native-final-test}.log`,
`library-membership-native.json`, `library-membership-profile-audit.json`,
`library-membership-native.png`. Android package compilation is separate from
runtime testing on a physical Android device.
