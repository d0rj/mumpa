param(
    [Parameter(Mandatory)][string]$Source,
    [string]$GoExecutable = 'C:\Users\PC\go\pkg\mod\golang.org\toolchain@v0.0.1-go1.27.1.windows-amd64\bin\go.exe'
)
$ErrorActionPreference = 'Stop'
$mumpaRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mumpaSource = [IO.Path]::GetFullPath($Source)
$mumpaWorkRoot = [IO.Path]::GetFullPath((Join-Path $mumpaRoot '.local/engine-build')) + [IO.Path]::DirectorySeparatorChar
if (-not $mumpaSource.StartsWith($mumpaWorkRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Negative controls may modify only fresh local engine-build source' }
$mumpaServer = Join-Path $mumpaSource 'server'
if (-not (Test-Path -LiteralPath (Join-Path $mumpaServer 'managed.mod'))) { throw 'Prepared candidate source with managed.mod is required' }
$mumpaOldCache = $env:GOMODCACHE
$mumpaOldToolchain = $env:GOTOOLCHAIN
$mumpaOldProxy = $env:GOPROXY
$mumpaOldCGO = $env:CGO_ENABLED

function Invoke-MumpaNegative([string]$Name, [string]$File, [scriptblock]$Transform, [string]$Test, [string]$Package, [string]$ExpectedFailure) {
    $mumpaFile = Join-Path $mumpaServer ('mumpa-deps/torrent/' + $File)
    $mumpaOriginal = [IO.File]::ReadAllBytes($mumpaFile)
    $mumpaText = [Text.Encoding]::UTF8.GetString($mumpaOriginal)
    $mumpaChanged = & $Transform $mumpaText
    if ($mumpaChanged -eq $mumpaText) { throw "Negative control did not change source: $Name" }
    $mumpaLog = Join-Path $PSScriptRoot ("negative-$Name.log")
    try {
        [IO.File]::WriteAllText($mumpaFile, $mumpaChanged, [Text.UTF8Encoding]::new($false))
        $mumpaArgs = @('test','-modfile=managed.mod','-mod=readonly','-buildvcs=false','-p','2','-tags','nosqlite','-ldflags','-checklinkname=0','-run',("^" + $Test + "$"),'-count=1','-timeout=30s','-v',$Package)
        & $GoExecutable @mumpaArgs *> $mumpaLog
        $mumpaExit = $LASTEXITCODE
        $mumpaResult = Get-Content -LiteralPath $mumpaLog -Raw
        if ($mumpaExit -eq 0 -or $mumpaResult -notmatch $ExpectedFailure) { throw "Negative control failed to detect its intended defect: $Name" }
        Write-Output "Detected $Name (expected test failure)"
    } finally { [IO.File]::WriteAllBytes($mumpaFile, $mumpaOriginal) }
}

try {
    $env:GOMODCACHE = Join-Path $mumpaRoot '.local/engine-build/module-cache'
    $env:GOTOOLCHAIN = 'go1.27.1'
    $env:GOPROXY = 'off'
    $env:CGO_ENABLED = '0'
    Push-Location $mumpaServer
    try {
        Invoke-MumpaNegative 'mse-eof-fallback' 'client.go' {
            param($s)
            $s.Replace("`t// An MSE rejection", "`tif err != nil { return }`n`t// An MSE rejection")
        } 'TestMumpaOutgoingMSEErrorFallsBackToPlaintext' 'github.com/anacrolix/torrent' 'optional-encryption connection = <nil>'
        Invoke-MumpaNegative 'bare-ip' 'tracker/http.go' {
            param($s)
            $s.Replace('opts.ClientIp4.IP.String()', 'opts.ClientIp4.String()').Replace('opts.ClientIp6.IP.String()', 'opts.ClientIp6.String()')
        } 'TestMumpaAnnounceBareIP' 'github.com/anacrolix/torrent/tracker' 'announce IP is not a bare address'
        Invoke-MumpaNegative 'auto-ip-override' 'tracker_scraper.go' {
            param($s)
            $s.Replace('config.AnnounceIp4', 'config.PublicIp4').Replace('config.AnnounceIp6', 'config.PublicIp6')
        } 'TestMumpaScraperAnnounceOverrideIsExplicit' 'github.com/anacrolix/torrent' 'auto-detected public IP produced tracker override'
        Invoke-MumpaNegative 'cancellation' 'client.go' {
            param($s)
            $s.Replace('if contextErr := outgoingContextError(ctx); contextErr != nil {', 'if contextErr := outgoingContextError(ctx); false {')
        } 'TestMumpaOutgoingCancellationNeverFallsBack' 'github.com/anacrolix/torrent' 'canceled connection = <nil>'
        # Repeated deadlines exercise the scheduling window between the socket
        # deadline and context timer. All source mutations were restored above.
        $mumpaArgs = @('test','-modfile=managed.mod','-mod=readonly','-buildvcs=false','-p','2','-tags','nosqlite','-ldflags','-checklinkname=0','-run','^TestMumpaOutgoingDeadlineNeverFallsBack$','-count=30','-timeout=30s','github.com/anacrolix/torrent')
        & $GoExecutable @mumpaArgs *> (Join-Path $PSScriptRoot 'deadline-stability.log')
        if ($LASTEXITCODE -ne 0) { throw 'Repeated deadline regression failed' }
        Write-Output 'Deadline stability: 30 passes'
    } finally { Pop-Location }
} finally {
    $env:GOMODCACHE = $mumpaOldCache
    $env:GOTOOLCHAIN = $mumpaOldToolchain
    $env:GOPROXY = $mumpaOldProxy
    $env:CGO_ENABLED = $mumpaOldCGO
}
