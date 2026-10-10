param([string]$Version = '1.2.0')
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
$mumpaOutput = Join-Path $mumpaRoot 'artifacts'
$mumpaWindows = Join-Path $mumpaRoot 'build/windows/x64/runner/Release'
$mumpaApks = Join-Path $mumpaRoot 'build/app/outputs/flutter-apk'
if (!(Test-Path -LiteralPath (Join-Path $mumpaWindows 'mumpa.exe'))) { throw 'Build Windows release first.' }
foreach ($mumpaAbi in @('arm64-v8a','armeabi-v7a','x86_64')) {
    if (!(Test-Path -LiteralPath (Join-Path $mumpaApks "app-$mumpaAbi-release.apk"))) { throw "Build Android $mumpaAbi first." }
}
New-Item -ItemType Directory -Force -Path $mumpaOutput | Out-Null
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
Compress-Archive -LiteralPath $mumpaApp -DestinationPath (Join-Path $mumpaOutput "Mumpa-$Version-windows-x64.zip") -Force
Copy-Item -LiteralPath (Join-Path $mumpaApks 'app-arm64-v8a-release.apk') -Destination (Join-Path $mumpaOutput "Mumpa-$Version-android-arm64.apk") -Force
Copy-Item -LiteralPath (Join-Path $mumpaApks 'app-armeabi-v7a-release.apk') -Destination (Join-Path $mumpaOutput "Mumpa-$Version-android-armv7.apk") -Force
Copy-Item -LiteralPath (Join-Path $mumpaApks 'app-x86_64-release.apk') -Destination (Join-Path $mumpaOutput "Mumpa-$Version-android-x86_64.apk") -Force
$mumpaReleaseFiles = @(Get-ChildItem -LiteralPath $mumpaOutput -File | Where-Object { $_.Extension -in @('.zip','.apk') })
$mumpaSourceFolder = Join-Path $mumpaOutput 'sources'
if (Test-Path -LiteralPath $mumpaSourceFolder) {
    $mumpaReleaseFiles += @(Get-ChildItem -LiteralPath $mumpaSourceFolder -File -Filter '*.zip')
}
$mumpaManifest = $mumpaReleaseFiles | ForEach-Object {
    [ordered]@{ file=$_.FullName.Substring($mumpaOutput.Length+1).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$mumpaManifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $mumpaOutput 'SHA256.json') -Encoding utf8
$mumpaManifest | Format-Table -AutoSize
