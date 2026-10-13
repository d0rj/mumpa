$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $project ('test-output/install-test-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
$target = Join-Path $testRoot 'installed'
New-Item -ItemType Directory -Force -Path (Join-Path $source 'data/flutter_assets') | Out-Null
Copy-Item -LiteralPath (Join-Path $project 'build/windows/x64/runner/Release/mumpa.exe') -Destination $source
foreach ($file in @('flutter_windows.dll','libmpv-2.dll')) { Set-Content -LiteralPath (Join-Path $source $file) -Value 'fixture' }
Set-Content -LiteralPath (Join-Path $source 'generation.txt') -Value 'original'
& (Join-Path $PSScriptRoot 'install-windows.ps1') -SourceDirectory $source -InstallDirectory $target -NoRegistration
if (-not (Test-Path -LiteralPath (Join-Path $target 'current/mumpa.exe'))) { throw 'First install failed' }
Set-Content -LiteralPath (Join-Path $source 'generation.txt') -Value 'updated'
& (Join-Path $PSScriptRoot 'install-windows.ps1') -SourceDirectory $source -InstallDirectory $target -NoRegistration
if ((Get-Content -LiteralPath (Join-Path $target 'current/generation.txt')) -ne 'updated') { throw 'Update failed' }
if ((Get-Content -LiteralPath (Join-Path $target 'previous/generation.txt')) -ne 'original') { throw 'Backup missing' }
# Force a real failure after promotion: the staged helper lacks the uninstaller.
$helper = Join-Path $testRoot 'broken-helper'
New-Item -ItemType Directory -Path $helper | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-windows.ps1') -Destination $helper
Set-Content -LiteralPath (Join-Path $source 'generation.txt') -Value 'broken'
$rejected = $false
try { & (Join-Path $helper 'install-windows.ps1') -SourceDirectory $source -InstallDirectory $target -NoRegistration } catch { $rejected = $true }
if (-not $rejected -or (Get-Content -LiteralPath (Join-Path $target 'current/generation.txt')) -ne 'updated') { throw 'Rollback failed' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unsafe = Join-Path $testRoot 'unsafe.zip'
$archive = [IO.Compression.ZipFile]::Open($unsafe, [IO.Compression.ZipArchiveMode]::Create)
try { $archive.CreateEntry('Mumpa/../../outside.txt') | Out-Null } finally { $archive.Dispose() }
$hash = (Get-FileHash -LiteralPath $unsafe -Algorithm SHA256).Hash
$rejected = $false
try { & (Join-Path $PSScriptRoot 'install-windows.ps1') -ZipPath $unsafe -Sha256 $hash -InstallDirectory $target -NoRegistration } catch { $rejected = $true }
if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $testRoot 'outside.txt'))) { throw 'Traversal not rejected' }
$rejected = $false
try { & (Join-Path $PSScriptRoot 'install-windows.ps1') -ZipPath $unsafe -Sha256 ('0' * 64) -InstallDirectory $target -NoRegistration } catch { $rejected = $true }
if (-not $rejected) { throw 'Wrong hash not rejected' }
foreach ($name in @('install-windows.ps1','uninstall-windows.ps1')) {
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $project "assets/updater/$name")).Hash) { throw 'Bundled updater differs from installer' }
}
Write-Output 'PASS: install, update, previous version, rollback, traversal, checksum, bundled helpers.'
# Keep the isolated fixtures as evidence under test-output; never touch user data.
