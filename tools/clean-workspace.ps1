#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$BuildCaches,
    [switch]$Temporary,
    [switch]$Releases,
    [string]$KeepReleaseDirectory = '',
    [string]$WorkspaceRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'workspace-maintenance.ps1')
$mumpaRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
if (-not (Test-Path -LiteralPath (Join-Path $mumpaRoot 'pubspec.yaml')) -or
    (Get-Content -LiteralPath (Join-Path $mumpaRoot 'pubspec.yaml') -Raw) -notmatch '(?m)^name:\s*mumpa\s*$') {
    throw 'Expected the Mumpa workspace root'
}
if (-not ($BuildCaches -or $Temporary -or $Releases)) { $BuildCaches = $Temporary = $Releases = $true }
$mumpaTargets = @()
if ($Releases) { $mumpaTargets += @(Get-MumpaOldReleasePaths $mumpaRoot $KeepReleaseDirectory) }
if ($BuildCaches) {
    $mumpaTargets += @('build','.dart_tool','.flutter-plugins-dependencies','windows/flutter/ephemeral','android/.gradle','android/.kotlin','android/app/.cxx','graphify-out') | ForEach-Object { Join-Path $mumpaRoot $_ }
}
if ($Temporary) {
    $mumpaTargets += Join-Path $mumpaRoot '.local'
    $mumpaTestOutput = Join-Path $mumpaRoot 'test-output'
    if (Test-Path -LiteralPath $mumpaTestOutput) {
        $mumpaTargets += @(Get-ChildItem -LiteralPath $mumpaTestOutput -Directory -Filter 'install-test-*' | Select-Object -ExpandProperty FullName)
        $mumpaTargets += @(Get-ChildItem -LiteralPath $mumpaTestOutput -File -Recurse -Force | Where-Object {
            $_.Extension -in @('.so','.exe','.dll','.zip','.part','.download','.apk','.symbols') -and
            $_.FullName -notmatch '[\\/]install-test-[^\\/]+[\\/]'
        } | Select-Object -ExpandProperty FullName)
    }
}
# Validate the entire plan before the first removal; a junction or invalid last
# release must not leave a half-cleaned workspace. -WhatIf uses this same plan.
$mumpaTargets = @($mumpaTargets | Select-Object -Unique | ForEach-Object { Resolve-MumpaGeneratedPath $mumpaRoot $_ })
foreach ($mumpaTarget in $mumpaTargets) { Assert-MumpaNoPersonalData $mumpaTarget }
foreach ($mumpaTarget in $mumpaTargets) {
    if ((Test-Path -LiteralPath $mumpaTarget) -and $PSCmdlet.ShouldProcess($mumpaTarget, 'Remove generated workspace files')) {
        Remove-MumpaGeneratedPath $mumpaRoot $mumpaTarget
        Write-Output "Removed: $mumpaTarget"
    }
}
