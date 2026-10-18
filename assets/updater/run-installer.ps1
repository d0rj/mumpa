param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [Parameter(Mandatory=$true)][string]$ZipPath,
    [Parameter(Mandatory=$true)][string]$Sha256,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$StatusPath,
    [Parameter(Mandatory=$true)][string]$LogPath,
    [int]$WaitForProcessId = 0,
    [string]$InstallDirectory,
    [switch]$NoRegistration,
    [switch]$Launch
)
# Keep this launcher ASCII-only: it must report errors even if an inner helper
# cannot be parsed by Windows PowerShell 5.1 before its own try/catch starts.
$ErrorActionPreference = 'Stop'
function Write-LauncherStatus([string]$State, [string]$Message = '') {
    $temporary = $StatusPath + '.tmp'
    [ordered]@{ state=$State; message=$Message; version=$Version } | ConvertTo-Json |
        Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $StatusPath -Force
}
try {
    'Mumpa Windows installer launcher' | Set-Content -LiteralPath $LogPath -Encoding utf8
    Write-LauncherStatus 'starting'
    # A Flutter/PowerShell 7 host can pass its own module search path. Load the
    # Windows PowerShell utility functions (including Get-FileHash) explicitly.
    Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Force
    $parameters = @{
        ZipPath=$ZipPath; Sha256=$Sha256; Version=$Version
        WaitForProcessId=$WaitForProcessId; StatusPath=$StatusPath
    }
    if ($InstallDirectory) { $parameters.InstallDirectory = $InstallDirectory }
    if ($NoRegistration) { $parameters.NoRegistration = $true }
    if ($Launch) { $parameters.Launch = $true }
    & $InstallerPath @parameters *>&1 | Out-File -LiteralPath $LogPath -Encoding utf8 -Append
} catch {
    ($_ | Out-String) | Add-Content -LiteralPath $LogPath -Encoding utf8
    Write-LauncherStatus 'failed' $_.Exception.Message
    exit 1
}
