param([ValidateSet('all','windows','android')][string]$Platform = 'all')
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
$mumpaLock = Get-Content -LiteralPath (Join-Path $mumpaRoot 'engine-patches/managed-engine.lock.json') -Raw | ConvertFrom-Json
$mumpaNeedsBuild = $false
foreach ($mumpaTarget in $mumpaLock.targets) {
    if ($Platform -ne 'all' -and $mumpaTarget.platform -ne $Platform) { continue }
    $mumpaPath = Join-Path $mumpaRoot $mumpaTarget.path
    if ((Test-Path -LiteralPath $mumpaPath) -and (Get-FileHash -LiteralPath $mumpaPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $mumpaTarget.sha256) {
        Write-Output "Verified $($mumpaTarget.id) $($mumpaLock.version)"
    } else { $mumpaNeedsBuild = $true }
}
if ($mumpaNeedsBuild) {
    # Official unpatched release downloads would reintroduce the reader leak.
    & (Join-Path $PSScriptRoot 'build-managed-engine.ps1') -Platform $Platform
}
