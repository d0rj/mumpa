#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-signing.ps1')
$mumpaSettings = Get-MumpaAndroidSigning
$mumpaOutput = [IO.Path]::GetFullPath($OutputPath)
$mumpaWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($mumpaOutput.StartsWith($mumpaWorkspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Signing backups must stay outside the checkout.' }
if (Test-Path -LiteralPath $mumpaOutput) { throw 'Refusing to overwrite an existing signing backup.' }
if (-not (Test-Path -LiteralPath (Split-Path $mumpaOutput -Parent) -PathType Container)) { throw 'Create the private backup destination directory first.' }
$mumpaSecurePassword = Read-Host 'Password for the portable encrypted PKCS12 backup' -AsSecureString
$mumpaSecureRepeat = Read-Host 'Repeat backup password' -AsSecureString
$mumpaPassword = [Net.NetworkCredential]::new('', $mumpaSecurePassword).Password
if ($mumpaPassword.Length -lt 12 -or $mumpaPassword -ne [Net.NetworkCredential]::new('', $mumpaSecureRepeat).Password) { throw 'Backup passwords must match and contain at least 12 characters.' }
$mumpaPreviousSource = $env:MUMPA_BACKUP_SOURCE_PASSWORD
$mumpaPreviousDestination = $env:MUMPA_BACKUP_DESTINATION_PASSWORD
try {
    $env:MUMPA_BACKUP_SOURCE_PASSWORD = $mumpaSettings.storePassword
    $env:MUMPA_BACKUP_DESTINATION_PASSWORD = $mumpaPassword
    $mumpaKeytool = 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin/keytool.exe'))) { $mumpaKeytool = Join-Path $env:JAVA_HOME 'bin/keytool.exe' }
    & $mumpaKeytool -importkeystore -srckeystore $mumpaSettings.keystorePath -srcstorepass:env MUMPA_BACKUP_SOURCE_PASSWORD -srcalias $mumpaSettings.keyAlias -srckeypass:env MUMPA_BACKUP_SOURCE_PASSWORD -destkeystore $mumpaOutput -deststoretype PKCS12 -deststorepass:env MUMPA_BACKUP_DESTINATION_PASSWORD -destkeypass:env MUMPA_BACKUP_DESTINATION_PASSWORD -destalias mumpa -noprompt 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Signing backup export failed.' }
    Assert-MumpaSigningKey ([pscustomobject]@{ keystorePath=$mumpaOutput; storePassword=$mumpaPassword })
    Write-Output "Encrypted portable backup verified: $mumpaOutput"
} finally {
    $env:MUMPA_BACKUP_SOURCE_PASSWORD = $mumpaPreviousSource
    $env:MUMPA_BACKUP_DESTINATION_PASSWORD = $mumpaPreviousDestination
    $mumpaSecurePassword.Dispose()
    $mumpaSecureRepeat.Dispose()
}
