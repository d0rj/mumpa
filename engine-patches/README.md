# Managed TorrServer: MatriX.145.2-mumpa2

Mumpa's managed engine revision is `MatriX.145.2-mumpa2`. It uses TorrServer
tag `MatriX.145.2`, commit `bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9`
(GPL-3.0), and the exact `github.com/tsynik/torrent v1.2.31` fork (MPL-2.0).
The complete corresponding source is
`artifacts/TorrServer-MatriX.145.2-mumpa2-source.zip`; it contains both licenses,
the patched local dependency, `managed.mod`, and build metadata. The archive's
own SHA256 is published separately so the archived README has no circular hash.

## What changed

The cancellation change originated in `mumpa1`: `http.ServeContent` reads use
the request context, and the existing fork's `ReadContext` wakes a reader
waiting for absent pieces. Cache bookkeeping and seek behavior stay intact.
Deferred `CloseReader` releases registration after Read returns. Local tests
repeat canceled reads/disconnects on the same metadata-only torrent and check
206 ranges and the reader parking race.

`mumpa2` fixes two additional protocol defects. An error during the first
outgoing MSE handshake now permits plaintext fallback when encryption is
optional. The first socket is closed before the second dial. Both attempts
share the original bounded context; `ForceEncryption`, cancellation, and an
expired deadline prevent fallback. The deadline is checked directly because
a socket timer can wake before `context.Err()` is set. A successful initial
MSE handshake retains encryption.

HTTP announce `ip`/`ipv4`/`ipv6` fields now serialize a bare IP instead of
`krpc.NodeAddr.String()` (`address:0` or `[ipv6]:0`). The independent `port`
field keeps the listening port. Auto-detected `PublicIp4/6` still serves
DHT/peer handshakes but no longer overrides the tracker-observed source IP.
Explicit TorrServer `-4` / `-6` addresses populate the separate `AnnounceIp4/6`
overrides, preserving deliberate configuration for HTTP and UDP announces.
The original private-tracker query remains first. DNS, TLS, tracker transport,
user agent, interface, IPv6, bootstrap, and encryption defaults are unchanged.

## Validation boundary

Local Go regressions prove the protocol fixes: actual outgoing MSE EOF followed
by successful plaintext, forced-encryption rejection, explicit cancellation,
deadline expiration, successful RC4 without downgrade, and explicit-versus-auto
tracker IP behavior. They observe the initiator's own Close calls. Four negative
controls reintroduce the exact defects and must fail; thirty repeated deadline
cases pass. The focused suite has 12 tests plus four IPv4/IPv6 subcases.

The native Windows and Android outgoing-peer E2E also passed: a rejected MSE connection
was followed by a plaintext connection, audio advanced before full download,
and range/cache/restart/offline/reader cleanup checks passed, including Android
audio-service integration. This uses an
original local fixture, not a public swarm.

The separate strict Windows favorites check still received zero peers/audio
with `mumpa2` and only original metainfo trackers. The local protocol fixes
have **not** been shown to resolve current public-swarm unavailability or
establish public playback. Tests/logs in `checks/` expose no tracker passkeys,
credentials, user payloads, or public IP addresses.

## Pinned source and module overlay

The untouched TorrServer source archive SHA256 is
`947f0433df01a3b1ea128e076db3e4ba9138e12699a4c4236333fb918fd4be7f`.
The pristine official fork ZIP is
`engine-patches/upstream/tsynik-torrent-v1.2.31.zip`, from
`https://proxy.golang.org/github.com/tsynik/torrent/@v/v1.2.31.zip`:

- SHA256: `a1f1e92c3969b4a020271a0c99ff3f574f9b7f7e842f3362916af1d2e20e5e32`
- Upstream module sum: `h1:3MV8hzdi4xOD6nn8nExwYWHtxfEd9JES2HlSqx2JKdo=`

