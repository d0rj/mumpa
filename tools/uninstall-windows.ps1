$ErrorActionPreference = 'Stop'
$mumpaRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')
$marker = Join-Path $mumpaRoot 'install.json'
if (-not (Test-Path -LiteralPath $marker)) { throw 'Managed installation marker is missing.' }
$metadata = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
if ($metadata.directory -ne $mumpaRoot) { throw 'Installation directory does not match.' }
$exe = Join-Path $mumpaRoot 'current/mumpa.exe'
if (Get-Process mumpa -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show('Заверши Mumpa через меню трея и повтори удаление.', 'Mumpa') | Out-Null
    exit 1
}
foreach ($folder in @('current','previous')) {
    $target = [IO.Path]::GetFullPath((Join-Path $mumpaRoot $folder))
    if (-not $target.StartsWith($mumpaRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid uninstall target.' }
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in installation.' }
        if (Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Reparse point in installation.' }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
$link = Join-Path ([Environment]::GetFolderPath('Programs')) 'Mumpa.lnk'
if (Test-Path -LiteralPath $link) {
    if ((New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath -eq $exe) { Remove-Item -LiteralPath $link }
}
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mumpa'
if ((Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).InstallLocation -eq $mumpaRoot) {
    Remove-Item -LiteralPath $key
}
Remove-Item -LiteralPath $marker
# User music, library, cache and settings live in ApplicationSupport, not here.
