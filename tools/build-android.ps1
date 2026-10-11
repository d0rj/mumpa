$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $mumpaRoot
try {
    # Keep Dart debug information beside the APKs, without obfuscating names.
    # package-release.ps1 publishes the matching symbols for crash diagnosis.
    & flutter build apk --release --split-per-abi --split-debug-info=build/android-symbols
    if ($LASTEXITCODE -ne 0) { throw "Android build failed with exit code $LASTEXITCODE" }
    foreach ($mumpaTarget in @('arm','arm64','x64')) {
        if (!(Test-Path -LiteralPath "build/android-symbols/app.android-$mumpaTarget.symbols")) {
            throw "Missing Android $mumpaTarget debug symbols"
        }
    }
} finally { Pop-Location }
