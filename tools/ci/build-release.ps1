param(
    [Parameter(Mandatory)][string]$GoExecutable,
    [Parameter(Mandatory)][string]$AndroidNdk
)

$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location -LiteralPath $mumpaRoot

function Invoke-CiCommand([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}

$mumpaVersionLine = Get-Content -LiteralPath 'pubspec.yaml' | Where-Object { $_ -match '^version:\s*' }
$mumpaVersion = ($mumpaVersionLine -replace '^version:\s*', '').Trim()
if ($mumpaVersion -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?\+\d+$') { throw 'Expected version+build in pubspec.yaml' }
$mumpaBuildName = $mumpaVersion.Split('+')[0]
$mumpaLock = Get-Content -LiteralPath 'engine-patches/managed-engine.lock.json' -Raw | ConvertFrom-Json

# This runs the engine regressions and verifies all four binary hashes against
# the lock. Never refresh the lock or upgrade dependencies in a release job.
& ./tools/build-managed-engine.ps1 -Platform all -GoExecutable $GoExecutable -AndroidNdk $AndroidNdk
& ./tools/prepare-jackett.ps1
& ./tools/prepare-flaresolverr.ps1
Invoke-CiCommand 'flutter' @('pub', 'get', '--enforce-lockfile')
# Each build must refresh native plugin registration for its own release mode.
# --no-pub can retain integration_test in GeneratedPluginRegistrant.java even
# after an ordinary pub get, while Gradle excludes that plugin from release.
Invoke-CiCommand 'flutter' @('build', 'windows', '--release')
& ./tools/test-install-windows.ps1
& ./tools/build-android.ps1
Invoke-CiCommand 'git' @('diff', '--exit-code', '--', 'pubspec.lock')

$mumpaOutput = Join-Path $mumpaRoot 'artifacts/ci-release'
$mumpaSourceOutput = Join-Path $mumpaOutput 'sources'
New-Item -ItemType Directory -Path $mumpaSourceOutput -Force | Out-Null
Invoke-CiCommand 'git' @('archive', '--format=zip', "--prefix=Mumpa-$mumpaBuildName/", "--output=$mumpaSourceOutput/Mumpa-$mumpaBuildName-source.zip", 'HEAD')
foreach ($mumpaSource in @(
    $mumpaLock.upstream.archive,
    "artifacts/TorrServer-$($mumpaLock.version)-source.zip",
    'artifacts/sources/Jackett-0.24.2806-source.zip',
    'artifacts/sources/FlareSolverr-v3.5.2-source.zip'
)) {
    Copy-Item -LiteralPath $mumpaSource -Destination $mumpaSourceOutput -Force
}
& ./tools/package-release.ps1 -Version $mumpaBuildName -OutputDirectory $mumpaOutput
$mumpaCommit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine source commit' }
[ordered]@{
    version = $mumpaVersion
    commit = $mumpaCommit
    engine = $mumpaLock.version
    toolchains = $mumpaLock.toolchains
    flutter = '3.44.4'
    androidSigning = if ($env:MUMPA_KEYSTORE_PATH) { 'release-keystore' } else { 'ephemeral-debug-key' }
    githubRun = $env:GITHUB_RUN_ID
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $mumpaOutput 'BUILD.json') -Encoding utf8
if ($env:GITHUB_OUTPUT) {
    "version=$mumpaBuildName" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
    "build-version=$mumpaVersion" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
}
