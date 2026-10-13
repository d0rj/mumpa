param(
    [string]$SourceDirectory,
    [string]$ZipPath,
    [string]$Sha256,
    [string]$Version,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/Mumpa'),
    [int]$WaitForProcessId = 0,
    [string]$StatusPath,
    [switch]$NoRegistration,
    [switch]$Launch
)
$ErrorActionPreference = 'Stop'
$mumpaRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\','/')
$mumpaCurrent = Join-Path $mumpaRoot 'current'
$mumpaPrevious = Join-Path $mumpaRoot 'previous'
$mumpaStage = Join-Path $mumpaRoot ('.stage-' + [Guid]::NewGuid().ToString('N'))
$mumpaMoved = $false
$mumpaPromoted = $false
$mumpaLock = $null
$mumpaOldMetadata = $null

function Set-InstallStatus([string]$State, [string]$Message = '') {
    if ($StatusPath) {
        $status = [ordered]@{ state=$State; message=$Message; version=$Version; installDirectory=$mumpaRoot }
        $temp = $StatusPath + '.tmp'
        $status | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $StatusPath -Force
    }
}

function Assert-Child([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($mumpaRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Operation leaves the installation directory.'
    }
    if (Test-Path -LiteralPath $full) {
        if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported.' }
        if (Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
            throw 'Reparse points are not supported.'
        }
    }
    return $full
}

try {
    if ([bool]$SourceDirectory -eq [bool]$ZipPath) { throw 'Choose SourceDirectory or ZipPath.' }
    if ($mumpaRoot -eq [IO.Path]::GetPathRoot($mumpaRoot)) { throw 'Cannot install at a drive root.' }
    if (Test-Path -LiteralPath $mumpaRoot) {
        if ((Get-Item -LiteralPath $mumpaRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation root is a reparse point.' }
    }
    foreach ($path in @($mumpaCurrent, $mumpaPrevious)) {
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath (Join-Path $mumpaRoot 'install.json'))) {
            throw 'This directory is not a managed Mumpa installation.'
        }
        Assert-Child $path | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $mumpaStage | Out-Null
    $mumpaLock = [IO.File]::Open((Join-Path $mumpaRoot 'install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (Test-Path -LiteralPath (Join-Path $mumpaRoot 'install.json')) {
        $mumpaOldMetadata = Get-Content -LiteralPath (Join-Path $mumpaRoot 'install.json') -Raw
    }
    if ($ZipPath) {
        if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash -ne $Sha256) {
            throw 'Update SHA-256 mismatch.'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ZipPath))
        try {
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName.Replace('\','/')
                if (-not $name.StartsWith('Mumpa/', [StringComparison]::Ordinal) -or $name.Split('/') -contains '..' -or $name.Contains(':')) {
                    throw 'Invalid update archive path.'
                }
                if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Archive contains a symlink.' }
            }
        } finally { $zip.Dispose() }
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $mumpaStage
        $app = Join-Path $mumpaStage 'Mumpa'
    } else {
        $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
        $app = Join-Path $mumpaStage 'Mumpa'
        New-Item -ItemType Directory -Path $app | Out-Null
        Get-ChildItem -LiteralPath $source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $app -Recurse -Force }
    }
    foreach ($required in @('mumpa.exe','flutter_windows.dll','libmpv-2.dll','data/flutter_assets')) {
        if (-not (Test-Path -LiteralPath (Join-Path $app $required))) { throw "Missing application file: $required" }
    }
    Assert-Child $app | Out-Null
    $nativeVersion = (Get-Item -LiteralPath (Join-Path $app 'mumpa.exe')).VersionInfo.ProductVersion
    if (-not $Version) { $Version = $nativeVersion }
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:\+\d+)?$' -or $nativeVersion.Split('+')[0] -ne $Version.Split('+')[0]) {
        throw 'Executable version does not match the update.'
    }
    if ($WaitForProcessId) {
        $waiting = Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue
        if ($waiting -and $waiting.ProcessName -ne 'mumpa') { throw 'Refusing to wait for a different application.' }
        Set-InstallStatus 'ready'
        if ($waiting) { $waiting.WaitForExit(120000) | Out-Null }
        if (Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue) { throw 'Mumpa did not exit. The installed files were not changed.' }
    }
    if (Get-Process mumpa -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $mumpaCurrent 'mumpa.exe') }) {
        throw 'Quit the installed Mumpa before installing.'
    }
    if (Test-Path -LiteralPath $mumpaPrevious) { Remove-Item -LiteralPath (Assert-Child $mumpaPrevious) -Recurse -Force }
    if (Test-Path -LiteralPath $mumpaCurrent) {
        Move-Item -LiteralPath (Assert-Child $mumpaCurrent) -Destination (Assert-Child $mumpaPrevious)
        $mumpaMoved = $true
    }
    Move-Item -LiteralPath (Assert-Child $app) -Destination (Assert-Child $mumpaCurrent)
    $mumpaPromoted = $true
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall-windows.ps1') -Destination (Join-Path $mumpaRoot 'uninstall.ps1') -Force
    if (-not $NoRegistration) {
        $programs = [Environment]::GetFolderPath('Programs')
        New-Item -ItemType Directory -Force -Path $programs | Out-Null
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $programs 'Mumpa.lnk'))
        $shortcut.TargetPath = Join-Path $mumpaCurrent 'mumpa.exe'
        $shortcut.WorkingDirectory = $mumpaCurrent
        $shortcut.IconLocation = $shortcut.TargetPath + ',0'
        $shortcut.Description = 'Mumpa — музыкальная медиатека'
        $shortcut.Save()
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mumpa'
        New-Item -Path $key -Force | Out-Null
        $values = @{
            DisplayName='Mumpa'; DisplayVersion=$Version; Publisher='d0rj'; InstallLocation=$mumpaRoot
            DisplayIcon=(Join-Path $mumpaCurrent 'mumpa.exe'); URLInfoAbout='https://github.com/d0rj/mumpa'
            UninstallString=('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $mumpaRoot 'uninstall.ps1') + '"')
        }
        foreach ($name in $values.Keys) { New-ItemProperty -LiteralPath $key -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null }
        foreach ($name in @('NoModify','NoRepair')) { New-ItemProperty -LiteralPath $key -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
    }
    [ordered]@{ version=$Version; installedAt=[DateTime]::UtcNow.ToString('o'); directory=$mumpaRoot } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $mumpaRoot 'install.json') -Encoding utf8
    if ($Launch) { Start-Process -FilePath (Join-Path $mumpaCurrent 'mumpa.exe') -WorkingDirectory $mumpaCurrent -WindowStyle Hidden }
    Set-InstallStatus 'installed'
    Write-Output "Installed Mumpa $Version in $mumpaCurrent"
} catch {
    $failure = $_.Exception.Message
    if ($mumpaPromoted -and $mumpaMoved) { Remove-Item -LiteralPath (Assert-Child $mumpaCurrent) -Recurse -Force }
    if ($mumpaMoved -and (Test-Path -LiteralPath $mumpaPrevious)) {
        Move-Item -LiteralPath (Assert-Child $mumpaPrevious) -Destination (Assert-Child $mumpaCurrent)
        if ($Launch) { Start-Process -FilePath (Join-Path $mumpaCurrent 'mumpa.exe') -WorkingDirectory $mumpaCurrent -WindowStyle Hidden }
    }
    if ($mumpaOldMetadata) {
        Set-Content -LiteralPath (Join-Path $mumpaRoot 'install.json') -Value $mumpaOldMetadata -Encoding utf8
    }
    Set-InstallStatus 'failed' $failure
    throw
} finally {
    if ($mumpaLock) { $mumpaLock.Dispose() }
    if (Test-Path -LiteralPath $mumpaStage) { Remove-Item -LiteralPath (Assert-Child $mumpaStage) -Recurse -Force }
}
