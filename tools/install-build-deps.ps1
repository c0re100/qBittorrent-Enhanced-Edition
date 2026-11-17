#requires -Version 5.1
<#
.SYNOPSIS
  Installs the Windows build toolchain for qBittorrent-Enhanced-Edition
  (Qt, vcpkg dependencies, Boost headers, libtorrent) and captures the
  on-disk size of every component as it is added.

  Author: Art Clark <Art.Clark@YMail.com> (GitHub: ArtClark)

.DESCRIPTION
  - No special prompt required: the script auto-initializes the Visual Studio
    developer environment (VS 2022 or VS 18 Insiders) when cl.exe is not already
    on PATH. Running from a VS developer prompt also works.
  - Appends each component's size and the remaining free space to
    C:\qbt-deps\sizes.log (append-only; also printed at the end).
  - Prunes transient artifacts (download caches, buildtrees, the libtorrent
    build dir) so the retained footprint stays small.

.PARAMETER BuildQbt
  After installing the dependencies, also configure and build the qbt_gui
  target of this repository (compiles all GUI dialogs, including the
  dialog-geometry changes).

.PARAMETER SkipQt
.PARAMETER SkipVcpkg
.PARAMETER SkipBoost
.PARAMETER SkipLibtorrent
  Skip the given component. Useful for resuming after an interrupted run.

.PARAMETER MinFreeGB
  Abort when free disk space drops below this many GB (default: 6).

