# Shared local/CI signing support. Never emit the returned private settings.
$mumpaSigningEnvironment = @('MUMPA_KEYSTORE_PATH','ANDROID_KEYSTORE_PASSWORD','ANDROID_KEY_ALIAS','ANDROID_KEY_PASSWORD')

function Get-MumpaSigningDirectory {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.mumpa-signing/android'
}

function Get-MumpaSigningFingerprint {
    (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../android/release-signing.sha256') -Raw).Trim().ToLowerInvariant()
}

function Assert-MumpaSigningKey($Settings, [string]$ExpectedFingerprint = (Get-MumpaSigningFingerprint)) {
    if (-not (Test-Path -LiteralPath $Settings.keystorePath -PathType Leaf)) { throw 'Persistent Android signing keystore is missing.' }
    $mumpaCertificate = $null
    try {
        $mumpaCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [IO.File]::ReadAllBytes($Settings.keystorePath), [string]$Settings.storePassword,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        if (-not $mumpaCertificate.HasPrivateKey -or
            $mumpaCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant() -ne $ExpectedFingerprint) {
            throw 'Android signing certificate does not match the pinned release identity.'
        }
    } catch {
        throw 'Cannot open the persistent Android key, or its certificate does not match the pinned release identity.'
    } finally { if ($mumpaCertificate) { $mumpaCertificate.Dispose() } }
}

function Get-MumpaAndroidSigning([string]$Directory = (Get-MumpaSigningDirectory)) {
    $mumpaValues = @($mumpaSigningEnvironment | ForEach-Object { [Environment]::GetEnvironmentVariable($_, 'Process') })
    $mumpaConfigured = @($mumpaValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($mumpaConfigured -eq 4) {
        $mumpaSettings = [pscustomobject]@{ keystorePath=$mumpaValues[0]; storePassword=$mumpaValues[1]; keyAlias=$mumpaValues[2]; keyPassword=$mumpaValues[3] }
    } elseif ($mumpaConfigured -ne 0) {
        throw 'Configure all four Android signing environment variables; partial signing is refused.'
    } else {
        if ($env:GITHUB_ACTIONS -eq 'true') { throw 'All four persistent Android signing secrets are required in GitHub Actions.' }
        $mumpaConfig = Join-Path $Directory 'signing.dpapi'
        if (-not (Test-Path -LiteralPath $mumpaConfig)) { throw 'Run tools/configure-android-signing.ps1 before a local Android release build.' }
        try {
            $mumpaPlaintext = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($mumpaConfig), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $mumpaSettings = [Text.Encoding]::UTF8.GetString($mumpaPlaintext) | ConvertFrom-Json
        } catch { throw 'Cannot decrypt local Android signing settings for this Windows account.' }
        finally { if ($mumpaPlaintext) { [Array]::Clear($mumpaPlaintext) } }
    }
    foreach ($mumpaField in @('keystorePath','storePassword','keyAlias','keyPassword')) {
        if ([string]::IsNullOrWhiteSpace($mumpaSettings.$mumpaField)) { throw 'Persistent Android signing settings are incomplete.' }
    }
    Assert-MumpaSigningKey $mumpaSettings
    return $mumpaSettings
}

function Invoke-WithMumpaAndroidSigning($Settings, [scriptblock]$Action) {
    $mumpaPrevious = @{}
    foreach ($mumpaName in $mumpaSigningEnvironment) { $mumpaPrevious[$mumpaName] = [Environment]::GetEnvironmentVariable($mumpaName, 'Process') }
    try {
        $env:MUMPA_KEYSTORE_PATH = $Settings.keystorePath
        $env:ANDROID_KEYSTORE_PASSWORD = $Settings.storePassword
        $env:ANDROID_KEY_ALIAS = $Settings.keyAlias
        $env:ANDROID_KEY_PASSWORD = $Settings.keyPassword
        & $Action
    } finally {
        foreach ($mumpaName in $mumpaSigningEnvironment) { [Environment]::SetEnvironmentVariable($mumpaName, $mumpaPrevious[$mumpaName], 'Process') }
    }
}

function Assert-MumpaApkSignatures([string]$WorkspaceRoot) {
    $mumpaSdk = $env:ANDROID_HOME
    if (-not $mumpaSdk) {
        $mumpaSdkLine = Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'android/local.properties') | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
        if ($mumpaSdkLine) { $mumpaSdk = $mumpaSdkLine.Substring(8).Replace('\\','\').Replace('\:',':') }
    }
    $mumpaApkSigner = Join-Path $mumpaSdk 'build-tools/36.0.0/apksigner.bat'
    $mumpaExpected = Get-MumpaSigningFingerprint
    foreach ($mumpaAbi in @('arm64-v8a','armeabi-v7a','x86_64')) {
        $mumpaApk = Join-Path $WorkspaceRoot "build/app/outputs/flutter-apk/app-$mumpaAbi-release.apk"
        $mumpaOutput = & $mumpaApkSigner verify --print-certs $mumpaApk 2>&1
        if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed: $mumpaAbi" }
        $mumpaFingerprints = @($mumpaOutput | Where-Object { $_ -match '^Signer #\d+ certificate SHA-256 digest: ' })
        if ($mumpaFingerprints.Count -ne 1 -or $mumpaFingerprints[0].Split(':',2)[1].Trim().ToLowerInvariant() -ne $mumpaExpected) {
            throw "APK does not have the pinned Android release certificate: $mumpaAbi"
        }
    }
    Write-Output "Verified all three APK signatures: SHA256 $mumpaExpected"
}
