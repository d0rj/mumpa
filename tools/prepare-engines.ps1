param([ValidateSet('all','windows','android')][string]$Platform = 'all')
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
$mumpaVersion = 'MatriX.145.2'
$mumpaAssets = @(
    @{ platform='windows'; asset='TorrServer-windows-amd64.exe'; path='assets/engine/TorrServer.exe'; sha='778bbc9bffb2e4d837a3a2c470fc2a4048d30f0a2004eb2553cd4a495b1bb2d6' },
    @{ platform='android'; asset='TorrServer-android-arm64'; path='android/app/src/main/jniLibs/arm64-v8a/libtorrserver.so'; sha='44ef08f4e02fd325af63803617a27260eaeafc7385a47e9e6e244e98cc9cd5f6' },
    @{ platform='android'; asset='TorrServer-android-amd64'; path='android/app/src/main/jniLibs/x86_64/libtorrserver.so'; sha='66c51578a93a1d4b3e4ea3a25b4848e5e96032e0fb52564b6ba057700c09873e' },
    @{ platform='android'; asset='TorrServer-android-arm7'; path='android/app/src/main/jniLibs/armeabi-v7a/libtorrserver.so'; sha='e0a25847f439ece85e4e9dad152b9624a455a1f5f9ddf01ee51a72c15a4be46d' }
)
foreach ($mumpaAsset in $mumpaAssets) {
    if ($Platform -ne 'all' -and $mumpaAsset.platform -ne $Platform) { continue }
    $mumpaTarget = Join-Path $mumpaRoot $mumpaAsset.path
    if ((Test-Path -LiteralPath $mumpaTarget) -and (Get-FileHash -LiteralPath $mumpaTarget -Algorithm SHA256).Hash.ToLowerInvariant() -eq $mumpaAsset.sha) {
        Write-Output "Verified $($mumpaAsset.asset)"
        continue
    }
    New-Item -ItemType Directory -Force (Split-Path $mumpaTarget -Parent) | Out-Null
    $mumpaPartial = "$mumpaTarget.download"
    Invoke-WebRequest "https://github.com/YouROK/TorrServer/releases/download/$mumpaVersion/$($mumpaAsset.asset)" -OutFile $mumpaPartial
    if ((Get-FileHash -LiteralPath $mumpaPartial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $mumpaAsset.sha) { throw "SHA256 mismatch: $($mumpaAsset.asset)" }
    Move-Item -LiteralPath $mumpaPartial -Destination $mumpaTarget -Force
    Write-Output "Downloaded and verified $($mumpaAsset.asset)"
}
