param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\assets\jackett'),
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\artifacts\sources')
)

$ErrorActionPreference = 'Stop'
$jackettVersion = '0.24.2806'
$expectedHash = '19c15d76c61979768c98c3e381aea5af95188b54e56d5fc1d9d0c76c9b784305'
$sourceHash = '2c7b2058a7cb7815041a63f590dea5405be4eafc2814be6df6a7567904b1032c'
$assetDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$assetPath = Join-Path $assetDirectory 'Jackett.Binaries.Windows.zip'
New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
$sourceDirectoryPath = [System.IO.Path]::GetFullPath($SourceDirectory)
New-Item -ItemType Directory -Path $sourceDirectoryPath -Force | Out-Null

function Get-JackettArchive([string]$Url, [string]$Destination, [string]$Hash) {
    if ((Test-Path -LiteralPath $Destination) -and
        ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Hash)) {
        Write-Output "Jackett $jackettVersion archive verified: $Destination"
        return
    }
    $partialPath = "$Destination.partial"
    Invoke-WebRequest -Uri $Url -OutFile $partialPath
    if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        throw 'Jackett download checksum mismatch; the existing archive was preserved.'
    }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination)) -ne
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($partialPath))) {
        throw 'Jackett archive destination escaped its directory.'
    }
    Move-Item -LiteralPath $partialPath -Destination $Destination -Force
    Write-Output "Jackett $jackettVersion archive prepared: $Destination"
}

Get-JackettArchive -Destination $assetPath -Hash $expectedHash `
    -Url "https://github.com/Jackett/Jackett/releases/download/v$jackettVersion/Jackett.Binaries.Windows.zip"
Get-JackettArchive -Destination (Join-Path $sourceDirectoryPath "Jackett-$jackettVersion-source.zip") -Hash $sourceHash `
    -Url "https://codeload.github.com/Jackett/Jackett/zip/refs/tags/v$jackettVersion"