.PARAMETER Jobs
  Maximum parallel compile jobs passed to ninja. Default: one per logical
  processor (ninja's own default). Lower it on memory-constrained machines
  (e.g. 4 cores / 8 GB RAM) -- an uncapped C++ build can thrash RAM hard.

.PARAMETER Target
  Which CMake/ninja target to build when -BuildQbt is set (default: qbt_gui,
  the static GUI library that compiles every dialog). Pass 'qbt_app' (the
  executable target, produced as qbittorrent.exe) instead.

.PARAMETER LogFile
  Also write a full transcript (all console output, including native build
  tool output) to this file. Useful when running detached/headless: the
  transcript is independent of the calling console.
#>
param(
    [switch]$BuildQbt,
    [switch]$SkipQt,
    [switch]$SkipVcpkg,
    [switch]$SkipBoost,
    [switch]$SkipLibtorrent,
    [int]$MinFreeGB = 6,
    [int]$Jobs = 0,
    [string]$Target = 'qbt_gui',
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($LogFile) {
    Start-Transcript -LiteralPath $LogFile -Force
}

# ---------------------------------------------------------------------------
# Paths / versions -- keep in sync with remove-build-deps.ps1
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$QtBaseDir = 'C:\Qt'
$QtVersion = '6.10.1'
$QtArch    = 'win64_msvc2022_64'
$VcpkgDir  = 'C:\vcpkg'
$DepsDir   = 'C:\qbt-deps'
$CacheDir  = Join-Path $DepsDir 'cache'
$BoostDir  = Join-Path $DepsDir 'boost'
$BoostVer  = '1.90.0'
$BoostDirName = 'boost_1_90_0'
$LibtorrentDir  = Join-Path $DepsDir 'libtorrent'
$LibtorrentVer  = '2.0.11'
$Triplet   = 'x64-windows-static-md-release'
$SizeLog   = Join-Path $DepsDir 'sizes.log'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-FreeSpaceGB {
    $root = [System.IO.Path]::GetPathRoot($DepsDir)
    $drive = $root.TrimEnd('\').TrimEnd(':')
    [double](Get-PSDrive -Name $drive -ErrorAction Stop).Free / 1GB
}

function Get-DirSizeGB([string]$LiteralPath) {
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return [double]0 }
    $sum = (Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    [math]::Round([double]$sum / 1GB, 2)
}

function Write-Status([string]$msg) {
    Write-Host ''
    Write-Host "=== $msg ===" -ForegroundColor Cyan
    Add-Content -LiteralPath $SizeLog -Encoding UTF8 -Value ("`n[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $msg)
}

function Log-Size([string]$name, [string]$LiteralPath) {
    $size = Get-DirSizeGB $LiteralPath
    $free = Get-FreeSpaceGB
    $line = '{0,-34} {1,8:N2} GB   (free space now: {2,6:N2} GB)' -f $name, $size, $free
    Write-Host $line
    Add-Content -LiteralPath $SizeLog -Encoding UTF8 -Value $line
}

function Assert-FreeSpace {
    $free = Get-FreeSpaceGB
    if ($free -lt $MinFreeGB) {
        throw "Only $([math]::Round($free,2)) GB free -- below the $MinFreeGB GB safety limit. Free up space and re-run."
    }
}

function Resolve-QtPrefix {
    # Locate the Qt installation directory for $QtVersion. aqt installs into a
    # normalized directory name (currently 'msvc2022_64') regardless of the arch
    # spec passed to 'aqt install-qt', and that naming can differ between aqt
    # releases -- so never hardcode it: scan for whichever dir actually holds
    # qmake.exe. Mirrors the VsDevCmd.bat self-discovery approach above.
    $versionRoot = Join-Path $QtBaseDir $QtVersion
    if (Test-Path -LiteralPath $versionRoot) {
        foreach ($d in (Get-ChildItem -LiteralPath $versionRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'bin\qmake.exe')) {
                return $d.FullName
            }
        }
    }
    # Fallback: the layout aqt uses today, in case the scan finds nothing.
    Join-Path $QtBaseDir "$QtVersion\msvc2022_64"
}

function Clear-PartialQt() {
    # Remove any half-finished Qt install dirs (no qmake.exe) so a re-run of
    # Step 1 can retry from scratch instead of tripping over leftover files.
    $versionRoot = Join-Path $QtBaseDir $QtVersion
    if (Test-Path -LiteralPath $versionRoot) {
        Get-ChildItem -LiteralPath $versionRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName 'bin\qmake.exe')) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Import-VsDevEnvironment {
    # Locate Visual Studio's VsDevCmd.bat dynamically (VS 2022, VS 18 Insiders,
    # future versions) and import its environment into this session
    # (cl.exe, INCLUDE/LIB for MSVC + Windows SDK, VS-shipped CMake/Ninja dirs).
    # Paths are discovered dynamically because Insiders builds change paths weekly.
    $vsDevCmd = $null
    $owners = @(
        'C:\Program Files\Microsoft Visual Studio'
        'C:\Program Files (x86)\Microsoft Visual Studio'
    )
    foreach ($owner in $owners) {
        foreach ($lvl1 in (Get-ChildItem -Path $owner -Directory -ErrorAction SilentlyContinue)) {
            foreach ($lvl2 in (Get-ChildItem -Path $lvl1.FullName -Directory -ErrorAction SilentlyContinue)) {
                $candidate = Join-Path $lvl2.FullName 'Common7\Tools\VsDevCmd.bat'
                if (Test-Path -LiteralPath $candidate) { $vsDevCmd = $candidate; break }
            }
            if ($vsDevCmd) { break }
        }
        if ($vsDevCmd) { break }
    }
    if (-not $vsDevCmd) {
        throw @"
cl.exe was not found on PATH and no Visual Studio (VsDevCmd.bat) was detected.

Options:
  - Run this script from a Visual Studio "Developer PowerShell" / developer prompt, or
  - Make sure Visual Studio with the "Desktop development with C++" workload is installed.
"@
    }
    Write-Host "Loading Visual Studio developer environment from:`n  $vsDevCmd"
    $envLines = & cmd /c ("`"$vsDevCmd`" -arch=x64 >nul 2>&1 && set")
    if ($LASTEXITCODE -ne 0) { throw 'VsDevCmd.bat failed to initialize the developer environment.' }
    foreach ($line in $envLines) {
        if ($line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw 'MSVC environment still unavailable after loading VsDevCmd.bat.'
    }
}

function Initialize-BuildToolchain {
    if (-not (Get-Command python.exe -ErrorAction SilentlyContinue)) {
        throw 'python.exe was not found on PATH. Install Python 3.9+ and add it to PATH.'
    }

    # MSVC environment active? Otherwise ask Visual Studio's dev shell for one.
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        Import-VsDevEnvironment
    }

    # VS-shipped CMake / Ninja are usually not on PATH in a plain prompt, but
    # live inside the VS installation. Add them if CMake/Ninja are missing.
    $toAdd = @()
    $owners = @(
        'C:\Program Files\Microsoft Visual Studio'
        'C:\Program Files (x86)\Microsoft Visual Studio'
    )
    foreach ($owner in $owners) {
        foreach ($lvl1 in (Get-ChildItem -Path $owner -Directory -ErrorAction SilentlyContinue)) {
            foreach ($lvl2 in (Get-ChildItem -Path $lvl1.FullName -Directory -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) {
                    $p = Join-Path $lvl2.FullName 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
                    if (Test-Path (Join-Path $p 'ninja.exe')) { $toAdd += $p }
                }
                if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) {
                    $p = Join-Path $lvl2.FullName 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
                    if (Test-Path (Join-Path $p 'cmake.exe')) { $toAdd += $p }
                }
            }
        }
    }
    if ($toAdd.Count -gt 0) { $env:PATH = ($toAdd -join ';') + ';' + $env:PATH }

    foreach ($tool in 'cl','cmake','ninja','git') {
        if (-not (Get-Command "$tool.exe" -ErrorAction SilentlyContinue)) {
            throw "Required tool '$tool' is not available. Install it and re-run (e.g. 'choco install cmake ninja git')."
        }
    }
    Write-Host ('Toolchain ready:  cl = {0}' -f (Get-Command cl.exe).Source)
    Write-Host ('                  cmake = {0}' -f (Get-Command cmake.exe).Source)
    Write-Host ('                  ninja = {0}' -f (Get-Command ninja.exe).Source)
    Write-Host ('                  git  = {0}' -f (Get-Command git.exe).Source)
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
try {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    if (-not (Test-Path $SizeLog)) { New-Item -ItemType File -Force -Path $SizeLog | Out-Null }

    $startFree = Get-FreeSpaceGB
    Write-Host "Free space at start: $([math]::Round($startFree,2)) GB" -ForegroundColor Yellow
    if ($startFree -lt $MinFreeGB) {
        throw "Only $([math]::Round($startFree,2)) GB free. At least $MinFreeGB GB is recommended before starting."
    }

    Initialize-BuildToolchain
    Write-Status 'Starting toolchain install'
    Log-Size 'baseline' $DepsDir

    # ---- Step 1/5: Qt ----------------------------------------------------
    if (-not $SkipQt) {
        $qtBin = Resolve-QtPrefix
        if (Test-Path (Join-Path $qtBin 'bin\qmake.exe')) {
            Write-Host 'Qt already installed -- skipping step 1.' -ForegroundColor DarkYellow
        }
        else {
            Assert-FreeSpace
            Write-Status 'Step 1/5: Installing Qt 6.10.1 (aqtinstall)'
            python -m pip install --quiet --disable-pip-version-check aqtinstall
            if ($LASTEXITCODE -ne 0) { throw 'pip install aqtinstall failed.' }
            python -m aqt install-qt windows desktop $QtVersion $QtArch -O $QtBaseDir --archives qtbase qtsvg qttools -m qtimageformats
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'aqt install-qt failed; removing partial Qt install so a re-run can retry cleanly.' -ForegroundColor DarkYellow
                Clear-PartialQt
                throw 'aqt install-qt failed.'
            }
            $qtBin = Resolve-QtPrefix   # pick up the real install dir
            if (-not (Test-Path (Join-Path $qtBin 'bin\qmake.exe'))) {
                throw "Qt was installed but qmake.exe was not found under $QtBaseDir\$QtVersion."
            }
        }
        Log-Size 'Qt (C:\Qt)' $QtBaseDir

        # Free the aqt download cache (the archive 7z files are large).
        Remove-Item "$env:USERPROFILE\.cache\aqt" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\aqt" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- Step 2/5: vcpkg ------------------------------------------------
    if (-not $SkipVcpkg) {
        if (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe')) {
            Write-Host 'vcpkg already installed -- skipping steps 2-3.' -ForegroundColor DarkYellow
        }
        else {
            Assert-FreeSpace
            Write-Status 'Step 2/5: Cloning vcpkg'
            git clone --depth 1 https://github.com/microsoft/vcpkg.git $VcpkgDir
            if ($LASTEXITCODE -ne 0) { throw 'vcpkg clone failed.' }
            Write-Status 'Step 2/5: Bootstrapping vcpkg'
            & (Join-Path $VcpkgDir 'bootstrap-vcpkg.bat') -DisableMetrics
            if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed.' }
            Log-Size 'vcpkg (clone + bootstrap)' $VcpkgDir
        }

        if (Test-Path (Join-Path $VcpkgDir "installed\$Triplet")) {
            Write-Host 'vcpkg packages already installed -- skipping step 3.' -ForegroundColor DarkYellow
        }
        else {
            Assert-FreeSpace
            Write-Status 'Step 3/5: Installing openssl / zlib / boost-build via vcpkg'
            $overlay = Join-Path $VcpkgDir 'triplets_overlay'
            New-Item -ItemType Directory -Force -Path $overlay | Out-Null
            Set-Content -LiteralPath (Join-Path $overlay "$Triplet.cmake") -Encoding ASCII -Value @(
                'set(VCPKG_TARGET_ARCHITECTURE x64)'
                'set(VCPKG_LIBRARY_LINKAGE static)'
                'set(VCPKG_CRT_LINKAGE dynamic)'
                'set(VCPKG_BUILD_TYPE release)'
            )
            & (Join-Path $VcpkgDir 'vcpkg.exe') install --clean-after-build --overlay-triplets="$overlay" `
                "boost-build:$Triplet" "openssl:$Triplet" "zlib:$Triplet"
            if ($LASTEXITCODE -ne 0) { throw 'vcpkg install failed.' }
            Log-Size 'vcpkg installed packages' (Join-Path $VcpkgDir 'installed')
        }
    }

    # ---- Step 4/5: Boost -------------------------------------------------
    if (-not $SkipBoost) {
        if (Test-Path (Join-Path $BoostDir 'lib\cmake')) {
            Write-Host 'Boost already staged -- skipping step 4.' -ForegroundColor DarkYellow
        }
        else {
            Assert-FreeSpace
            Write-Status 'Step 4/5: Downloading + staging Boost 1.90.0'
            $tarPath = Join-Path $CacheDir "$BoostDirName.tar.gz"
            if (-not (Test-Path $tarPath)) {
                $boostUrl = "https://archives.boost.io/release/$BoostVer/source/$BoostDirName.tar.gz"
                Write-Host "Downloading $boostUrl"
                Invoke-WebRequest -Uri $boostUrl -OutFile $tarPath -UseBasicParsing
                if (-not (Test-Path $tarPath)) { throw 'Boost download failed.' }
            }

            if (-not (Test-Path $BoostDir)) {
                tar -xf $tarPath -C $CacheDir
                if ($LASTEXITCODE -ne 0) { throw 'Boost extraction failed.' }
                Move-Item -Force (Join-Path $CacheDir $BoostDirName) $BoostDir
                Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
            }

            $b2 = Join-Path $VcpkgDir "installed\$Triplet\tools\boost-build\b2.exe"
            if (-not (Test-Path $b2)) { throw "boost-build is missing -- expected at $b2" }

            Write-Status 'Step 4/5: Staging Boost headers (b2 --with-headers)'
            Push-Location $BoostDir
            try {
                & $b2 stage toolset=msvc --stagedir=. --with-headers
                if ($LASTEXITCODE -ne 0) { throw 'b2 stage failed.' }
            }
            finally { Pop-Location }

            if (-not (Test-Path (Join-Path $BoostDir 'lib\cmake'))) {
                Write-Host 'WARNING: Boost cmake config not found under lib\cmake -- BOOST_ROOT may need adjusting.' -ForegroundColor DarkYellow
            }
        }
        Log-Size 'Boost (C:\qbt-deps\boost)' $BoostDir
    }

    # ---- Step 5/5: libtorrent -------------------------------------------
    if (-not $SkipLibtorrent) {
        $ltInstall = Join-Path $LibtorrentDir 'install'
        $ltConfig  = Join-Path $ltInstall 'lib\cmake\LibtorrentRasterbar'
        if (Test-Path $ltConfig) {
            Write-Host 'libtorrent already installed -- skipping step 5.' -ForegroundColor DarkYellow
        }
        else {
            Assert-FreeSpace
            Write-Status 'Step 5/5: Building libtorrent 2.0.11'
            if (-not (Test-Path (Join-Path $LibtorrentDir 'CMakeLists.txt'))) {
                git clone --depth 1 --branch "v$LibtorrentVer" --recurse-submodules https://github.com/arvidn/libtorrent.git $LibtorrentDir
                if ($LASTEXITCODE -ne 0) { throw 'libtorrent clone failed.' }
            }

            $ltBuild = Join-Path $LibtorrentDir 'build'
            $ltCmakeArgs = @(
                '-B', $ltBuild
                '-G', 'Ninja'
                '-DCMAKE_BUILD_TYPE=RelWithDebInfo'
                '-DCMAKE_CXX_STANDARD=20'
                "-DCMAKE_INSTALL_PREFIX=$ltInstall"
                "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $VcpkgDir 'scripts\buildsystems\vcpkg.cmake')"
                "-DBOOST_ROOT=$(Join-Path $BoostDir 'lib\cmake')"
                '-DBUILD_SHARED_LIBS=OFF'
                '-Ddeprecated-functions=OFF'
                '-Dstatic_runtime=OFF'
                "-DVCPKG_TARGET_TRIPLET=$Triplet"
            )
            Push-Location $LibtorrentDir
            try {
                & cmake @ltCmakeArgs
                if ($LASTEXITCODE -ne 0) { throw 'libtorrent cmake configure failed.' }
                $ltBuildArgs = @('--build', $ltBuild)
                if ($Jobs -gt 0) { $ltBuildArgs += @('--', '-j', "$Jobs") }
                & cmake @ltBuildArgs
                if ($LASTEXITCODE -ne 0) { throw 'libtorrent build failed.' }
                & cmake --install $ltBuild
                if ($LASTEXITCODE -ne 0) { throw 'libtorrent install failed.' }
            }
            finally { Pop-Location }

            Log-Size 'libtorrent (build + install)' $LibtorrentDir
            # Prune the intermediate build dir; the install/ tree is all CMake needs.
            Remove-Item $ltBuild -Recurse -Force -ErrorAction SilentlyContinue
        }
        Log-Size 'libtorrent (install only)' $LibtorrentDir
    }

    # ---- Step 6 (optional): build qBittorrent ---------------------------
    if ($BuildQbt) {
        Assert-FreeSpace
        $qtPrefix = Resolve-QtPrefix
        $ltConfig = Join-Path $LibtorrentDir 'install\lib\cmake\LibtorrentRasterbar'
        if (-not (Test-Path (Join-Path $qtPrefix 'lib\cmake\Qt6'))) { throw 'Qt not found -- cannot build qbt_gui without -SkipQt=false.' }
        if (-not (Test-Path $ltConfig)) { throw 'libtorrent not installed -- cannot build qbt_gui without -SkipLibtorrent=false.' }
        if (-not (Test-Path (Join-Path $BoostDir 'lib\cmake'))) { throw 'Boost not staged -- cannot build qbt_gui without -SkipBoost=false.' }

        Write-Status "Step 6: Building qBittorrent (target: $Target)"
        $qbtBuild = Join-Path $RepoRoot 'build'
        $qbtCmakeArgs = @(
            '-B', $qbtBuild
            '-G', 'Ninja'
            '-DCMAKE_BUILD_TYPE=RelWithDebInfo'
            "-DCMAKE_PREFIX_PATH=$qtPrefix"
            "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $VcpkgDir 'scripts\buildsystems\vcpkg.cmake')"
            "-DBOOST_ROOT=$(Join-Path $BoostDir 'lib\cmake')"
            "-DLibtorrentRasterbar_DIR=$ltConfig"
            '-DMSVC_RUNTIME_DYNAMIC=ON'
            '-DTESTING=OFF'
            '-DVERBOSE_CONFIGURE=ON'
            "-DVCPKG_TARGET_TRIPLET=$Triplet"
        )
        Push-Location $RepoRoot
        try {
            if (-not (Test-Path (Join-Path $qbtBuild 'CMakeCache.txt'))) {
                & cmake @qbtCmakeArgs
                if ($LASTEXITCODE -ne 0) { throw 'qBittorrent cmake configure failed.' }
            }
            $buildArgs = @('--build', $qbtBuild, '--target', $Target)
            if ($Jobs -gt 0) { $buildArgs += @('--', '-j', "$Jobs") }
            & cmake @buildArgs
            if ($LASTEXITCODE -ne 0) { throw "qBittorrent ($Target target) build failed." }

            # windeployqt: stage the dynamically-linked Qt runtime (Qt6*.dll +
            # plugin folders) next to the exe in $qbtBuild, where package_zip.ps1
            # expects it. Only meaningful for the executable target; qbt_gui
            # produces no exe yet. --compiler-runtime also copies the MSVC C++
            # runtime (MSVCP140.dll/VCRUNTIME140.dll) that qbittorrent.exe imports.
            # --no-translations: the PortableApps layout ships its own translations
            # folder, pointed at via qt.conf.
            $qbtAppExe = Join-Path $qbtBuild 'qbittorrent.exe'
            if ($Target -eq 'qbt_app' -and (Test-Path -LiteralPath $qbtAppExe)) {
                $windeployqt = Join-Path $qtPrefix 'bin\windeployqt.exe'
                if (Test-Path -LiteralPath $windeployqt) {
                    Write-Status 'Step 6: Staging Qt runtime (windeployqt)'
                    & $windeployqt --no-translations --compiler-runtime $qbtAppExe
                    if ($LASTEXITCODE -ne 0) { throw 'windeployqt failed.' }
                }
                else {
                    Write-Host "WARNING: windeployqt.exe not found at $windeployqt - Qt runtime NOT staged. package_zip.ps1 will produce a bundle that cannot run standalone." -ForegroundColor DarkYellow
                }
            }
        }
        finally { Pop-Location }
        Log-Size 'qBittorrent build' $qbtBuild
    }

    # ---- Final tidy-up --------------------------------------------------
    if (-not $SkipVcpkg) {
        Remove-Item (Join-Path $VcpkgDir 'buildtrees') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $VcpkgDir 'downloads') -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $VcpkgDir 'installed')) {
            Log-Size 'vcpkg (final, buildtrees/downloads pruned)' $VcpkgDir
        }
    }

    Write-Status 'Toolchain install complete'
    Write-Host ''
    Write-Host '=== Size log (C:\qbt-deps\sizes.log) ===' -ForegroundColor Green
    Get-Content -LiteralPath $SizeLog
    Write-Host ''
    Write-Host "Final free space: $([math]::Round((Get-FreeSpaceGB),2)) GB" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Next: run  .\remove-build-deps.ps1  in tools/ to tear everything down later.' -ForegroundColor Green
    if ($LogFile) { Stop-Transcript -ErrorAction SilentlyContinue }
}
catch {
    Write-Host ''
    Write-Host "ERROR: $_" -ForegroundColor Red
    Add-Content -LiteralPath $SizeLog -Encoding UTF8 -Value ("ERROR: $_") -ErrorAction SilentlyContinue
    if ($LogFile) { Stop-Transcript -ErrorAction SilentlyContinue }
    exit 1
}