The build verifies source/patch hashes, unpacks the fork into fresh source at
`server/mumpa-deps/torrent`, and applies `torrent-source/`. Original `go.mod`
and `go.sum` remain byte-for-byte unchanged. `managed.mod` changes only the
existing torrent replacement to this local module, and `managed.sum` retains
the original sums. All other dependency versions and the upnp replacement
remain pinned. No shared module-cache source is edited.

## Build and verify the promoted release

```powershell
tools/build-managed-engine.ps1 -TestsOnly
tools/build-managed-engine.ps1 -Platform all
tools/prepare-engines.ps1
```

The script runs only deterministic local regressions, then builds sequentially
with `GOMAXPROCS=2`, `-p 2`, `-trimpath`, `-buildvcs=false`, `nosqlite`,
and an empty build ID. Ordinary builds must reproduce the lock's hashes.
`-TestsOnly` stops before NDK discovery, binary output, and source packaging.
No `go mod tidy`, latest generator, UPnP change, or tracker probe runs.

| Target | Toolchain and environment | SHA256 |
| --- | --- | --- |
| Windows amd64 | Go 1.27.1; CGO_ENABLED=0; GOAMD64=v1 | `b04344607b18de6a54a0a5a265a2c8c243d9bafadc90ddf8980cc547a95d3bb4` |
| Android arm64-v8a | Go 1.25.14; CGO_ENABLED=1; GOARM64=v8.0 | `df54f54ceaa44766804deb0f9b5a12d3cb239858969d9d84fef31375bd757196` |
| Android armeabi-v7a | Go 1.25.14; CGO_ENABLED=1; GOARM=7 | `48f2ea92cfeb9c430abdf968ba4e878a907c8900143d763fecb5a4e7f1ba3638` |
| Android x86_64 | Go 1.25.14; CGO_ENABLED=1; GOAMD64=v1 | `6058d057383f850ea03edc9585a1d738f009b1d4e64185b45a9cef87535e6f0b` |

The exact compiler versions match upstream's pinned binaries. Android uses NDK
**28.2.13676358**, API **21**, and `clang.exe`/`clang++.exe` targets
`aarch64-linux-android21`, `armv7a-linux-androideabi21`, or
`x86_64-linux-android21`. The `.so` files are Go executable ELF binaries
(`buildmode=exe`), matching upstream packaging.

A workspace `GOMODCACHE` can isolate exact-version dependency downloads.
`-GoExecutable` and optional `-AndroidGoExecutable` may select already installed
exact compilers. Otherwise Go can download the pinned toolchains automatically.

## Build from the corresponding source archive

Enter `server`, set the exact `GOOS`, `GOARCH`, `GOTOOLCHAIN`, CGO and CPU
settings above, and set Android `CC`/`CXX` to the NDK compilers with the listed
`--target`. The prepared local module is complete; run:

```text
go test -modfile=managed.mod -mod=readonly -buildvcs=false -p 2 -tags nosqlite -ldflags "-checklinkname=0" -run "TestRequestReader|TestReaderContextCancellation|TestReaderOffDoesNotPark|TestMumpa" -count=1 -timeout=120s ./torr ./torr/storage/torrstor github.com/anacrolix/torrent github.com/anacrolix/torrent/tracker
go build -modfile=managed.mod -mod=readonly -buildvcs=false -p 2 -trimpath -tags nosqlite -ldflags "-s -w -buildid= -checklinkname=0 -X server/version.Version=MatriX.145.2-mumpa2" -o <output> ./cmd
```

Build metadata is included under `mumpa-build/`. These raw Go commands work
directly from the archive without modifying a module cache.

## Developer patch promotion

`-LockFile <reviewed-lock.json>` selects an independent
reviewed candidate before promotion. An initial `pendingBinaries` flag blocks
ordinary builds; an intentional `-Platform all -UpdateLock` records all four
outputs and clears it. Promote the candidate to the primary lock after native
validation. Before promotion, pass the candidate lock explicitly to build and
preparation; ordinary commands use the primary lock. Source archives use deterministic ordering
and ZIP timestamps. `-UpdateLock` is reserved for intentional patch revisions.
