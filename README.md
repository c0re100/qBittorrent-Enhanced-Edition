# qBittorrent - A BitTorrent client in Qt

[![GitHub Actions CI Status](https://github.com/qbittorrent/qBittorrent/actions/workflows/ci_ubuntu.yaml/badge.svg)](https://github.com/qbittorrent/qBittorrent/actions)
[![Coverity Status](https://scan.coverity.com/projects/5494/badge.svg)](https://scan.coverity.com/projects/5494)

> **Note:** This repository is a **personal working fork** of
> [qBittorrent-Enhanced-Edition](https://github.com/c0re100/qBittorrent-Enhanced-Edition),
> created as a working copy to prepare and submit patches to qBittorrent. It is **not**
> and will **not** be regularly synchronized or updated with the upstream repository.
> For daily use, releases, and issue reporting, please use the upstream project instead.
>
> **Author:** **Art Clark** — GitHub: [ArtClark](https://github.com/ArtClark) · Email: Art.Clark@YMail.com
>
> The fork's Windows build/deploy scripts live in [`tools/`](tools) — see
> [Windows build toolchain for this fork](#windows-build-toolchain-for-this-fork).

qBittorrent is a [BitTorrent] client programmed in C++ / Qt that uses
[libtorrent] (sometimes called libtorrent-rasterbar) by Arvid Norberg.

It aims to be a good alternative to all other BitTorrent clients
out there. qBittorrent is fast, stable and provides Unicode
support as well as many features.

The free [IP to Country Lite database] by [DB-IP] is used for resolving the countries of peers.
The database is licensed under the [Creative Commons Attribution 4.0 International License].

[BitTorrent]: https://en.wikipedia.org/wiki/BitTorrent
[Creative Commons Attribution 4.0 International License]: https://creativecommons.org/licenses/by/4.0/
[DB-IP]: https://db-ip.com/
[IP to Country Lite database]: https://db-ip.com/db/download/ip-to-country-lite
[libtorrent]: https://libtorrent.org/

## Installation

Refer to the [INSTALL] file.

[INSTALL]: INSTALL

## Windows build toolchain for this fork

> The instructions below apply **only to this personal fork** and its Windows
> development setup. Everything is scripted: the install script records how much
> disk each component uses as it is installed (`C:\qbt-deps\sizes.log`), and the
> removal script deletes the whole toolchain again afterwards.

**Prerequisites** — everything below is **already installed on this machine**
(verified 2026-11-17 against `C:\repos\tools\tools.json`); no action needed. The install script
takes care of the rest automatically.

* **Visual Studio 18 (Insiders)** with the C++ workload — MSVC 19.52, Windows SDK
  (10.0.26100 / 10.0.28000). Insider builds change paths weekly, so the install
  script discovers everything dynamically via the VS developer shell rather than
  hardcoding paths.
* **CMake 4.4.3** (standalone, `C:\Program Files\CMake`)
* **Ninja 1.13.2** (bundled with Visual Studio)
* **Git for Windows 2.53.0**
* **Python 3.14.7** (used by `aqtinstall` to fetch Qt)
* **Chocolatey 2.7.4** (available if ever needed)
* ~15 GB of free disk is comfortable; the retained footprint is ~4.6 GB — see
  the table below, and allow ~6 GB of headroom for the install itself.

What the install script adds that you do **not** already have: Qt, vcpkg and its
packages, Boost headers, and libtorrent — see the table below.

**Install** — run from **any PowerShell prompt**. The script auto-loads the
Visual Studio developer shell if `cl.exe` is not already on PATH (running it from
a VS developer prompt works too):

```pwsh
cd C:\repos\qBittorrent-Enhanced-Edition\tools
.\install-build-deps.ps1                 # Qt, vcpkg deps, Boost, libtorrent
.\install-build-deps.ps1 -BuildQbt       # same, and also builds qbt_gui (all GUI dialogs)
```

Each step appends its on-disk size and the remaining free space to
`C:\qbt-deps\sizes.log`. The table below is transcribed from that log
(run of 2026-09-24, 4-core / 8 GB machine), not estimated:

| Component | Location | Size |
| --- | --- | --- |
| Qt 6.10.1 (`win64_msvc2022_64` + qtimageformats) | `C:\Qt` | 2.00 GB |
| vcpkg (clone, bootstrap, boost-build/openssl/zlib) | `C:\vcpkg` | 0.21 GB |
| Boost 1.90.0 headers (staged via `b2`) | `C:\qbt-deps\boost` | 0.98 GB |
| libtorrent 2.0.11 (static, `RelWithDebInfo`) | `C:\qbt-deps\libtorrent` | 0.64 GB |
| qBittorrent build | `<repo>\build` | 0.79 GB |
| **Total retained** | | **4.62 GB** |

Transient build artifacts (boost archive, aqt download cache, vcpkg
buildtrees/downloads, the libtorrent intermediate `build` dir) are pruned
automatically, so these figures are **post-prune** — what is left once the
install finishes. Peak usage part-way through the install is higher; allow
roughly 6 GB of headroom rather than 4.62 GB.

Two rows are worth understanding before you start, because both are larger
than a first guess would suggest:

* **libtorrent's 0.64 GB is almost entirely one file.**
  `install\lib\torrent-rasterbar.lib` is **569.67 MB** — a *static* archive
  compiled `RelWithDebInfo`, so debug information is embedded per object file.
  The intermediate `build` directory that gets pruned was never the bulk, which
  is the easy mistake to make when sizing this. Building libtorrent as `Release`
  instead of `RelWithDebInfo` drops this row by several hundred MB.
* **vcpkg is 0.21 GB only after pruning.** Its `buildtrees` and `downloads`
  directories exist for the duration of the run and are removed at the end.

Boost is 0.98 GB across ~93,000 files, most of which are documentation and
per-library headers rather than anything the build reads.

**Measured times** (first full `qbt_app` build, 2026-09-24, on a 4-core / 8 GB
machine): CMake configure **~125 s**, full build (**408 translation units**,
incl. translations + RCC) **~48 min**, whole scripted chain **~51 min**; the
feature file `dialoggeometry.cpp` compiled clean. The build directory is the
0.79 GB row above, so the retained footprint is **4.62 GB**, matching the total
in the table. Note for small machines: use `-Jobs` to cap parallelism and keep
RAM thrash down.

**Build manually** (if you did not use `-BuildQbt`):

```pwsh
cd C:\repos\qBittorrent-Enhanced-Edition
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo `
    -DCMAKE_PREFIX_PATH="C:\Qt\6.10.1\msvc2022_64" `
    -DCMAKE_TOOLCHAIN_FILE="C:\vcpkg\scripts\buildsystems\vcpkg.cmake" `
    -DBOOST_ROOT="C:\qbt-deps\boost\lib\cmake" `
    -DLibtorrentRasterbar_DIR="C:\qbt-deps\libtorrent\install\lib\cmake\LibtorrentRasterbar" `
    -DMSVC_RUNTIME_DYNAMIC=ON `
    -DTESTING=OFF `
    -DVCPKG_TARGET_TRIPLET=x64-windows-static-md-release
cmake --build build --target qbt_gui   # or qbt_app for the full executable
```

**Package as a PortableApps.com update ZIP** (after a successful build):

```pwsh
cd C:\repos\qBittorrent-Enhanced-Edition\tools
.\package_zip.ps1                     # -> <repo>\deploy\qBittorrentEnhancedPortable_<ver>.zip
```

The official PortableApps repack of qBittorrent-enh is **fully statically linked**: its
44.9 MB `qbittorrent.exe` imports no Qt DLLs at all (confirmed via `dumpbin /IMPORTS` — no
Qt6/libtorrent/CRT imports, only Windows system DLLs). Qt, libtorrent, Boost, OpenSSL and
the C++ runtime are all compiled into that single exe, which is why the package ships with
no DLLs and runs standalone.

Our build, by contrast, links Qt6 **dynamically**: `qbittorrent.exe` (≈21.4 MB) imports
`Qt6Core.dll`, `Qt6Gui.dll`, etc., and the C++ runtime (`MSVCP140.dll`/`VCRUNTIME140.dll`).
So our package **must** ship those DLLs + the platform/plugin DLLs in the same folder to run
standalone. `package_zip.ps1` collects exactly those from the build directory and zips them
under an `App\qBittorrent64\` prefix (no enclosing per-app folder), producing
`qBittorrentEnhancedPortable_<ver>.zip` in the `deploy/` folder.

To deploy, first run the official self-installer
(`qBittorrentEnhancedPortable_<ver>.paf.exe`), let it create the per-app folder, then
extract this ZIP **into that folder** (right-drag → "Extract Here"), overwriting the
deployed app files. That updates `qbittorrent.exe` and adds the required Qt runtime.
The launcher, AppInfo, Data, DefaultData and Other are left untouched.

Prefer the scripted deploy: `.\tools\install.ps1` performs the same extraction
for you (entry-by-entry, no manual dragging) into the target per-app folder --
by default the machine's PortableApps tree; point it elsewhere with
`-PortableAppsPerAppDir`.

**Remove everything again** (only after a successful build):

```pwsh
cd C:\repos\qBittorrent-Enhanced-Edition\tools
.\remove-build-deps.ps1            # prompts for confirmation
.\remove-build-deps.ps1 -NoPrompt  # no prompt
```

Deletes `C:\Qt`, `C:\vcpkg`, `C:\qbt-deps`, and `<repo>\build`, measuring and
reporting the freed space per component. Use `-KeepQt`, `-KeepVcpkg`, or
`-KeepQbtBuild` to retain any of them; `-RemoveAqt` additionally uninstalls
the `aqtinstall` helper via pip.

## License

Refer to the [COPYING] file.

[COPYING]: COPYING

## PGP Public Key

Starting from v3.3.4 all source tarballs and binaries are signed. \
The key currently used is 4096R/[5B7CC9A2](https://pgp.mit.edu/pks/lookup?op=get&search=0x6E4A2D025B7CC9A2) with fingerprint `D8F3DA77AAC6741053599C136E4A2D025B7CC9A2`. \
You can also [download it](https://github.com/qbittorrent/qBittorrent/raw/master/5B7CC9A2.asc). \
**PREVIOUSLY** the following key was used to sign the v3.3.4 source tarballs and v3.3.4 Windows installer **only**: 4096R/[520EC6F6](https://pgp.mit.edu/pks/lookup?op=get&search=0xA1ACCAE4520EC6F6) with fingerprint `F4A5FD201B117B1C2AB590E2A1ACCAE4520EC6F6`.

## Misc

For more information please visit:
<https://www.qbittorrent.org>

Check out our wiki at:
<https://wiki.qbittorrent.org>

Use the forum for troubleshooting before reporting bugs:
<https://forum.qbittorrent.org>

Please report any bug (or feature request) to:
<https://bugs.qbittorrent.org>

Official IRC channel:
[#qbittorrent on irc.libera.chat](ircs://irc.libera.chat:6697/qbittorrent)

-----------------------------------------------------

sledgehammer999 \<<sledgehammer999@qbittorrent.org>\>
