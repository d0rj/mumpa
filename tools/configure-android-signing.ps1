#requires -Version 7.0
param(
    [switch]$SyncGitHubSecrets,
    [string]$Repository = 'd0rj/mumpa'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-signing.ps1')
$mumpaDirectory = Get-MumpaSigningDirectory
$mumpaConfigPath = Join-Path $mumpaDirectory 'signing.dpapi'
$mumpaKeystorePath = Join-Path $mumpaDirectory 'release.p12'
$mumpaWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([IO.Path]::GetFullPath($mumpaDirectory).StartsWith($mumpaWorkspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Private signing material must stay outside the checkout.' }
if (-not (Test-Path -LiteralPath $mumpaConfigPath)) {
    if (Test-Path -LiteralPath $mumpaKeystorePath) { throw 'A persistent key already exists without settings. Restore its protected settings; never replace the key.' }
    $mumpaSource = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.android/debug.keystore'
    if (-not (Test-Path -LiteralPath $mumpaSource)) { throw 'The key used for v1.2.22 is missing. Restore it before configuring persistent signing.' }
    New-Item -ItemType Directory -Path $mumpaDirectory -Force | Out-Null
    $mumpaAcl = [Security.AccessControl.DirectorySecurity]::new()
    $mumpaAcl.SetAccessRuleProtection($true, $false)
    foreach ($mumpaSid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $mumpaAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($mumpaSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $mumpaDirectory -AclObject $mumpaAcl
    $mumpaPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $mumpaStage = Join-Path $mumpaDirectory ('.import-' + [Guid]::NewGuid().ToString('N') + '.p12')
    $mumpaOldImportPassword = $env:MUMPA_KEY_IMPORT_PASSWORD
    try {
        $env:MUMPA_KEY_IMPORT_PASSWORD = $mumpaPassword
        $mumpaKeytool = 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'
        if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin/keytool.exe'))) { $mumpaKeytool = Join-Path $env:JAVA_HOME 'bin/keytool.exe' }
        & $mumpaKeytool -importkeystore -srckeystore $mumpaSource -srcstorepass android -srcalias androiddebugkey -srckeypass android -destkeystore $mumpaStage -deststoretype PKCS12 -deststorepass:env MUMPA_KEY_IMPORT_PASSWORD -destkeypass:env MUMPA_KEY_IMPORT_PASSWORD -destalias mumpa -noprompt 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot import the existing Android identity into the protected release keystore.' }
        $mumpaSettings = [pscustomobject]@{ keystorePath=$mumpaStage; storePassword=$mumpaPassword; keyAlias='mumpa'; keyPassword=$mumpaPassword }
        Assert-MumpaSigningKey $mumpaSettings
        Move-Item -LiteralPath $mumpaStage -Destination $mumpaKeystorePath
        $mumpaSettings.keystorePath = $mumpaKeystorePath
        $mumpaClear = [Text.Encoding]::UTF8.GetBytes(($mumpaSettings | ConvertTo-Json -Compress))
        try {
            $mumpaEncrypted = [Security.Cryptography.ProtectedData]::Protect($mumpaClear, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $mumpaStream = [IO.File]::Open($mumpaConfigPath, [IO.FileMode]::CreateNew)
            try { $mumpaStream.Write($mumpaEncrypted) } finally { $mumpaStream.Dispose() }
        } finally { [Array]::Clear($mumpaClear) }
        $mumpaBackup = Join-Path $mumpaDirectory 'backup'
        New-Item -ItemType Directory -Path $mumpaBackup | Out-Null
        Copy-Item -LiteralPath $mumpaKeystorePath,$mumpaConfigPath -Destination $mumpaBackup
    } finally {
        $env:MUMPA_KEY_IMPORT_PASSWORD = $mumpaOldImportPassword
        if (Test-Path -LiteralPath $mumpaStage) { Remove-Item -LiteralPath $mumpaStage -Force }
    }
}
$mumpaSettings = Get-MumpaAndroidSigning
if ($SyncGitHubSecrets) {
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid GitHub repository.' }
    $mumpaSecrets = [ordered]@{
        ANDROID_KEYSTORE_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mumpaSettings.keystorePath))
        ANDROID_KEYSTORE_PASSWORD = $mumpaSettings.storePassword
        ANDROID_KEY_ALIAS = $mumpaSettings.keyAlias
        ANDROID_KEY_PASSWORD = $mumpaSettings.keyPassword
    }
    foreach ($mumpaSecret in $mumpaSecrets.GetEnumerator()) {
        $mumpaStart = [Diagnostics.ProcessStartInfo]::new('gh')
        $mumpaStart.UseShellExecute = $false
        $mumpaStart.CreateNoWindow = $true
        $mumpaStart.RedirectStandardInput = $true
        $mumpaStart.RedirectStandardOutput = $true
        $mumpaStart.RedirectStandardError = $true
        foreach ($mumpaArgument in @('secret','set',$mumpaSecret.Key,'--repo',$Repository)) { $mumpaStart.ArgumentList.Add($mumpaArgument) }
        $mumpaProcess = [Diagnostics.Process]::Start($mumpaStart)
        try {
            $mumpaProcess.StandardInput.Write($mumpaSecret.Value)
            $mumpaProcess.StandardInput.Close()
            $mumpaOutput = $mumpaProcess.StandardOutput.ReadToEndAsync()
            $mumpaError = $mumpaProcess.StandardError.ReadToEndAsync()
            $mumpaProcess.WaitForExit()
            $null = $mumpaOutput.GetAwaiter().GetResult()
            $null = $mumpaError.GetAwaiter().GetResult()
            if ($mumpaProcess.ExitCode -ne 0) { throw "GitHub secret update failed: $($mumpaSecret.Key). Check gh authentication/permissions." }
            Write-Output "Configured GitHub secret: $($mumpaSecret.Key)"
        } finally { $mumpaProcess.Dispose() }
    }
}
Write-Output "Persistent Android identity verified: SHA256 $(Get-MumpaSigningFingerprint)"
Write-Output "Local protected settings: $mumpaConfigPath"
