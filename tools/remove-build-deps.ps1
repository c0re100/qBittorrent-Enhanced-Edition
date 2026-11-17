#requires -Version 5.1
<#
.SYNOPSIS
  Removes the Windows build toolchain put in place by install-build-deps.ps1
  and reports how much disk space was freed per component.

  Author: Art Clark <Art.Clark@YMail.com> (GitHub: ArtClark)

.DESCRIPTION
  First prints the sizes recorded during installation (C:\qbt-deps\sizes.log),
  then measures every component again right before deleting it.

  Deleted by default:
    - Qt 6.10.1        C:\Qt\6.10.1               (use -KeepQt to retain)
    - vcpkg            C:\vcpkg                   (use -KeepVcpkg to retain)
    - deps / workspace C:\qbt-deps                (Boost, libtorrent, logs)
    - qBittorrent build \qBittorrent-Enhanced-Edition\build   (use -KeepQbtBuild to retain)

  Also always deletes the aqt download cache if present.

.PARAMETER NoPrompt
  Skip the interactive confirmation. Without it the script asks you to
  type REMOVE before deleting anything.

.PARAMETER KeepQt
.PARAMETER KeepVcpkg
.PARAMETER KeepQbtBuild
  Keep the named component.

.PARAMETER RemoveAqt
  Additionally uninstall the aqtinstall Python helper: "python -m pip uninstall -y aqtinstall".
#>
param(
    [switch]$NoPrompt,
    [switch]$KeepQt,
    [switch]$KeepVcpkg,
    [switch]$KeepQbtBuild,
    [switch]$RemoveAqt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Paths -- keep in sync with install-build-deps.ps1
# ---------------------------------------------------------------------------
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$QtBaseDir  = 'C:\Qt'
$QtVersion  = '6.10.1'
$VcpkgDir   = 'C:\vcpkg'
$DepsDir    = 'C:\qbt-deps'
$QbtBuild   = Join-Path $RepoRoot 'build'
$RemovalLog = Join-Path $env:TEMP 'qbttoolchain-removal.log'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-DirSizeGB([string]$LiteralPath) {
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return [double]0 }
    $sum = (Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    [math]::Round([double]$sum / 1GB, 2)
}

function Get-FreeSpaceGB {
    $root = [System.IO.Path]::GetPathRoot($DepsDir)
    $drive = $root.TrimEnd('\').TrimEnd(':')
    [double](Get-PSDrive -Name $drive -ErrorAction Stop).Free / 1GB
}

# ---------------------------------------------------------------------------
# Work
# ---------------------------------------------------------------------------
$targets = @()
if (-not $KeepQt)      { $targets += @{Name = 'Qt 6.10.1';        Path = (Join-Path $QtBaseDir $QtVersion) } }
if (-not $KeepVcpkg)   { $targets += @{Name = 'vcpkg';            Path = $VcpkgDir } }
$targets += @{Name = 'deps (C:\qbt-deps)'; Path = $DepsDir }
if (-not $KeepQbtBuild){ $targets += @{Name = 'qBittorrent build'; Path = $QbtBuild } }

$sizeLog = Join-Path $DepsDir 'sizes.log'
if (Test-Path $sizeLog) {
    Write-Host ''
    Write-Host '=== Sizes recorded during install (C:\qbt-deps\sizes.log) ===' -ForegroundColor Cyan
    Get-Content -LiteralPath $sizeLog
    Write-Host ''
}
else {
    Write-Host 'No sizes.log found (install may have never completed).' -ForegroundColor DarkYellow
}

Write-Host 'The following will be deleted:' -ForegroundColor Yellow
foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t.Path) { $mark = 'present' }
    else                                { $mark = 'absent' }
    Write-Host ('  {0,-24} {1}   [{2}]' -f $t.Name, $t.Path, $mark)
}

if (-not $NoPrompt) {
    $answer = Read-Host "`nType REMOVE and press Enter to delete these folders (Ctrl+C aborts)"
    if ($answer -ne 'REMOVE') {
        Write-Host 'Aborted -- nothing was deleted.' -ForegroundColor Red
        exit 0
    }
}

$freeBefore = Get-FreeSpaceGB
$totalFreed = [double]0

foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t.Path) {
        $size = Get-DirSizeGB $t.Path
        Remove-Item -LiteralPath $t.Path -Recurse -Force
        $totalFreed += $size
        Write-Host ('Deleted {0,-24} {1,8:N2} GB' -f $t.Name, $size) -ForegroundColor Green
    }
    else {
        Write-Host ('Skipped {0,-24} (not present)' -f $t.Name) -ForegroundColor DarkYellow
    }
}

# Prune the now-empty C:\Qt parent (unless Qt was kept).
if ((-not $KeepQt) -and (Test-Path $QtBaseDir)) {
    if (-not (Get-ChildItem $QtBaseDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item $QtBaseDir -Force
        Write-Host 'Removed empty C:\Qt parent folder.' -ForegroundColor Green
    }
}

# Always delete aqt download cache; optionally also pip-uninstall aqtinstall.
Remove-Item "$env:USERPROFILE\.cache\aqt" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\aqt" -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveAqt) {
    python -m pip uninstall -y aqtinstall 2>$null | Out-Null
}

$freeAfter = Get-FreeSpaceGB
$report = @"
Removal complete at $(Get-Date -Format 'yyyy-MM-dd HH:mm')
  Disk freed        : $([math]::Round($totalFreed,2)) GB
  Free space before : $([math]::Round($freeBefore,2)) GB
  Free space after  : $([math]::Round($freeAfter,2)) GB
"@
Write-Host ''
Write-Host $report -ForegroundColor Green
Add-Content -LiteralPath $RemovalLog -Encoding UTF8 -Value ($report + "`n" + ('-' * 70))
Write-Host "Log written to: $RemovalLog"