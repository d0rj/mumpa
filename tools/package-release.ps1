#requires -Version 7.0
param(
    [string]$Version = '',
    [string]$OutputDirectory = '',
    [switch]$KeepBuildCache
)
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'workspace-maintenance.ps1')
if (-not $Version) {
    $mumpaVersionLine = Get-Content -LiteralPath (Join-Path $mumpaRoot 'pubspec.yaml') | Where-Object { $_ -match '^version:\s*' }
    $Version = ($mumpaVersionLine -replace '^version:\s*', '').Split('+')[0].Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Invalid release version.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $mumpaRoot "artifacts/release-$Version" }
$mumpaArtifacts = Resolve-MumpaGeneratedPath $mumpaRoot (Join-Path $mumpaRoot 'artifacts')
$mumpaDestinationOutput = Resolve-MumpaGeneratedPath $mumpaArtifacts $OutputDirectory
$mumpaWindows = Join-Path $mumpaRoot 'build/windows/x64/runner/Release'
$mumpaApks = Join-Path $mumpaRoot 'build/app/outputs/flutter-apk'
if (!(Test-Path -LiteralPath (Join-Path $mumpaWindows 'mumpa.exe'))) { throw 'Build Windows release first.' }
foreach ($mumpaAbi in @('arm64-v8a','armeabi-v7a','x86_64')) {
    if (!(Test-Path -LiteralPath (Join-Path $mumpaApks "app-$mumpaAbi-release.apk"))) { throw "Build Android $mumpaAbi first." }
}
$mumpaSymbols = @('arm','arm64','x64') | ForEach-Object {
    $mumpaSymbol = Join-Path $mumpaRoot "build/android-symbols/app.android-$_.symbols"
    if (!(Test-Path -LiteralPath $mumpaSymbol)) { throw 'Build Android with tools/build-android.ps1 first.' }
    $mumpaSymbol
}
$mumpaOutput = Join-Path $mumpaArtifacts ('.package-' + [Guid]::NewGuid().ToString('N'))
$mumpaBackup = Join-Path $mumpaArtifacts ('.previous-' + [Guid]::NewGuid().ToString('N'))
$mumpaPromoted = $false
try {
New-Item -ItemType Directory -Force -Path $mumpaOutput | Out-Null
$mumpaExistingSources = Join-Path $mumpaDestinationOutput 'sources'
if (Test-Path -LiteralPath $mumpaExistingSources) {
    $null = Resolve-MumpaGeneratedPath $mumpaRoot $mumpaExistingSources
    $mumpaSourceOutput = Join-Path $mumpaOutput 'sources'
    New-Item -ItemType Directory -Path $mumpaSourceOutput | Out-Null
    $mumpaLockPath = Join-Path $mumpaRoot 'engine-patches/managed-engine.lock.json'
    $mumpaSourceLock = if (Test-Path -LiteralPath $mumpaLockPath) { Get-Content -LiteralPath $mumpaLockPath -Raw | ConvertFrom-Json } else { $null }
    foreach ($mumpaSourceFile in Get-ChildItem -LiteralPath $mumpaExistingSources -File) {
        if ($mumpaSourceFile.Name -like 'Mumpa-*-source.zip' -and $mumpaSourceFile.Name -ne "Mumpa-$Version-source.zip") { continue }
        if ($mumpaSourceLock -and $mumpaSourceFile.Name -like 'TorrServer-*-source.zip' -and
            $mumpaSourceFile.Name -notin @([IO.Path]::GetFileName($mumpaSourceLock.upstream.archive), "TorrServer-$($mumpaSourceLock.version)-source.zip")) { continue }
        Copy-Item -LiteralPath $mumpaSourceFile.FullName -Destination $mumpaSourceOutput
    }
}
$mumpaStage = Join-Path $mumpaOutput "Mumpa-$Version-windows-x64"
if (Test-Path -LiteralPath $mumpaStage) {
    $mumpaResolved = (Resolve-Path -LiteralPath $mumpaStage).Path
    $mumpaExpected = [IO.Path]::GetFullPath($mumpaOutput) + [IO.Path]::DirectorySeparatorChar
    if (!$mumpaResolved.StartsWith($mumpaExpected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid staging directory.' }
    Remove-Item -LiteralPath $mumpaResolved -Recurse -Force
}
$mumpaApp = Join-Path $mumpaStage 'Mumpa'
New-Item -ItemType Directory -Force -Path $mumpaApp | Out-Null
Get-ChildItem -LiteralPath $mumpaWindows | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $mumpaApp -Recurse -Force }
foreach ($mumpaNotice in @('LICENSE','THIRD_PARTY_NOTICES.md','README.md')) {
    Copy-Item -LiteralPath (Join-Path $mumpaRoot $mumpaNotice) -Destination $mumpaApp
}
Copy-Item -LiteralPath (Join-Path $mumpaRoot 'docs') -Destination $mumpaApp -Recurse -Force
$mumpaInstallTools = Join-Path $mumpaApp 'tools'
New-Item -ItemType Directory -Force -Path $mumpaInstallTools | Out-Null
foreach ($mumpaTool in @('install-windows.ps1','uninstall-windows.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $mumpaTool) -Destination $mumpaInstallTools -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install Mumpa.cmd') -Destination $mumpaApp -Force
Compress-Archive -LiteralPath $mumpaApp -DestinationPath (Join-Path $mumpaOutput "Mumpa-$Version-windows-x64.zip") -Force
Copy-Item -LiteralPath (Join-Path $mumpaApks 'app-arm64-v8a-release.apk') -Destination (Join-Path $mumpaOutput "Mumpa-$Version-android-arm64.apk") -Force
Copy-Item -LiteralPath (Join-Path $mumpaApks 'app-armeabi-v7a-release.apk') -Destination (Join-Path $mumpaOutput "Mumpa-$Version-android-armv7.apk") -Force
Copy-Item -LiteralPath (Join-Path $mumpaApks 'app-x86_64-release.apk') -Destination (Join-Path $mumpaOutput "Mumpa-$Version-android-x86_64.apk") -Force
Compress-Archive -LiteralPath $mumpaSymbols -DestinationPath (Join-Path $mumpaOutput "Mumpa-$Version-android-symbols.zip") -Force
$mumpaReleaseFiles = @(Get-ChildItem -LiteralPath $mumpaOutput -File | Where-Object { $_.Extension -in @('.zip','.apk') })
$mumpaSourceFolder = Join-Path $mumpaOutput 'sources'
if (Test-Path -LiteralPath $mumpaSourceFolder) {
    $mumpaReleaseFiles += @(Get-ChildItem -LiteralPath $mumpaSourceFolder -File -Filter '*.zip')
}
$mumpaManifest = $mumpaReleaseFiles | ForEach-Object {
    [ordered]@{ file=$_.FullName.Substring($mumpaOutput.Length+1).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$mumpaManifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $mumpaOutput 'SHA256.json') -Encoding utf8
Assert-MumpaRelease $mumpaRoot $mumpaOutput $Version
if (Test-Path -LiteralPath $mumpaDestinationOutput) {
    # Both absolute paths have been checked inside this workspace's artifacts.
    $null = Resolve-MumpaGeneratedPath $mumpaRoot $mumpaBackup
    Move-Item -LiteralPath $mumpaDestinationOutput -Destination $mumpaBackup
}
try {
    $null = Resolve-MumpaGeneratedPath $mumpaRoot $mumpaDestinationOutput
    Move-Item -LiteralPath $mumpaOutput -Destination $mumpaDestinationOutput
    $mumpaPromoted = $true
} catch {
    if (Test-Path -LiteralPath $mumpaBackup) {
        Move-Item -LiteralPath $mumpaBackup -Destination $mumpaDestinationOutput
    }
    throw
}
# Preserve the previous good release until all new packages and hashes exist.
& (Join-Path $PSScriptRoot 'clean-workspace.ps1') -Releases -KeepReleaseDirectory $mumpaDestinationOutput
if (-not $KeepBuildCache) { & (Join-Path $PSScriptRoot 'clean-workspace.ps1') -BuildCaches }
$mumpaManifest | Format-Table -AutoSize
} finally {
    Remove-MumpaGeneratedPath $mumpaRoot $mumpaOutput
    if ($mumpaPromoted) { Remove-MumpaGeneratedPath $mumpaRoot $mumpaBackup }
}
