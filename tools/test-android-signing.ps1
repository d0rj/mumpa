#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-signing.ps1')
. (Join-Path $PSScriptRoot 'workspace-maintenance.ps1')
$mumpaRoot = Split-Path $PSScriptRoot -Parent
$mumpaTestRoot = Join-Path $mumpaRoot ('test-output/signing-test-' + [Guid]::NewGuid().ToString('N'))
$mumpaPrevious = @{}
foreach ($mumpaName in @($mumpaSigningEnvironment + 'GITHUB_ACTIONS')) { $mumpaPrevious[$mumpaName] = [Environment]::GetEnvironmentVariable($mumpaName, 'Process') }
$mumpaAssertions = 0
function Assert-SigningTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:mumpaAssertions++
}
function Assert-SigningRejected([scriptblock]$Action) {
    $mumpaRejected = $false
    try { & $Action | Out-Null } catch { $mumpaRejected = $true }
    Assert-SigningTest $mumpaRejected 'Invalid signing input was accepted.'
}
try {
    New-Item -ItemType Directory -Path $mumpaTestRoot | Out-Null
    foreach ($mumpaName in @($mumpaSigningEnvironment + 'GITHUB_ACTIONS')) { [Environment]::SetEnvironmentVariable($mumpaName, $null, 'Process') }
    Assert-SigningRejected { Get-MumpaAndroidSigning -Directory $mumpaTestRoot }
    $env:ANDROID_KEY_ALIAS = 'fixture'
    Assert-SigningRejected { Get-MumpaAndroidSigning -Directory $mumpaTestRoot }
    $env:ANDROID_KEY_ALIAS = $null
    $env:GITHUB_ACTIONS = 'true'
    Assert-SigningRejected { Get-MumpaAndroidSigning -Directory (Get-MumpaSigningDirectory) }
    $env:GITHUB_ACTIONS = $null
    $mumpaRsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $mumpaRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Mumpa isolated fixture', $mumpaRsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $mumpaCertificate = $mumpaRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddHours(1))
        try {
            $mumpaFixtureKey = Join-Path $mumpaTestRoot 'fixture.p12'
            [IO.File]::WriteAllBytes($mumpaFixtureKey, $mumpaCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, 'fixture-only'))
            $mumpaFixtureFingerprint = $mumpaCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        } finally { $mumpaCertificate.Dispose() }
    } finally { $mumpaRsa.Dispose() }
    $mumpaSettings = [pscustomobject]@{ keystorePath=$mumpaFixtureKey; storePassword='fixture-only'; keyAlias='fixture'; keyPassword='fixture-only' }
    Assert-MumpaSigningKey $mumpaSettings $mumpaFixtureFingerprint
    Assert-SigningTest $true 'Valid synthetic PKCS12 key was refused.'
    Assert-SigningRejected { Assert-MumpaSigningKey $mumpaSettings }
    $mumpaSettings.storePassword = 'wrong-fixture-password'
    Assert-SigningRejected { Assert-MumpaSigningKey $mumpaSettings $mumpaFixtureFingerprint }
    $mumpaSettings.storePassword = 'fixture-only'
    $mumpaSettings.keystorePath = Join-Path $mumpaTestRoot 'missing.p12'
    Assert-SigningRejected { Assert-MumpaSigningKey $mumpaSettings $mumpaFixtureFingerprint }
    $mumpaSettings.keystorePath = $mumpaFixtureKey
    $mumpaClear = [Text.Encoding]::UTF8.GetBytes(($mumpaSettings | ConvertTo-Json -Compress))
    try { [IO.File]::WriteAllBytes((Join-Path $mumpaTestRoot 'signing.dpapi'), [Security.Cryptography.ProtectedData]::Protect($mumpaClear, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)) }
    finally { [Array]::Clear($mumpaClear) }
    # Decryption works, but a different certificate still cannot become the release identity.
    Assert-SigningRejected { Get-MumpaAndroidSigning -Directory $mumpaTestRoot }
    Invoke-WithMumpaAndroidSigning $mumpaSettings {
        Assert-SigningTest ($env:ANDROID_KEYSTORE_PASSWORD -eq 'fixture-only') 'Signing environment was not supplied.'
        Assert-SigningTest ($env:ANDROID_KEY_ALIAS -eq 'fixture') 'Signing alias was not supplied.'
    }
    Assert-SigningTest ([string]::IsNullOrEmpty($env:ANDROID_KEYSTORE_PASSWORD)) 'Signing environment leaked after success.'
    Assert-SigningRejected { Invoke-WithMumpaAndroidSigning $mumpaSettings { throw 'Injected isolated failure' } }
    Assert-SigningTest ([string]::IsNullOrEmpty($env:ANDROID_KEYSTORE_PASSWORD)) 'Signing environment leaked after failure.'
    Write-Output "PASS: $mumpaAssertions signing assertions (missing/partial/CI secrets, encrypted config, pinned certificate, wrong password, environment cleanup)."
} finally {
    foreach ($mumpaName in $mumpaPrevious.Keys) { [Environment]::SetEnvironmentVariable($mumpaName, $mumpaPrevious[$mumpaName], 'Process') }
    Remove-MumpaGeneratedPath $mumpaRoot $mumpaTestRoot
}
