param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\assets\flaresolverr'),
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\artifacts\sources')
)
$ErrorActionPreference = 'Stop'
$flareVersion = '3.5.2'
$sourceRevision = '93125d6ea6956906c8dfa29e169b2dc67d993dc3'
$binaryHash = '309abd7c821546325ae6c509b40d969c5e39034be2314d21b3f5e0517feda7a7'
$sourceHash = 'cfd9797fa59f43bba74820d0215945fa233fdd5c07377b66f4390b89c93167f1'
$assetDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$sourceDirectoryPath = [System.IO.Path]::GetFullPath($SourceDirectory)
New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $sourceDirectoryPath -Force | Out-Null

function Get-VerifiedArchive {
    param([string]$Url, [string]$Destination, [string]$Hash)
    if ((Test-Path -LiteralPath $Destination) -and
        ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Hash)) {
        Write-Output "Verified: $Destination"
        return
    }
    $partialPath = "$Destination.download"
    Invoke-WebRequest -Uri $Url -OutFile $partialPath
    if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        throw 'Archive checksum mismatch. Existing destination was preserved.'
    }
    # Both move paths are explicit files in this destination's checked directory.
    $resolvedDestination = [System.IO.Path]::GetFullPath($Destination)
    $resolvedPartial = [System.IO.Path]::GetFullPath($partialPath)
    if ([System.IO.Path]::GetDirectoryName($resolvedDestination) -ne
        [System.IO.Path]::GetDirectoryName($resolvedPartial)) {
        throw 'Archive download destination escaped its directory.'
    }
    Move-Item -LiteralPath $resolvedPartial -Destination $resolvedDestination -Force
    Write-Output "Prepared: $Destination"
}

Get-VerifiedArchive `
    -Url "https://github.com/FlareSolverr/FlareSolverr/releases/download/v$flareVersion/flaresolverr_windows_x64.zip" `
    -Destination (Join-Path $assetDirectory 'flaresolverr_windows_x64.zip') -Hash $binaryHash
$runtimePath = Join-Path $assetDirectory 'flaresolverr_windows_x64_runtime.zip'
$runtimeHash = 'de288f2d563764b648b3ce4ed5bc5fad873de49300f2991ba4f13d9a73b9bb6d'
if (!(Test-Path -LiteralPath $runtimePath) -or
    (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtimeHash) {
    & node (Join-Path $PSScriptRoot 'prune-flaresolverr.mjs') (Join-Path $assetDirectory 'flaresolverr_windows_x64.zip') $runtimePath
    if ($LASTEXITCODE -ne 0) { throw 'FlareSolverr runtime preparation failed' }
}
if ((Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtimeHash) {
    throw 'FlareSolverr runtime checksum mismatch'
}
Get-VerifiedArchive `
    -Url "https://codeload.github.com/FlareSolverr/FlareSolverr/zip/$sourceRevision" `
    -Destination (Join-Path $sourceDirectoryPath "FlareSolverr-v$flareVersion-source.zip") -Hash $sourceHash
$licensePath = Join-Path $assetDirectory 'LICENSE.txt'
if (-not (Test-Path -LiteralPath $licensePath)) {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/FlareSolverr/FlareSolverr/$sourceRevision/LICENSE" -OutFile $licensePath
}
