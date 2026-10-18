param(
    [string]$BuildName = '',
    [string]$BuildNumber = ''
)
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'android-signing.ps1')
$mumpaSigning = Get-MumpaAndroidSigning
if ($BuildName -and $BuildName -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Invalid Android build name.' }
if ($BuildNumber -and $BuildNumber -notmatch '^\d+$') { throw 'Invalid Android build number.' }
Push-Location -LiteralPath $mumpaRoot
try {
    # Keep Dart debug information beside the APKs, without obfuscating names.
    # package-release.ps1 publishes the matching symbols for crash diagnosis.
    Invoke-WithMumpaAndroidSigning $mumpaSigning {
        $mumpaArguments = @('build','apk','--release','--target','lib/main.dart','--split-per-abi','--split-debug-info=build/android-symbols')
        if ($BuildName) { $mumpaArguments += "--build-name=$BuildName" }
        if ($BuildNumber) { $mumpaArguments += "--build-number=$BuildNumber" }
        & flutter @mumpaArguments
        if ($LASTEXITCODE -ne 0) { throw "Android build failed with exit code $LASTEXITCODE" }
    }
    foreach ($mumpaTarget in @('arm','arm64','x64')) {
        if (!(Test-Path -LiteralPath "build/android-symbols/app.android-$mumpaTarget.symbols")) {
            throw "Missing Android $mumpaTarget debug symbols"
        }
    }
    Assert-MumpaApkSignatures $mumpaRoot
} finally { Pop-Location }
