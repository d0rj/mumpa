param([Parameter(Mandatory=$true)][string]$ConfigurationPath)
# ASCII-only broker. A normal Dart child can report launch errors; Start-Process
# gives the worker its own lifetime and files instead of inherited Dart pipes.
$ErrorActionPreference = 'Stop'
try {
    $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding utf8 | ConvertFrom-Json
    $literalPath = $ConfigurationPath.Replace("'", "''")
    $command = @"
`$configuration = Get-Content -LiteralPath '$literalPath' -Raw -Encoding utf8 | ConvertFrom-Json
`$parameters = @{}
foreach (`$property in `$configuration.Parameters.PSObject.Properties) {
    `$parameters[`$property.Name] = `$property.Value
}
& `$configuration.RunnerPath @parameters
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $worker = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $configuration.StdoutPath -RedirectStandardError $configuration.StderrPath
    [ordered]@{ processId=$worker.Id } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}
