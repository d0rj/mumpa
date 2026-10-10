# TorrServer MatriX.145.2 source constraints

Investigated 2026-10-08 to diagnose a fixture that imports `.torrent` metadata successfully but never requests its local HTTP webseed and leaves native playback at position zero. App code was inspected read-only; the findings below come from the exact engine source and its pinned dependencies. They do not assert that a revised fixture has passed runtime checks.

## Webseed-only fixture cannot work with this binary

The initial original-audio fixture uses `url-list: http://127.0.0.1:<port>/original.wav`, with no tracker or BitTorrent seeder. That proves metadata parsing if add/get yields `file_stats`; it provides no usable payload source to this engine.

In `server/web/api/utils/link.go`, `fromHttp`, `ParseFile`, `ParseFromBytes` and `fromFile` load the metainfo but manually create a `TorrentSpec` containing only `InfoBytes`, `Trackers`, `DisplayName` and `InfoHash`. The root metainfo's `UrlList` is not carried over. `fromMagnet` similarly keeps only info hash, name and trackers. [Pinned parser source](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/utils/link.go).

The engine does not in fact use upstream anacrolix v1.59.1 at runtime. Its `go.mod` replaces that module with `github.com/tsynik/torrent v1.2.31`. The fork's `TorrentSpec` has no `Webseeds` field, and its own `TorrentSpecFromMetaInfo` ignores `UrlList`. A simple parser change adding `Webseeds: minfo.UrlList` would not compile against that struct. [Pinned dependency replacement](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/go.mod), [fork spec implementation](https://github.com/tsynik/torrent/blob/v1.2.31/spec.go).

Some `btserver.go` comments mention webseed settings, but comments are not evidence of implemented support. No enabled/disabled flag, preload setting or media-player URL change can restore a source that was discarded at import and is absent from the selected spec API.

Use a real local BitTorrent fixture instead: a generated original WAV, metainfo with correct piece hashes, an isolated seeder that has the bytes, and an HTTP tracker returning that seeder's compact IP/port. A minimal peer-wire fixture can serve blocks itself; alternatively use the installed Go runtime and a BitTorrent library in a separate test helper. Keep that helper separate from the app and preserve the pinned engine binary to validate the shipped implementation. The tracker should use an announce URL the engine retains. Add `.torrent` first; magnet metadata exchange can then be tested as a separate case.

## Stream flags and preload

