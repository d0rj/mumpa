# Shared by packaging and the explicit workspace cleaner. PowerShell 7 is required.
function Assert-MumpaNoPersonalData([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $mumpaScan = [Collections.Generic.Stack[string]]::new()
    if (-not (Get-Item -LiteralPath $Path -Force).PSIsContainer) { return }
    $mumpaScan.Push($Path)
    while ($mumpaScan.Count) {
        $mumpaFolder = $mumpaScan.Pop()
        foreach ($mumpaEntry in Get-ChildItem -LiteralPath $mumpaFolder -Force) {
            if ($mumpaEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($mumpaEntry.PSIsContainer) { $mumpaScan.Push($mumpaEntry.FullName) }
            elseif ($mumpaEntry.Name -match '^library\.json(?:\.bak|\.tmp)?$' -or $mumpaEntry.Name -eq 'ServerConfig.json') {
                throw "Personal Mumpa/Jackett data found: $($mumpaEntry.FullName). Cleanup stopped. Move the profile to durable application data before cleaning this directory."
            }
        }
    }
}

function Resolve-MumpaGeneratedPath([string]$WorkspaceRoot, [string]$Path) {
    $mumpaCheckedRoot = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $mumpaCheckedPath = [IO.Path]::GetFullPath($Path)
    if (-not $mumpaCheckedPath.StartsWith($mumpaCheckedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated path escapes the workspace: $mumpaCheckedPath"
    }
    # Resolve every existing ancestor, not just the spelling of the final path.
    $mumpaAncestor = $mumpaCheckedPath
    while ($true) {
        if (Test-Path -LiteralPath $mumpaAncestor) {
            if ((Get-Item -LiteralPath $mumpaAncestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Generated path passes through a link: $mumpaAncestor"
            }
        }
        if ($mumpaAncestor -eq $mumpaCheckedRoot) { break }
        $mumpaAncestor = [IO.Path]::GetDirectoryName($mumpaAncestor)
    }
    return $mumpaCheckedPath
}

function Remove-MumpaGeneratedPath([string]$WorkspaceRoot, [string]$Path) {
    $mumpaCheckedPath = Resolve-MumpaGeneratedPath $WorkspaceRoot $Path
    if (-not (Test-Path -LiteralPath $mumpaCheckedPath)) { return }
    Assert-MumpaNoPersonalData $mumpaCheckedPath
    # Unlink nested junctions without traversing their targets before recursion.
    $mumpaDirectories = [Collections.Generic.Stack[string]]::new()
    if ((Get-Item -LiteralPath $mumpaCheckedPath -Force).PSIsContainer) { $mumpaDirectories.Push($mumpaCheckedPath) }
    while ($mumpaDirectories.Count) {
        foreach ($mumpaEntry in Get-ChildItem -LiteralPath ($mumpaDirectories.Pop()) -Force) {
            if ($mumpaEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Remove-Item -LiteralPath $mumpaEntry.FullName -Force
            } elseif ($mumpaEntry.PSIsContainer) { $mumpaDirectories.Push($mumpaEntry.FullName) }
        }
    }
    Remove-Item -LiteralPath $mumpaCheckedPath -Recurse -Force
}

function Assert-MumpaRelease([string]$WorkspaceRoot, [string]$Directory, [string]$Version) {
    $mumpaReleasePath = Resolve-MumpaGeneratedPath $WorkspaceRoot $Directory
    $mumpaManifestPath = Join-Path $mumpaReleasePath 'SHA256.json'
    $mumpaManifest = @(Get-Content -LiteralPath $mumpaManifestPath -Raw | ConvertFrom-Json)
    $mumpaRequired = @('windows-x64.zip','android-arm64.apk','android-armv7.apk','android-x86_64.apk','android-symbols.zip')
    foreach ($mumpaSuffix in $mumpaRequired) {
        $mumpaName = "Mumpa-$Version-$mumpaSuffix"
        if (@($mumpaManifest | Where-Object { $_.file -eq $mumpaName }).Count -ne 1) {
            throw "Incomplete release manifest: $mumpaName"
        }
    }
    foreach ($mumpaRecord in $mumpaManifest) {
        $mumpaFile = Resolve-MumpaGeneratedPath $mumpaReleasePath (Join-Path $mumpaReleasePath $mumpaRecord.file)
        if ((Get-Item -LiteralPath $mumpaFile).Length -ne $mumpaRecord.bytes -or
            (Get-FileHash -LiteralPath $mumpaFile -Algorithm SHA256).Hash -ne $mumpaRecord.sha256) {
            throw "Release checksum mismatch: $($mumpaRecord.file)"
        }
    }
}

function Get-MumpaOldReleasePaths([string]$WorkspaceRoot, [string]$KeepReleaseDirectory = '') {
    $mumpaArtifacts = Resolve-MumpaGeneratedPath $WorkspaceRoot (Join-Path $WorkspaceRoot 'artifacts')
    if (-not (Test-Path -LiteralPath $mumpaArtifacts)) { return }
    $mumpaCandidates = @(foreach ($mumpaEntry in Get-ChildItem -LiteralPath $mumpaArtifacts -Force) {
        $mumpaVersion = ''
        if ($mumpaEntry.PSIsContainer -and $mumpaEntry.Name -match '^release-(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)$') {
            $mumpaVersion = $Matches[1]
        } elseif ($mumpaEntry.PSIsContainer -and $mumpaEntry.Name -eq 'ci-release') {
            $mumpaCiManifest = Join-Path $mumpaEntry.FullName 'SHA256.json'
            if (Test-Path -LiteralPath $mumpaCiManifest) {
                $mumpaCiPackages = @(Get-Content -LiteralPath $mumpaCiManifest -Raw | ConvertFrom-Json | Where-Object { $_.file -match '^Mumpa-(.+)-windows-x64.zip$' })
                if ($mumpaCiPackages.Count -ne 1) { throw 'Cannot determine CI release version' }
                $mumpaVersion = $mumpaCiPackages[0].file -replace '^Mumpa-(.+)-windows-x64.zip$', '$1'
            }
        } elseif ($mumpaEntry.Name -match '^Mumpa-(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)-(?:windows-x64|android-(?:arm64|armv7|x86_64|symbols)|source)(?:\.zip|\.apk)?$') {
            $mumpaVersion = $Matches[1]
        }
        if ($mumpaVersion) {
            [pscustomobject]@{ Path = $mumpaEntry.FullName; Version = [System.Management.Automation.SemanticVersion]$mumpaVersion; Name = $mumpaVersion; IsRelease = $mumpaEntry.Name.StartsWith('release-') -or $mumpaEntry.Name -eq 'ci-release' }
        }
    })
    if ($KeepReleaseDirectory) {
        $mumpaKeep = Resolve-MumpaGeneratedPath $mumpaArtifacts $KeepReleaseDirectory
        $mumpaManifest = @(Get-Content -LiteralPath (Join-Path $mumpaKeep 'SHA256.json') -Raw | ConvertFrom-Json)
        $mumpaPackage = @($mumpaManifest | Where-Object { $_.file -match '^Mumpa-(.+)-windows-x64.zip$' })
        if ($mumpaPackage.Count -ne 1) { throw 'Cannot determine packaged release version' }
        $mumpaKeepVersion = [System.Management.Automation.SemanticVersion]($mumpaPackage[0].file -replace '^Mumpa-(.+)-windows-x64.zip$', '$1')
    } else {
        if (-not $mumpaCandidates.Count) { return }
        $mumpaLatest = $mumpaCandidates | Sort-Object Version -Descending | Select-Object -First 1
        $mumpaKeepVersion = $mumpaLatest.Version
        $mumpaKeep = if ($mumpaLatest.IsRelease) { $mumpaLatest.Path } else { Join-Path $mumpaArtifacts "release-$($mumpaLatest.Name)" }
    }
    # Check all retained package hashes before returning any destructive targets.
    Assert-MumpaRelease $WorkspaceRoot $mumpaKeep $mumpaKeepVersion.ToString()
    foreach ($mumpaCandidate in $mumpaCandidates) {
        if ($mumpaCandidate.Version -le $mumpaKeepVersion -and $mumpaCandidate.Path -ne $mumpaKeep) { $mumpaCandidate.Path }
    }
    foreach ($mumpaLegacyManifest in @('SHA256.json','RELEASE.json')) {
        $mumpaLegacyPath = Join-Path $mumpaArtifacts $mumpaLegacyManifest
        if (Test-Path -LiteralPath $mumpaLegacyPath) { $mumpaLegacyPath }
    }
    $mumpaLockPath = Join-Path $WorkspaceRoot 'engine-patches/managed-engine.lock.json'
    if (Test-Path -LiteralPath $mumpaLockPath) {
        $mumpaLock = Get-Content -LiteralPath $mumpaLockPath -Raw | ConvertFrom-Json
        $mumpaNeeded = @([IO.Path]::GetFileName($mumpaLock.upstream.archive), "TorrServer-$($mumpaLock.version)-source.zip")
        foreach ($mumpaArchive in Get-ChildItem -LiteralPath $mumpaArtifacts -File -Filter 'TorrServer-*-source.zip') {
            if ($mumpaArchive.Name -notin $mumpaNeeded) { $mumpaArchive.FullName }
        }
    }
}
