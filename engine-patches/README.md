# Managed TorrServer patch

Mumpa distributes `MatriX.145.2-mumpa1`, based on upstream TorrServer commit
`bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9` (GPL-3.0). The upstream `LICENSE`
remains in the complete corresponding source archive.

The patch binds `http.ServeContent` reads to the HTTP request context. The pinned
`github.com/tsynik/torrent v1.2.31` already supports `ReadContext`: cancellation
wakes a read waiting for absent torrent pieces. The cache reader preserves its
existing begin/end bookkeeping and seek behavior. `CloseReader` runs after the
read returns, releasing the cache registration without concurrent Close/Read.

Go regressions cover three canceled reads on actual metadata-only cached torrent
readers with all networking disabled, three client disconnects over a local HTTP
connection, and the existing 206 byte-range response behavior. Retries keep the
same torrent/server running and do not drop metadata to simulate cancellation.

## Build from the Mumpa checkout

Run `tools/build-managed-engine.ps1 -Platform all` in PowerShell on Windows.
`tools/prepare-engines.ps1` verifies patched hashes and builds missing assets.
The script verifies the upstream source and patch SHA256 hashes, copies the
checked overlay, preserves upstream `go.mod`/`go.sum`, runs focused package tests,
then builds Windows and Android arm64-v8a/armeabi-v7a/x86_64 sequentially.

The lock records Go **1.27.1** for Windows and **1.25.14** for Android (matching
the upstream binaries' compiler versions), NDK **28.2.13676358**, Android API
**21**, and every resulting binary SHA256. Go's automatic toolchain downloader
may fetch those exact official compilers. Dependencies are pinned by the
unchanged module files, including the upstream torrent/upnp replacements.
No `go mod tidy`, latest generator, UPnP change, or tracker probe is performed.

Windows uses `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 GOAMD64=v1`.
Android uses `GOOS=android CGO_ENABLED=1`, the NDK `clang.exe` with
`--target=aarch64-linux-android21`, `armv7a-linux-androideabi21`, or
`x86_64-linux-android21`, and `GOARM64=v8.0` / `GOARM=7` / `GOAMD64=v1`.

From a corresponding patched source archive, enter `server` and run:

```text
go test -mod=readonly -buildvcs=false -p 2 -tags nosqlite -ldflags "-checklinkname=0" -run "TestRequestReader|TestReaderContextCancellation|TestReaderOffDoesNotPark" -count=1 -timeout=120s ./torr ./torr/storage/torrstor
go build -mod=readonly -buildvcs=false -p 2 -trimpath -tags nosqlite -ldflags "-s -w -buildid= -checklinkname=0 -X server/version.Version=MatriX.145.2-mumpa1" -o <output> ./cmd
```

Set the exact toolchain and target environment above before building each
binary. Android `.so` assets are executable Go ELF binaries (`buildmode=exe`),
matching upstream packaging. The build script is included under `mumpa-build/`
with this explanation and the lock. `-UpdateLock` is reserved for intentionally
producing a new reviewed patch revision; regular builds must match the lock.