`/stream?link=<hash>&index=<file_stats.id>&play=` is valid. The handler calls `c.GetQuery("play")` and tests the returned boolean; Gin 1.11 returns true when the key exists even with an empty value. `play`, `play=` and `play=false` all set the flag. The last form must not be used to disable streaming. [Pinned handler](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/stream.go), [Gin query behavior](https://github.com/gin-gonic/gin/blob/v1.11.0/context.go).

The index is the returned server file ID after natural-path sorting, starting at 1. A successful `get` proves metadata and file identity; it does not prove that any audio piece is available or that native playback started.

The `preload` flag invokes preload before handling `stat`/`m3u`/`play`. `Preload` reads beginning/end data through torrent readers and can block waiting for missing pieces. It cannot make a peerless webseed-only fixture work. Defaults are a 64 MiB piece cache, 50% preload target, 95% reader readahead and a 30-second torrent disconnect timeout. For a 2 MiB music file preload is capped to file length, so adding it may wait for almost the complete small file. [Preload algorithm](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/preload.go), [preload dispatch](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/apihelper.go), [default settings](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/settings/btsets.go).

`Stream` creates a torrent reader and passes it to `http.ServeContent`. The actual byte request blocks until the requested piece/block arrives; reader presence and response headers do not prove useful payload delivery. Inspect actual stream bytes and seeder upload counters before investigating decoder behavior. [Pinned byte-serving implementation](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/stream.go).

## Plaintext fixture handshake

Loopback peers are not categorically rejected: `badPeerIPPort` checks a zero port, self/doppelganger address, configured blocklist and banned IPs. The fixture's compact tracker peer address is valid. The fork normally initiates an MSE encrypted handshake first because both `DisableEncryption` and `PreferNoEncryption` default false. A plaintext-only fixture that consumes the first 68 bytes as a BitTorrent handshake instead consumes MSE data. An MSE error returns immediately from `establishOutgoingConn`; the plaintext fallback occurs only when the first attempt returns a nil connection without an error. [Fork connection behavior](https://github.com/tsynik/torrent/blob/v1.2.31/client.go), [policy defaults](https://github.com/tsynik/torrent/blob/v1.2.31/config.go).

Fixture solution without modifying the shipped binary: initiate a plaintext peer connection **from the seeder to the engine** using the `port` advertised by the engine in its HTTP announce request. Send the complete BitTorrent handshake first, validate the response, then send bitfield and unchoke and answer requests. Return an empty compact `peers` string from the tracker to avoid an additional MSE outgoing dial. The engine accepts an incoming plaintext handshake when `ForceEncrypt` is false. This is a source-supported fixture design; a passing runtime test still needs to establish actual payload/decoder behavior.

**Managed correction in 1.1.4:** `MatriX.145.2-mumpa2` patches the pinned fork's immediate error return. A failed outgoing MSE handshake retries plaintext only while encryption is optional and the request context/deadline is live. Forced encryption and successful encrypted connections retain their policy. The native `OUTGOING_PEER_TEST` fixture advertises its own listening peer through the local tracker, rejects MSE and verifies actual playback through the subsequent outgoing plaintext connection. The incoming fixture above remains available as a separate baseline.

### Binary HTTP announce query in Dart

The tracker's `info_hash` and `peer_id` query values are byte strings, not UTF-8 text. The fixture originally used `request.uri.queryParameters['port']`; Dart decodes every query value with UTF-8 before returning that map. The original WAV fixture's info hash is `bfc5614f2cb09d89ae90f0654ba6640738c6e808`, whose first byte `0xbf` is invalid UTF-8. That getter therefore throws before the reverse connection is started. An empty `catch (_) {}` hides the failure and leaves the HTTP response unanswered. This explains the fixture's apparent lack of announce/seed activity without any local-tracker rejection.

Read the numeric port directly from raw query text, e.g. `RegExp(r'(?:^|&)port=(\d+)(?:&|$)').firstMatch(request.uri.query)`, or use `Uri.splitQueryString(request.uri.query, encoding: latin1)` for a one-byte-preserving map. Count/log announces before decoding and log exceptions; never silently abandon a tracker response. [Dart query splitting implementation](https://api.dart.dev/dart-core/Uri/splitQueryString.html), [UTF-8 error contract](https://api.dart.dev/dart-convert/Utf8Codec/decode.html).

The pinned tracker implementation retains a root metainfo `announce` URL via `MetaInfo.Magnet`/`UpvertedAnnounceList`, starts its first announce immediately, accepts HTTP(S), and has no categorical loopback/private-address rejection. Address filtering consults the optional configured IP blocklist. Its explicit HTTP transport uses the configured proxy function; nil does not select an environment proxy. Thus the parser, on-demand scheduling and default proxy path do not account for the deterministic Dart decoding failure. [Metainfo tracker conversion](https://github.com/tsynik/torrent/blob/v1.2.31/metainfo/metainfo.go), [announce scheduling](https://github.com/tsynik/torrent/blob/v1.2.31/tracker_scraper.go), [HTTP transport and binary query escaping](https://github.com/tsynik/torrent/blob/v1.2.31/tracker/http.go).

## Quiet managed first-start configuration

Disable optional LAN advertisements and port mapping with `EnableLPD:false`, `EnableBonjour:false`, `EnableDLNA:false` and `DisableUPNP:true`. Retain TCP, uTP, DHT and PEX for normal public swarm operation; those features are separate from LAN discovery. Both LPD and Bonjour are enabled by upstream defaults. HTTP management should still bind to loopback. [Engine mapping](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/btserver.go), [defaults](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/settings/btsets.go).

The on-disk filename is `<CLI -d directory>/settings.json`; its root is a map with case-sensitive key `BitTorr`. The object uses exported PascalCase `BTSets` names. Create it before first engine start to prevent a brief startup advertisement. A safe initial record preserves upstream nonzero playback/cache defaults:

```json
{
  "BitTorr": {
    "CacheSize": 67108864,
    "PreloadCache": 50,
    "ConnectionsLimit": 25,
    "RetrackersMode": 1,
    "TorrentDisconnectTimeout": 30,
    "ReaderReadAHead": 95,
    "ResponsiveMode": true,
    "ShowFSActiveTorr": true,
    "StoreSettingsInJson": true,
    "EnableLPD": false,
    "LPDIPv6": false,
    "EnableBonjour": false,
    "EnableDLNA": false,
    "DisableUPNP": true
  }
}
```

Writing only four flags is unsafe: `loadBTSets` does not overlay a partial decoded record on `SetDefaultConfig`; most omitted numeric fields stay zero. The loader fills missing tracker text and TMDB defaults and clamps readahead, but does not reconstruct every omitted field. Only initialize a new managed state directory. Preserve other root/config fields when updating an existing stopped-engine JSON file. [JSON filename/key mapping](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/settings/jsondb.go), [startup routing](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/settings/settings.go).

For an already running server, `POST /settings` accepts `{"action":"get"}`, followed by `{"action":"set","sets":<full merged object>}`. It replaces settings and reconnects the BitTorrent client, so preserve unrelated values. A fixture may disable DHT/uTP/PEX and added retrackers and bind peer transport to `127.0.0.1:0`; those restrictions should not become normal public-swarm defaults. [Settings endpoint](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/settings.go).

## `.torrent` persistence and restart

Upload with multipart `file` and a nonempty `save` field schedules `SaveTorrentToDB` after `GotInfo`. The response is produced before that asynchronous save necessarily finishes. The app must not infer durable engine persistence from the upload response alone if it immediately shuts down the engine. Wait for readiness/allow save or retain the metainfo independently. [Upload lifecycle](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/upload.go).

`AddTorrentDB` stores the current `TorrentSpec` plus title/category/artwork/data/time/size. `WaitInfo` copies resolved `InfoBytes` into the spec when originally absent. `settings.AddTorrent` serializes the record to JSON in the engine's persistent `Torrents` storage. Thus an uploaded metainfo with `save` retains info bytes and tracker information in the engine state directory; it does not require the original picker path for an ordinary restart with that directory intact. [DB wrapper](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/dbwrapper.go), [spec info completion](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/torrent.go), [persistence serialization](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/settings/torrent.go).

After restart `GetTorrent(hash)` can return a `TorrentInDB` record while starting a live torrent in a goroutine. The first successful HTTP `get` need not contain live `file_stats`. Poll until a live status is ready before treating it as a resolved stream. The saved display `Data` includes file IDs/paths/sizes, but that display data is not a live file reader. [Reload behavior](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/apihelper.go).

`NewTorrent` restores missing info bytes from DB but does not explicitly copy saved trackers into a newly parsed hash-only spec. DB reload asynchronously uses the full saved spec. Preserve the imported source and test play-after-restart using a fixture whose only announce is the local tracker; this catches any ordering/race that public default trackers might hide. This is a risk inferred from the reload paths and needs runtime validation, not a confirmed failure.

For robust application-level recovery retain an app-owned copy of uploaded `.torrent` bytes and its hash. If the managed engine directory is reset or an external server drops its DB, hash-only streaming cannot recreate the original file metadata without peers, nor recover private trackers from the hash. Re-upload that copy. A `torrentLink == null` track combined with an absent engine record otherwise has no recovery source. The metainfo copy is independent of complete-file offline music.

## Diagnostic order

1. Confirm requested stream URL contains `play` and the returned `file_stats.id`.
2. Confirm a real BitTorrent seeder/tracker is present; `url-list` alone is insufficient for this pinned engine.
3. Read a tiny HTTP `Range` from the actual stream and compare exact bytes to the generated WAV.
4. Inspect tracker announces and seeder uploaded bytes.
5. Only after bytes pass, inspect native decoder errors/position.
6. Download and compare SHA-256, stop the engine/seed, then exercise offline playback.
7. Restart the engine with the same directory, verify saved upload reload, and exercise re-upload recovery with a reset engine directory separately.
