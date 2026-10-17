#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$mumpaProject = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'workspace-maintenance.ps1')
$mumpaTestBase = Join-Path $mumpaProject ('test-output/maintenance-test-' + [Guid]::NewGuid().ToString('N'))
$mumpaAssertions = 0
function Assert-Maintenance([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:mumpaAssertions++
}
function Write-Fixture([string]$Path, [string]$Text = 'fixture') {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}
function New-TestWorkspace([string]$Name) {
    $mumpaFixtureRoot = Join-Path $mumpaTestBase $Name
    Write-Fixture (Join-Path $mumpaFixtureRoot 'pubspec.yaml') "name: mumpa`nversion: 1.2.20+28`n"
    Write-Fixture (Join-Path $mumpaFixtureRoot 'lib/main.dart')
    foreach ($mumpaFile in @('clean-workspace.ps1','workspace-maintenance.ps1','package-release.ps1','build-managed-engine.ps1','install-windows.ps1','uninstall-windows.ps1','Install Mumpa.cmd')) {
        New-Item -ItemType Directory -Path (Join-Path $mumpaFixtureRoot 'tools') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $mumpaFile) -Destination (Join-Path $mumpaFixtureRoot 'tools')
    }
    return $mumpaFixtureRoot
}
function New-TestRelease([string]$Root, [string]$Version) {
    $mumpaRelease = Join-Path $Root "artifacts/release-$Version"
    $mumpaRecords = @(foreach ($mumpaSuffix in @('windows-x64.zip','android-arm64.apk','android-armv7.apk','android-x86_64.apk','android-symbols.zip')) {
        $mumpaName = "Mumpa-$Version-$mumpaSuffix"
        $mumpaPath = Join-Path $mumpaRelease $mumpaName
        Write-Fixture $mumpaPath "package $Version $mumpaSuffix"
        [ordered]@{ file=$mumpaName; bytes=(Get-Item -LiteralPath $mumpaPath).Length; sha256=(Get-FileHash -LiteralPath $mumpaPath).Hash.ToLowerInvariant() }
    })
    Write-Fixture (Join-Path $mumpaRelease 'SHA256.json') (ConvertTo-Json -InputObject $mumpaRecords)
    return $mumpaRelease
}
function Add-TestBuild([string]$Root) {
    foreach ($mumpaPath in @('build/windows/x64/runner/Release/mumpa.exe','build/app/outputs/flutter-apk/app-arm64-v8a-release.apk','build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk','build/app/outputs/flutter-apk/app-x86_64-release.apk','build/android-symbols/app.android-arm.symbols','build/android-symbols/app.android-arm64.symbols','build/android-symbols/app.android-x64.symbols','.dart_tool/cache.bin','docs/fixture.md','LICENSE','THIRD_PARTY_NOTICES.md','README.md')) {
        Write-Fixture (Join-Path $Root $mumpaPath)
    }
}
try {
    $mumpaFixture = New-TestWorkspace 'clean'
    $mumpaOld = New-TestRelease $mumpaFixture '1.2.9'
    $mumpaLatest = New-TestRelease $mumpaFixture '1.2.19'
    $mumpaLatestHash = (Get-FileHash -LiteralPath (Join-Path $mumpaLatest 'Mumpa-1.2.19-windows-x64.zip')).Hash
    foreach ($mumpaPath in @('build/cache.bin','.dart_tool/cache.bin','.local/scratch.txt','windows/flutter/ephemeral/generated','android/.gradle/cache','graphify-out/graph.json','artifacts/Mumpa-1.2.8-windows-x64.zip','artifacts/SHA256.json','artifacts/sources/dependency.zip','test-output/install-test-old/copied.exe','test-output/stripped-engine.so','test-output/update/package.zip.part','test-output/evidence.json','personal-library/music.flac')) {
        Write-Fixture (Join-Path $mumpaFixture $mumpaPath)
    }
    & (Join-Path $mumpaFixture 'tools/clean-workspace.ps1') -WhatIf | Out-Null
    Assert-Maintenance (Test-Path -LiteralPath $mumpaOld) 'WhatIf removed an old release'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaFixture '.local/scratch.txt')) 'WhatIf removed temporary files'
    & (Join-Path $mumpaFixture 'tools/clean-workspace.ps1') | Out-Null
    foreach ($mumpaRemoved in @('build','.dart_tool','.local','windows/flutter/ephemeral','android/.gradle','graphify-out','artifacts/release-1.2.9','artifacts/Mumpa-1.2.8-windows-x64.zip','artifacts/SHA256.json','test-output/install-test-old','test-output/stripped-engine.so','test-output/update/package.zip.part')) {
        Assert-Maintenance (-not (Test-Path -LiteralPath (Join-Path $mumpaFixture $mumpaRemoved))) "Not cleaned: $mumpaRemoved"
    }
    foreach ($mumpaKept in @('lib/main.dart','artifacts/sources/dependency.zip','test-output/evidence.json','personal-library/music.flac')) {
        Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaFixture $mumpaKept)) "Removed durable file: $mumpaKept"
    }
    Assert-Maintenance ((Get-FileHash -LiteralPath (Join-Path $mumpaLatest 'Mumpa-1.2.19-windows-x64.zip')).Hash -eq $mumpaLatestHash) 'Latest release changed'
    & (Join-Path $mumpaFixture 'tools/clean-workspace.ps1') | Out-Null
    Assert-Maintenance (Test-Path -LiteralPath $mumpaLatest) 'Repeated cleanup removed latest release'

    $mumpaBroken = New-TestWorkspace 'incomplete'
    $mumpaPrevious = New-TestRelease $mumpaBroken '1.2.19'
    $mumpaIncomplete = New-TestRelease $mumpaBroken '1.2.20'
    Write-Fixture (Join-Path $mumpaIncomplete 'Mumpa-1.2.20-android-arm64.apk') 'corrupted'
    Write-Fixture (Join-Path $mumpaBroken 'build/preserved.bin')
    $mumpaRejected = $false
    try { & (Join-Path $mumpaBroken 'tools/clean-workspace.ps1') | Out-Null } catch { $mumpaRejected = $true }
    Assert-Maintenance $mumpaRejected 'Corrupt latest release was accepted'
    Assert-Maintenance (Test-Path -LiteralPath $mumpaPrevious) 'Corrupt release deleted the previous release'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaBroken 'build/preserved.bin')) 'Plan was partly executed before validation'

    $mumpaLinks = New-TestWorkspace 'links'
    $mumpaOutside = Join-Path $mumpaTestBase 'outside'
    Write-Fixture (Join-Path $mumpaOutside 'keep.txt')
    New-Item -ItemType Junction -Path (Join-Path $mumpaLinks 'build') -Target $mumpaOutside | Out-Null
    $mumpaRejected = $false
    try { & (Join-Path $mumpaLinks 'tools/clean-workspace.ps1') -BuildCaches | Out-Null } catch { $mumpaRejected = $true }
    Assert-Maintenance $mumpaRejected 'Top-level junction was accepted'
    Remove-Item -LiteralPath (Join-Path $mumpaLinks 'build') -Force
    New-Item -ItemType Directory -Path (Join-Path $mumpaLinks 'build') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $mumpaLinks 'build/nested') -Target $mumpaOutside | Out-Null
    & (Join-Path $mumpaLinks 'tools/clean-workspace.ps1') -BuildCaches | Out-Null
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaOutside 'keep.txt')) 'Nested junction target was traversed'
    foreach ($mumpaUnsafe in @($mumpaLinks, $mumpaOutside, (Join-Path $mumpaLinks '../outside/keep.txt'))) {
        $mumpaRejected = $false
        try { Remove-MumpaGeneratedPath $mumpaLinks $mumpaUnsafe } catch { $mumpaRejected = $true }
        Assert-Maintenance $mumpaRejected 'Workspace escape/root deletion was accepted'
    }

    $mumpaPack = New-TestWorkspace 'package'
    $mumpaPrevious = New-TestRelease $mumpaPack '1.2.19'
    Add-TestBuild $mumpaPack
    function Compress-Archive { throw 'Injected packaging failure' }
    $mumpaRejected = $false
    try { & (Join-Path $mumpaPack 'tools/package-release.ps1') | Out-Null } catch { $mumpaRejected = $true }
    Remove-Item Function:\Compress-Archive
    Assert-Maintenance $mumpaRejected 'Injected packaging failure did not fail'
    Assert-Maintenance (Test-Path -LiteralPath $mumpaPrevious) 'Failed packaging removed previous release'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaPack 'build')) 'Failed packaging removed build inputs'
    Assert-Maintenance (@(Get-ChildItem -LiteralPath (Join-Path $mumpaPack 'artifacts') -Force -Filter '.package-*').Count -eq 0) 'Failed packaging left staging files'
    & (Join-Path $mumpaPack 'tools/package-release.ps1') | Out-Null
    Assert-Maintenance (-not (Test-Path -LiteralPath $mumpaPrevious)) 'Successful packaging retained previous release'
    Assert-Maintenance (-not (Test-Path -LiteralPath (Join-Path $mumpaPack 'build'))) 'Packaging retained build cache'
    Assert-Maintenance (-not (Test-Path -LiteralPath (Join-Path $mumpaPack '.dart_tool'))) 'Packaging retained Dart cache'
    Assert-MumpaRelease $mumpaPack (Join-Path $mumpaPack 'artifacts/release-1.2.20') '1.2.20'
    $mumpaAssertions++
    # Repack the same version and retain cache explicitly; source files survive.
    Add-TestBuild $mumpaPack
    Write-Fixture (Join-Path $mumpaPack 'artifacts/release-1.2.20/sources/source.zip')
    & (Join-Path $mumpaPack 'tools/package-release.ps1') -KeepBuildCache | Out-Null
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaPack 'build')) 'KeepBuildCache was ignored'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaPack 'artifacts/release-1.2.20/sources/source.zip')) 'Repack lost corresponding sources'
    Assert-Maintenance (@(Get-ChildItem -LiteralPath (Join-Path $mumpaPack 'artifacts') -Force | Where-Object { $_.Name -match '^\.(package|previous)-' }).Count -eq 0) 'Packaging left transaction directories'

    # The fixed CI directory participates in retention and drops old sources.
    $mumpaCiOutput = Join-Path $mumpaPack 'artifacts/ci-release'
    Write-Fixture (Join-Path $mumpaCiOutput 'sources/Mumpa-1.2.20-source.zip')
    Write-Fixture (Join-Path $mumpaCiOutput 'sources/Mumpa-1.2.21-source.zip')
    & (Join-Path $mumpaPack 'tools/package-release.ps1') -Version '1.2.21' -OutputDirectory $mumpaCiOutput -KeepBuildCache | Out-Null
    Assert-Maintenance (-not (Test-Path -LiteralPath (Join-Path $mumpaPack 'artifacts/release-1.2.20'))) 'CI packaging retained previous release'
    Assert-Maintenance (-not (Test-Path -LiteralPath (Join-Path $mumpaCiOutput 'sources/Mumpa-1.2.20-source.zip'))) 'CI packaging retained previous sources'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaCiOutput 'sources/Mumpa-1.2.21-source.zip')) 'CI packaging lost current sources'
    & (Join-Path $mumpaPack 'tools/clean-workspace.ps1') -Releases | Out-Null
    Assert-Maintenance (Test-Path -LiteralPath $mumpaCiOutput) 'Manual cleanup lost the latest CI release'
    $null = New-TestRelease $mumpaPack '1.2.22'
    & (Join-Path $mumpaPack 'tools/clean-workspace.ps1') -Releases | Out-Null
    Assert-Maintenance (-not (Test-Path -LiteralPath $mumpaCiOutput)) 'Manual cleanup retained the old CI release'

    $mumpaEngine = New-TestWorkspace 'engine-failure'
    $mumpaBadArchive = Join-Path $mumpaEngine 'artifacts/source.zip'
    Write-Fixture $mumpaBadArchive 'invalid zip'
    $mumpaLock = @{ upstream=@{ archive='artifacts/source.zip'; commit='fixture'; sha256=(Get-FileHash -LiteralPath $mumpaBadArchive).Hash.ToLowerInvariant() } }
    Write-Fixture (Join-Path $mumpaEngine 'engine-patches/managed-engine.lock.json') ($mumpaLock | ConvertTo-Json)
    $mumpaRejected = $false
    try { & (Join-Path $mumpaEngine 'tools/build-managed-engine.ps1') -GoExecutable (Get-Process -Id $PID).Path | Out-Null } catch { $mumpaRejected = $true }
    Assert-Maintenance $mumpaRejected 'Invalid source archive was accepted'
    Assert-Maintenance (@(Get-ChildItem -LiteralPath (Join-Path $mumpaEngine '.local/engine-build') -Directory -Filter 'run-*').Count -eq 0) 'Early engine failure left a run directory'
    try { & (Join-Path $mumpaEngine 'tools/build-managed-engine.ps1') -GoExecutable (Get-Process -Id $PID).Path -KeepWorkDirectory | Out-Null } catch { }
    Assert-Maintenance (@(Get-ChildItem -LiteralPath (Join-Path $mumpaEngine '.local/engine-build') -Directory -Filter 'run-*').Count -eq 1) 'KeepWorkDirectory was ignored'

    # Exercise the successful engine path with a local compiler stand-in.
    $mumpaEngineOk = New-TestWorkspace 'engine-success'
    $mumpaSource = Join-Path $mumpaEngineOk 'fixture/TorrServer-fixture'
    Write-Fixture (Join-Path $mumpaSource 'server/go.mod') 'module fixture'
    Write-Fixture (Join-Path $mumpaSource 'server/go.sum') 'fixture sum'
    Write-Fixture (Join-Path $mumpaEngineOk 'engine-patches/README.md')
    $mumpaArchive = Join-Path $mumpaEngineOk 'artifacts/source.zip'
    New-Item -ItemType Directory -Path (Split-Path $mumpaArchive -Parent) -Force | Out-Null
    Compress-Archive -LiteralPath $mumpaSource -DestinationPath $mumpaArchive
    $mumpaBinary = Join-Path $mumpaEngineOk 'fixture/binary'
    Write-Fixture $mumpaBinary 'compiled fixture'
    $mumpaCompiler = Join-Path $mumpaEngineOk 'tools/compiler-fixture.ps1'
    Write-Fixture $mumpaCompiler @'
