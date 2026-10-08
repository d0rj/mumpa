param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\assets\jackett')
)

$ErrorActionPreference = 'Stop'
$jackettVersion = '0.24.2806'
$expectedHash = '19c15d76c61979768c98c3e381aea5af95188b54e56d5fc1d9d0c76c9b784305'
$assetDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$assetPath = Join-Path $assetDirectory 'Jackett.Binaries.Windows.zip'
New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null

if ((Test-Path -LiteralPath $assetPath) -and
    ((Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedHash)) {
    Write-Output "Jackett $jackettVersion archive verified: $assetPath"
    exit 0
}

$partialPath = "$assetPath.partial"
$downloadUrl = "https://github.com/Jackett/Jackett/releases/download/v$jackettVersion/Jackett.Binaries.Windows.zip"
Invoke-WebRequest -Uri $downloadUrl -OutFile $partialPath
if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw 'Jackett download checksum mismatch; the existing archive was preserved.'
}

# Resolve the exact destination before replacing the single bundled asset.
if ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($assetPath)) -ne $assetDirectory) {
    throw 'Jackett archive destination escaped its asset directory.'
}
Move-Item -LiteralPath $partialPath -Destination $assetPath -Force
Write-Output "Jackett $jackettVersion archive prepared: $assetPath"
