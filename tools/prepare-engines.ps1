param(
    [ValidateSet('all','windows','android')][string]$Platform = 'all',
    [string]$LockFile = ''
)
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path $PSScriptRoot -Parent
$mumpaLockPath = if ($LockFile) { [IO.Path]::GetFullPath((Join-Path $mumpaRoot $LockFile)) } else { Join-Path $mumpaRoot 'engine-patches/managed-engine.lock.json' }
$mumpaLock = Get-Content -LiteralPath $mumpaLockPath -Raw | ConvertFrom-Json
if ($mumpaLock.pendingBinaries) { throw 'Candidate source has no complete binary lock; run reviewed all-target -UpdateLock build first' }
$mumpaNeedsBuild = $false
foreach ($mumpaTarget in $mumpaLock.targets) {
    if ($Platform -ne 'all' -and $mumpaTarget.platform -ne $Platform) { continue }
    $mumpaPath = Join-Path $mumpaRoot $mumpaTarget.path
    if ((Test-Path -LiteralPath $mumpaPath) -and (Get-FileHash -LiteralPath $mumpaPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $mumpaTarget.sha256) {
        Write-Output "Verified $($mumpaTarget.id) $($mumpaLock.version)"
    } else {
        $mumpaNeedsBuild = $true
    }
}
if ($mumpaNeedsBuild) {
    # Official unpatched release downloads would reintroduce the reader leak.
    & (Join-Path $PSScriptRoot 'build-managed-engine.ps1') -Platform $Platform -LockFile $LockFile
}