if ($args[0] -eq 'build') {
    $outputIndex = [Array]::IndexOf($args, '-o')
    [IO.File]::WriteAllText($args[$outputIndex + 1], 'compiled fixture')
}
$global:LASTEXITCODE = 0
'@
    $mumpaSuccessLock = @{
        version='fixture'; upstream=@{archive='artifacts/source.zip';commit='fixture';sha256=(Get-FileHash -LiteralPath $mumpaArchive).Hash.ToLowerInvariant()}
        modules=@(@{path='server/go.mod';sha256=(Get-FileHash -LiteralPath (Join-Path $mumpaSource 'server/go.mod')).Hash.ToLowerInvariant()},@{path='server/go.sum';sha256=(Get-FileHash -LiteralPath (Join-Path $mumpaSource 'server/go.sum')).Hash.ToLowerInvariant()})
        overlays=@(); toolchains=@{windows='fixture'}
        targets=@(@{id='windows';platform='windows';goos='windows';goarch='amd64';cgo='0';goamd64='v1';path='assets/engine/fixture.exe';toolchain='fixture';sha256=(Get-FileHash -LiteralPath $mumpaBinary).Hash.ToLowerInvariant()})
    }
    Write-Fixture (Join-Path $mumpaEngineOk 'engine-patches/managed-engine.lock.json') ($mumpaSuccessLock | ConvertTo-Json -Depth 5)
    $mumpaOriginalGoEnvironment = [Environment]::GetEnvironmentVariable('GOMAXPROCS', 'Process')
    & (Join-Path $mumpaEngineOk 'tools/build-managed-engine.ps1') -Platform windows -SkipTests -GoExecutable $mumpaCompiler | Out-Null
    Assert-Maintenance (@(Get-ChildItem -LiteralPath (Join-Path $mumpaEngineOk '.local/engine-build') -Directory -Filter 'run-*').Count -eq 0) 'Successful engine build left a run directory'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaEngineOk 'assets/engine/fixture.exe')) 'Successful engine output disappeared'
    Assert-Maintenance (Test-Path -LiteralPath (Join-Path $mumpaEngineOk 'artifacts/TorrServer-fixture-source.zip')) 'Corresponding source archive disappeared'
    Assert-Maintenance ([Environment]::GetEnvironmentVariable('GOMAXPROCS', 'Process') -eq $mumpaOriginalGoEnvironment) 'Engine environment was not restored'
    Write-Output "PASS: $mumpaAssertions assertions (real file cleanup, hashes, retention, WhatIf, junctions, transaction failure/repack, engine failure cleanup)."
} finally {
    Remove-MumpaGeneratedPath $mumpaProject $mumpaTestBase
}
