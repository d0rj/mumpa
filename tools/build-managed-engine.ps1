param(
    [ValidateSet('all','windows','android')][string]$Platform = 'all',
    [string]$GoExecutable = 'C:\Program Files\Go\bin\go.exe',
    [string]$AndroidNdk = '',
    [switch]$UpdateLock,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
$mumpaLockPath = Join-Path $mumpaRoot 'engine-patches/managed-engine.lock.json'
$mumpaLock = Get-Content -LiteralPath $mumpaLockPath -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $GoExecutable)) { throw "Go executable missing: $GoExecutable" }

function Get-MumpaHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Invoke-MumpaGo([string[]]$Arguments) {
    & $GoExecutable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Go command failed with exit code $LASTEXITCODE" }
}
function Write-MumpaSourceArchive([string]$Source, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    $mumpaZipStream = [IO.File]::Create($Destination)
    $mumpaZip = [IO.Compression.ZipArchive]::new($mumpaZipStream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($mumpaFile in @(Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName)) {
            $mumpaRelative = $mumpaFile.FullName.Substring($Source.Length + 1).Replace('\','/')
            $mumpaEntry = $mumpaZip.CreateEntry("TorrServer-$($mumpaLock.version)/$mumpaRelative", [IO.Compression.CompressionLevel]::Optimal)
            $mumpaEntry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $mumpaInput = [IO.File]::OpenRead($mumpaFile.FullName)
            $mumpaOutput = $mumpaEntry.Open()
            try { $mumpaInput.CopyTo($mumpaOutput) } finally { $mumpaInput.Dispose(); $mumpaOutput.Dispose() }
        }
    } finally { $mumpaZip.Dispose(); $mumpaZipStream.Dispose() }
}

$mumpaSourceZip = Join-Path $mumpaRoot $mumpaLock.upstream.archive
if (-not (Test-Path -LiteralPath $mumpaSourceZip)) {
    New-Item -ItemType Directory -Force (Split-Path $mumpaSourceZip -Parent) | Out-Null
    $mumpaDownload = "$mumpaSourceZip.download"
    Invoke-WebRequest $mumpaLock.upstream.url -OutFile $mumpaDownload
    if ((Get-MumpaHash $mumpaDownload) -ne $mumpaLock.upstream.sha256) { throw 'Pinned source archive SHA256 mismatch' }
    Move-Item -LiteralPath $mumpaDownload -Destination $mumpaSourceZip -Force
}
if ((Get-MumpaHash $mumpaSourceZip) -ne $mumpaLock.upstream.sha256) { throw 'Pinned source archive SHA256 mismatch' }
$mumpaWork = Join-Path $mumpaRoot ('.local/engine-build/run-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $mumpaWork | Out-Null
Expand-Archive -LiteralPath $mumpaSourceZip -DestinationPath $mumpaWork
$mumpaSource = Join-Path $mumpaWork ('TorrServer-' + $mumpaLock.upstream.commit)
if (-not (Test-Path -LiteralPath (Join-Path $mumpaSource 'server/go.mod'))) { throw 'Unexpected pinned archive root' }
foreach ($mumpaOverlay in $mumpaLock.overlays) {
    $mumpaOverlayFile = Join-Path $mumpaRoot ('engine-patches/source/' + $mumpaOverlay.path)
    if ((Get-MumpaHash $mumpaOverlayFile) -ne $mumpaOverlay.sha256) { throw "Patch integrity mismatch: $($mumpaOverlay.path)" }
    $mumpaDestination = Join-Path $mumpaSource $mumpaOverlay.path
    New-Item -ItemType Directory -Force (Split-Path $mumpaDestination -Parent) | Out-Null
    Copy-Item -LiteralPath $mumpaOverlayFile -Destination $mumpaDestination -Force
}
foreach ($mumpaModuleFile in $mumpaLock.modules) {
    if ((Get-MumpaHash (Join-Path $mumpaSource $mumpaModuleFile.path)) -ne $mumpaModuleFile.sha256) { throw 'Pinned module graph changed' }
}
$mumpaEnvironmentKeys = @('GOTOOLCHAIN','GOMAXPROCS','GOOS','GOARCH','CGO_ENABLED','GOARM','GOARM64','GOAMD64','CC','CXX','GOFLAGS','GOWORK')
$mumpaEnvironment = @{}
foreach ($mumpaKey in $mumpaEnvironmentKeys) { $mumpaEnvironment[$mumpaKey] = [Environment]::GetEnvironmentVariable($mumpaKey, 'Process') }
try {
    $env:GOMAXPROCS = '2'
    $env:GOFLAGS = ''
    $env:GOWORK = 'off'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:GOAMD64 = 'v1'
    $env:GOARM = ''
    $env:GOARM64 = ''
    $env:CGO_ENABLED = '0'
    $env:GOTOOLCHAIN = $mumpaLock.toolchains.windows
    Push-Location (Join-Path $mumpaSource 'server')
    try {
        Invoke-MumpaGo @('version')
        # Preserve the exact module graph; no tidy or latest generators.
        Invoke-MumpaGo @('mod','download')
        if (-not $SkipTests) {
            # Other upstream tests start a full client and fetch public IP/tracker
            # lists; restrict this build check to deterministic local regressions.
            Invoke-MumpaGo @('test','-mod=readonly','-buildvcs=false','-p','2','-tags','nosqlite','-ldflags','-checklinkname=0','-run','TestRequestReader|TestReaderContextCancellation|TestReaderOffDoesNotPark','-count=1','-timeout=120s','-v','./torr','./torr/storage/torrstor')
        }
        if ($Platform -in @('all','android')) {
            if (-not $AndroidNdk) {
                $mumpaLocalProperties = Join-Path $mumpaRoot 'android/local.properties'
                if (Test-Path -LiteralPath $mumpaLocalProperties) {
                    $mumpaSdkLine = Get-Content -LiteralPath $mumpaLocalProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
                    if ($mumpaSdkLine) {
                        $mumpaSdk = $mumpaSdkLine.Substring(8).Replace('\\','\').Replace('\:',':')
                        $AndroidNdk = Join-Path $mumpaSdk ('ndk/' + $mumpaLock.toolchains.ndk)
                    }
                }
            }
            if (-not $AndroidNdk -or -not (Test-Path -LiteralPath (Join-Path $AndroidNdk 'source.properties'))) { throw 'Pinned Android NDK missing; pass -AndroidNdk explicitly' }
            $mumpaNdkRevision = (Get-Content -LiteralPath (Join-Path $AndroidNdk 'source.properties') | Where-Object { $_ -match '^Pkg.Revision\s*=' }).Split('=')[1].Trim()
            if ($mumpaNdkRevision -ne $mumpaLock.toolchains.ndk) { throw "Expected NDK $($mumpaLock.toolchains.ndk), found $mumpaNdkRevision" }
        }
        foreach ($mumpaTarget in $mumpaLock.targets) {
            if ($Platform -ne 'all' -and $mumpaTarget.platform -ne $Platform) { continue }
            $env:GOTOOLCHAIN = $mumpaTarget.toolchain
            $env:GOOS = $mumpaTarget.goos
            $env:GOARCH = $mumpaTarget.goarch
            $env:CGO_ENABLED = $mumpaTarget.cgo
            $env:GOARM = $mumpaTarget.goarm
            $env:GOARM64 = $mumpaTarget.goarm64
            $env:GOAMD64 = $mumpaTarget.goamd64
            $env:CC = ''
            $env:CXX = ''
            if ($mumpaTarget.platform -eq 'android') {
                $mumpaLlvm = Join-Path $AndroidNdk 'toolchains/llvm/prebuilt/windows-x86_64/bin'
                $env:CC = '"' + (Join-Path $mumpaLlvm 'clang.exe') + '" --target=' + $mumpaTarget.clangTarget
                $env:CXX = '"' + (Join-Path $mumpaLlvm 'clang++.exe') + '" --target=' + $mumpaTarget.clangTarget
            }
            Write-Output "Building $($mumpaTarget.id) with $($mumpaTarget.toolchain)"
            $mumpaOutput = Join-Path $mumpaWork ($mumpaTarget.id + '.binary')
            $mumpaLdflags = '-s -w -buildid= -checklinkname=0 -X server/version.Version=' + $mumpaLock.version
            Invoke-MumpaGo @('build','-mod=readonly','-buildvcs=false','-p','2','-trimpath','-tags','nosqlite','-ldflags',$mumpaLdflags,'-o',$mumpaOutput,'./cmd')
            $mumpaHash = Get-MumpaHash $mumpaOutput
            if (-not $UpdateLock -and $mumpaHash -ne $mumpaTarget.sha256) { throw "Reproducibility mismatch for $($mumpaTarget.id): $mumpaHash" }
            $mumpaFinal = Join-Path $mumpaRoot $mumpaTarget.path
            New-Item -ItemType Directory -Force (Split-Path $mumpaFinal -Parent) | Out-Null
            if (-not (Test-Path -LiteralPath $mumpaFinal) -or (Get-MumpaHash $mumpaFinal) -ne $mumpaHash) {
                Copy-Item -LiteralPath $mumpaOutput -Destination $mumpaFinal -Force
            }
            $mumpaTarget.sha256 = $mumpaHash
            Write-Output "$($mumpaTarget.id) SHA256 $mumpaHash"
        }
        foreach ($mumpaModuleFile in $mumpaLock.modules) {
            if ((Get-MumpaHash (Join-Path $mumpaSource $mumpaModuleFile.path)) -ne $mumpaModuleFile.sha256) { throw 'Build modified pinned module graph' }
        }
    } finally { Pop-Location }
    if ($UpdateLock) {
        [IO.File]::WriteAllText($mumpaLockPath, ($mumpaLock | ConvertTo-Json -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
    }
    $mumpaBuildFolder = Join-Path $mumpaSource 'mumpa-build'
    New-Item -ItemType Directory -Path $mumpaBuildFolder | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $mumpaBuildFolder 'build-managed-engine.ps1')
    Copy-Item -LiteralPath $mumpaLockPath -Destination (Join-Path $mumpaBuildFolder 'managed-engine.lock.json')
    Copy-Item -LiteralPath (Join-Path $mumpaRoot 'engine-patches/README.md') -Destination (Join-Path $mumpaBuildFolder 'README.md')
    $mumpaPatchedZip = Join-Path $mumpaRoot ('artifacts/TorrServer-' + $mumpaLock.version + '-source.zip')
    Write-MumpaSourceArchive $mumpaSource $mumpaPatchedZip
    Write-Output "Corresponding source SHA256 $(Get-MumpaHash $mumpaPatchedZip)"
} finally {
    foreach ($mumpaKey in $mumpaEnvironmentKeys) { [Environment]::SetEnvironmentVariable($mumpaKey, $mumpaEnvironment[$mumpaKey], 'Process') }
}
