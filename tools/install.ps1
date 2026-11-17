<#
.SYNOPSIS
    Deploy the latest packaged ZIP on top of a PortableApps.com qBittorrent install.

.DESCRIPTION
    Picks up the single ZIP produced by package_zip.ps1 (repo\deploy\qBittorrentEnhancedPortable_<ver>.zip)
    and extracts it INTO the per-app folder created by the PortableApps self-installer
    ("qBittorrentEnhancedPortable_<ver>.paf.exe"). The zip's App\qBittorrent64\... entries
    overwrite the deployed app files, updating qbittorrent.exe and adding the missing Qt6
    runtime, while leaving the launcher, AppInfo, Data, DefaultData and translations intact.

    No confirmation is requested. Afterwards the path to qbittorrent.exe is printed (so it
    can be copied from the screen) and you are asked whether to launch the application.

    The target per-app folder is a TEST path (points at a machine-local PortableApps tree).
    Point -PortableAppsDir at the real PortableApps base to change where the app folder lives.
#>
[CmdletBinding()]
param(
    # Repository root. Defaults to the directory that contains this script's parent.
    [string]$RepoRoot,
    # Folder holding the packaged ZIP (repo\deploy by default).
    [string]$DeployDir,
    # The per-app folder to deploy into (this is the PortableApps install target).
    [string]$PortableAppsPerAppDir = 'E:\PortableApps\qBittorrentEnhancedPortable2'
)

$ErrorActionPreference = 'Stop'

# Defaults are resolved here (not in the param list) because $PSScriptRoot is not
# guaranteed to be set when default parameter values are evaluated.
if (-not $RepoRoot)  { $RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $DeployDir) { $DeployDir = Join-Path $RepoRoot 'deploy' }

# ---------------------------------------------------------------------------
# 1. Locate the single packaged ZIP.
# ---------------------------------------------------------------------------
$zips = @(Get-ChildItem -LiteralPath $DeployDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
if ($zips.Count -eq 0) { throw "No packaged ZIP found in $DeployDir (run tools\package_zip.ps1 first)." }
if ($zips.Count -gt 1) { throw "Multiple ZIPs found in $DeployDir. Keep only the one to install." }
$zip = $zips[0]

# ---------------------------------------------------------------------------
# 2. Validate the target per-app folder exists (created by the .paf.exe).
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $PortableAppsPerAppDir)) {
    throw "Per-app folder not found: $PortableAppsPerAppDir (run the qBittorrentEnhancedPortable_*.paf.exe installer first)."
}

# ---------------------------------------------------------------------------
# 3. Extract the ZIP on top of the per-app folder (overwrite deployed files).
# ---------------------------------------------------------------------------
Write-Host "Deploying '$($zip.Name)' -> $PortableAppsPerAppDir"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Extract entry-by-entry with overwrite. The framework-style
# ZipFile::ExtractToDirectory(src, dst, $overwrite) overload used here previously does not
# exist in .NET Framework (Windows PowerShell 5.1) -- only in the newer .NET API used by
# PowerShell 7. ExtractToFile is an extension method (ZipFileExtensions), which PowerShell
# does not bind as an instance member, so it is invoked statically; the trailing $true
# overwrites an existing file and works on all runtimes.
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
try {
    foreach ($entry in $archive.Entries) {
        $target = Join-Path $PortableAppsPerAppDir $entry.FullName
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    }
}
finally {
    $archive.Dispose()
}

# The per-app binary now on disk (the standard PortableApps.COM layout).
$appExe = Join-Path $PortableAppsPerAppDir 'App\qBittorrent64\qbittorrent.exe'

# ---------------------------------------------------------------------------
# 4. Report the path (copy-able) and offer to launch the application.
# ---------------------------------------------------------------------------
$appExe = [System.IO.Path]::GetFullPath($appExe)
if (-not (Test-Path -LiteralPath $appExe)) {
    Write-Warning "Expected executable not found after extraction: $appExe"
    Write-Host "Application path: $appExe"
    exit 0
}

Write-Host ""
Write-Host "Application path: $appExe"
Write-Host ""
$launch = Read-Host 'Start the application now? [Y/n]'
if ($launch -eq '' -or $launch -match '^(y|yes)$' -or $launch -match '^(Y|YES)$') {
    # The PortableApps shim file must normally be executed to
    # use the roaming profile within the PortableApps' folder.
    # For example, this would be the proper binary to start:
    # "<per-app folder>\qBittorrentEnhancedPortable.exe"
    Start-Process -FilePath $appExe
    Write-Host 'Launched.'
}
else {
    Write-Host 'Not launched.'
}
