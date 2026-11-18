<#
.SYNOPSIS
    Package the freshly built qBittorrent into a deployable ZIP that is applied on
    top of the PortableApps.com install, bundling the Qt6 runtime alongside the exe.

.DESCRIPTION
    The official qBittorrent-enh PortableApps repack ships NO Qt DLLs (it leans on a
    system-installed Qt, which is why it doesn't run standalone). Our build links Qt6
    dynamically, so the executable REQUIRES the Qt runtimes (Qt6Core.dll, Qt6Gui.dll,
    ...) plus the platform/plugin DLLs to be in the SAME folder as qbittorrent.exe.
    windeployqt (run as part of the build) already lays all of that out inside the
    build directory. This script gathers exactly those runtime files and zips them
    under an "App\qBittorrent64\" prefix -- i.e. the PortableApps.com layout -- with
    NO enclosing per-app folder in the zip.

    Deployment: the PortableApps self-installer ("qBittorrentEnhancedPortable_<ver>.paf.exe")
    creates a per-app folder at the PortableApps base (wherever the installer places the app).
    Extract this ZIP (right-drag -> "Extract Here") INTO that per-app folder, letting its
    contents overwrite the app files the .paf.exe deployed. That updates qbittorrent.exe and
    adds the missing Qt runtimes while leaving the launcher, AppInfo, Data and translations
    intact.

    No machine-specific paths are assumed: the script only needs the repository's build
    directory. Point it at another build tree with -BuildDir if needed.

    Version is read from src/base/version.h.in the same way build_dist.sh does, so the
    artifact name stays consistent with the Linux tarballs.
#>
[CmdletBinding()]
param(
    # Repository root. Defaults to the directory that contains this script's parent.
    [string]$RepoRoot,
    # The configured CMake build tree (contains the windeployqt-staged runtime).
    [string]$BuildDir,
    # Output folder for the resulting ZIP (created if missing).
    [string]$DeployDir
)

$ErrorActionPreference = 'Stop'

# Defaults are resolved here (not in the param list) because $PSScriptRoot is not
# guaranteed to be set when default parameter values are evaluated.
if (-not $RepoRoot)   { $RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $BuildDir)   { $BuildDir   = Join-Path $RepoRoot 'build' }
if (-not $DeployDir)  { $DeployDir  = Join-Path $RepoRoot 'deploy' }

# ---------------------------------------------------------------------------
# 1. Resolve the project version (mirrors build_dist.sh).
# ---------------------------------------------------------------------------
$versionSrc = Join-Path $RepoRoot 'src\base\version.h.in'
if (-not (Test-Path -LiteralPath $versionSrc)) { throw "version.h.in not found at $versionSrc" }
$verMajor = (Select-String -Path $versionSrc -Pattern 'QBT_VERSION_MAJOR (\d+)').Matches.Groups[1].Value
$verMinor = (Select-String -Path $versionSrc -Pattern 'QBT_VERSION_MINOR (\d+)').Matches.Groups[1].Value
$verBug   = (Select-String -Path $versionSrc -Pattern 'QBT_VERSION_BUGFIX (\d+)').Matches.Groups[1].Value
$verBuild = (Select-String -Path $versionSrc -Pattern 'QBT_VERSION_BUILD (\d+)').Matches.Groups[1].Value
if ($verBuild -ne '0') {
    $projectVersion = "$verMajor.$verMinor.$verBug.$verBuild"
}
else {
    $projectVersion = "$verMajor.$verMinor.$verBug"
}

# ---------------------------------------------------------------------------
# 2. Locate the built exe; bail if it is stale or missing.
# ---------------------------------------------------------------------------
$exe = Join-Path $BuildDir 'qbittorrent.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Built executable not found: $exe (run the build first)." }

# The Qt runtime must already be staged next to the exe (Qt6Core.dll + plugin
# folders). Nothing in the upstream build does this for dynamically-linked
# builds, so bail loudly instead of packaging a bundle that cannot run.
if (-not (Test-Path -LiteralPath (Join-Path $BuildDir 'Qt6Core.dll'))) {
    throw "Qt runtime not staged next to the exe (missing $BuildDir\Qt6Core.dll). Run windeployqt first -- install-build-deps.ps1 -BuildQbt -Target qbt_app does this automatically."
}

# ---------------------------------------------------------------------------
# 3. Stage the PortableApps.COM layout in a temp folder.
#    Zip root will contain "App\qBittorrent64\..." (no per-app folder).
# ---------------------------------------------------------------------------
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "qbt-pkg-$PID"
$appDir = Join-Path $stageRoot 'App\qBittorrent64'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null

# 3a. App binary.
Copy-Item -LiteralPath $exe -Destination (Join-Path $appDir 'qbittorrent.exe') -Force

# 3b. Qt runtime DLLs that windeployqt placed next to the exe in the build dir
#     (the dynamically-linked Qt6 libraries qbittorrent.exe needs at runtime).
Get-ChildItem -LiteralPath $BuildDir -File -Filter '*.dll' -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $appDir $_.Name) -Force }

# 3c. Qt plugin directories (platforms, styles, imageformats, ...). windeployqt
#     put them at the build root; each becomes a subfolder next to the exe.
$pluginDirs = @('platforms','styles','imageformats','iconengines','generic','networkinformation','sqldrivers','tls')
foreach ($p in $pluginDirs) {
    $src = Join-Path $BuildDir $p
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $appDir $p) -Recurse -Force
    }
}

# 3d. qt.conf so Qt finds the (already present) portable translations folder.
Set-Content -LiteralPath (Join-Path $appDir 'qt.conf') -Encoding ASCII -Value @(
    '[Paths]'
    'Translations = translations'
    ''
    '[Platforms]'
    ';WindowsArguments = dpiawareness=1'
)

# ---------------------------------------------------------------------------
# 4. Zip the staged "App" folder (root = App\qBittorrent64\...).
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null
$zipName = "qBittorrentEnhancedPortable_$projectVersion.zip"
$zipPath = Join-Path $DeployDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# ---------------------------------------------------------------------------
# 5. Report + cleanup.
#    The staging folder is a temp folder created at the start of this run and is
#    removed here, so there is nothing stale left behind between runs. The ZIP in
#    $DeployDir is overwritten atomically below on every run, so re-running simply
#    produces a fresh archive (no accumulation of old packages).
# ---------------------------------------------------------------------------
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
$mb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
Write-Host "Packaged: $zipPath  ($mb MB)"
Write-Host "Deploy:   after running the .paf.exe installer, extract this ZIP INTO the"
Write-Host "          per-app folder it created, overwriting the deployed app files."
Write-Output $zipPath
