#!/bin/bash -e

# This script is for static cross compiling
# Please run this script in docker image: abcfy2/musl-cross-toolchain-ubuntu:${CROSS_HOST}
# E.g: docker run --rm -v "$(git rev-parse --show-toplevel):/build" abcfy2/musl-cross-toolchain-ubuntu:arm-unknown-linux-musleabi /build/.github/workflows/cross_build.sh
# Downloaded source archives are cached in .github/workflows/downloads/ for reuse across targets.
# Artifacts will copy to the same directory.

set -o pipefail

# match qt version prefix. E.g 5 --> 5.15.2, 5.12 --> 5.12.10
export QT_VER_PREFIX="6"
export LIBTORRENT_BRANCH="RC_1_2"

# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  source /etc/os-release
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://repo.huaweicloud.com/ubuntu/
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports ${UBUNTU_CODENAME}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  else
    cat >/etc/apt/sources.list <<EOF
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
  fi
  export PIP_INDEX_URL="https://repo.huaweicloud.com/repository/pypi/simple"
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt update
apt install -y \
  jq \
  curl \
  git \
  make \
  g++ \
  unzip \
  zip \
  pkg-config \
  pipx \
  python3-pip \
  libglib2.0-0t64

# use zlib-ng instead of zlib by default
USE_ZLIB_NG=${USE_ZLIB_NG:-1}

# OPENSSL_COMPILER value is from openssl source: ./Configure LIST
case "${CROSS_HOST}" in
arm*linux*)
  export OPENSSL_COMPILER=linux-armv4
  ;;
aarch64*linux*)
  export OPENSSL_COMPILER=linux-aarch64
  ;;
mips64el*linux* | mips64*linux*)
  export OPENSSL_COMPILER=linux64-mips64
  ;;
mipsel*linux* | mips*linux*)
  export OPENSSL_COMPILER=linux-mips32
  ;;
loongarch64*linux*)
  export OPENSSL_COMPILER=linux64-loongarch64
  ;;
x86_64*linux*)
  export OPENSSL_COMPILER=linux-x86_64
  ;;
x86_64*mingw*)
  export OPENSSL_COMPILER=mingw64
  ;;
i686*mingw*)
  export OPENSSL_COMPILER=mingw
  ;;
*)
  export OPENSSL_COMPILER=cc
  ;;
esac

# strip all compiled files by default
export LDFLAGS='-Wl,-s'

TARGET_ARCH="${CROSS_HOST%%-*}"
case "${CROSS_HOST}" in
*"mingw"*)
  TARGET_HOST=Windows
  apt install -y wine
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
*)
  TARGET_HOST=Linux
  apt install -y "qemu-user" --no-install-recommends --no-install-suggests
  case "${TARGET_ARCH}" in
  i686)
    RUNNER_CHECKER="qemu-i386"
    ;;
  arm*)
    RUNNER_CHECKER="qemu-arm"
    ;;
  *)
    RUNNER_CHECKER="qemu-${TARGET_ARCH}"
    ;;
  esac
  ;;
esac

export PKG_CONFIG_PATH="${CROSS_PREFIX}/opt/qt/lib/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${CROSS_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH}"

SELF_DIR="$(dirname "$(readlink -f "${0}")")"
mkdir -p "${SELF_DIR}/downloads"
export DOWNLOADS_DIR="${SELF_DIR}/downloads"

retry() {
  # max retry 5 times
  try=5
  # sleep 1 min every retry
  sleep_time=60
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

# This function is used to check version less than or equal to another version
verlte() {
  printf '%s\n' "$1" "$2" | sort -C -V
}

prepare_cmake() {
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry curl -ksSL --compressed https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://gh-proxy.com/${cmake_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry curl -kLo "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz.part" "${cmake_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz.part" "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    fi
    tar -zxf "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
}

prepare_ninja() {
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry curl -ksSL --compressed https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://gh-proxy.com/${ninja_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip" ]; then
      retry curl -kLC- -o "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${ninja_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
    fi
    unzip -d /usr/local/bin "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_zlib() {
  if [ x"${USE_ZLIB_NG}" = x"1" ]; then
    zlib_ng_latest_tag="$(retry curl -ksSL --compressed https://api.github.com/repos/zlib-ng/zlib-ng/releases \| jq -r "'.[0].tag_name'")"
    zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${zlib_ng_latest_tag}.tar.gz"
    echo "zlib-ng version ${zlib_ng_latest_tag}"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      zlib_ng_latest_url="https://gh-proxy.com/${zlib_ng_latest_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" ]; then
      retry curl -ksSL "${zlib_ng_latest_url}" -o "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part"
      mv -fv "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-ng-${zlib_ng_latest_tag}/"
    tar -zxf "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-ng-${zlib_ng_latest_tag}/"
    cd "/usr/src/zlib-ng-${zlib_ng_latest_tag}/"
    rm -f build/CMakeCache.txt
    cmake -B build \
      -G Ninja \
      -DBUILD_SHARED_LIBS=OFF \
      -DZLIB_COMPAT=ON \
      -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
      -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
      -DCMAKE_C_COMPILER="${CROSS_HOST}-cc" \
      -DCMAKE_CXX_COMPILER="${CROSS_HOST}-c++" \
      -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DWITH_GTEST=OFF
    cmake --build build
    cmake --install build
    # Fix mingw build sharedlibdir lost issue
    sed -i 's@^sharedlibdir=.*@sharedlibdir=${libdir}@' "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc"
  else
    zlib_ver="$(retry curl -ksSL --compressed https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
    echo "zlib version ${zlib_ver}"
    if [ ! -f "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.xz" ]; then
      zlib_latest_url="https://sourceforge.net/projects/libpng/files/zlib/${zlib_ver}/zlib-${zlib_ver}.tar.xz/download"
      retry curl -kL "${zlib_latest_url}" -o "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.xz.part"
      mv -fv "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.xz.part" "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.xz"
    fi
    mkdir -p "/usr/src/zlib-${zlib_ver}"
    tar -Jxf "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.xz" --strip-components=1 -C "/usr/src/zlib-${zlib_ver}"
    cd "/usr/src/zlib-${zlib_ver}"

    if [ x"${TARGET_HOST}" = x"Windows" ]; then
      make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
    else
      CHOST="${CROSS_HOST}" CFLAGS="-fPIC" ./configure --prefix="${CROSS_PREFIX}" --static
      make -j$(nproc)
      make install
    fi
  fi
}

prepare_ssl() {
  openssl_filename="$(retry curl -ksSL --compressed https://openssl-library.org/source/ \| grep -o "'>openssl-3\(\.[0-9]*\)*tar.gz<'" \| grep -o "'[^>]*.tar.gz'" \| sort -nr \| head -1)"
  openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
  echo "OpenSSL version ${openssl_ver}"
  if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" ]; then
    openssl_download_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/${openssl_filename}"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      openssl_download_url="https://gh-proxy.com/${openssl_download_url}"
    fi
    retry curl -kL "${openssl_download_url}" -o "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part"
    mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz"
  fi
  mkdir -p "/usr/src/openssl-${openssl_ver}/"
  tar -zxf "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" --strip-components=1 -C "/usr/src/openssl-${openssl_ver}/"
  cd "/usr/src/openssl-${openssl_ver}/"
  CC=cc ./Configure -static no-tests -fPIC --openssldir=/etc/ssl --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" "${OPENSSL_COMPILER}"
  make -j$(nproc)
  make install_sw
  if [ -f "${CROSS_PREFIX}/lib64/libssl.a" ]; then
    cp -rfv "${CROSS_PREFIX}"/lib64/. "${CROSS_PREFIX}/lib"
  fi
  if [ -f "${CROSS_PREFIX}/lib32/libssl.a" ]; then
    cp -rfv "${CROSS_PREFIX}"/lib32/. "${CROSS_PREFIX}/lib"
  fi
}

prepare_boost() {
  # Boost >= 1.69: boost::system is header-only.
  # libtorrent only links Boost::headers (see CMakeLists.txt).
  boost_ver="1.86.0"
  echo "Boost version ${boost_ver}"
  if [ ! -f "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2" ]; then
    boost_latest_url="https://sourceforge.net/projects/boost/files/boost/${boost_ver}/boost_${boost_ver//./_}.tar.bz2/download"
    retry curl -kL "${boost_latest_url}" -o "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2.part"
    mv -fv "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2.part" "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2"
  fi
  mkdir -p "/usr/src/boost-${boost_ver}/"
  tar -jxf "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2" --strip-components=1 -C "/usr/src/boost-${boost_ver}/"
  cp -rf "/usr/src/boost-${boost_ver}/boost" "${CROSS_PREFIX}/include/"
}

prepare_qt() {
  QT_DOWNLOAD_URL_BASE="https://download.qt.io"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    QT_DOWNLOAD_URL_BASE="https://mirrors.sjtug.sjtu.edu.cn/qt"
  fi
  qt_major_ver="$(retry curl -ksSL --compressed "https://download.qt.io/official_releases/qt/" \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  qt_ver="$(retry curl -ksSL --compressed "https://download.qt.io/official_releases/qt/${qt_major_ver}/" \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  echo "Using qt version: ${qt_ver}"
  if [ ! -f "${DOWNLOADS_DIR}/qt-host/${qt_ver}/gcc_64/bin/qt.conf" ]; then
    pipx install aqtinstall
    qt_archives=(qtbase qttools icu)
    if verlte "6.11.0" "${qt_ver}"; then
      qt_archives+=(qtdeclarative)
    fi
    aqt_base_args=(-O "${DOWNLOADS_DIR}/qt-host")
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      aqt_base_args+=(-b "${QT_DOWNLOAD_URL_BASE}")
    fi
    aqt_base_args+=(linux desktop "${qt_ver}" --archives "${qt_archives[@]}")
    retry "${HOME}/.local/bin/aqt" install-qt "${aqt_base_args[@]}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz" ]; then
    qtbase_url="${QT_DOWNLOAD_URL_BASE}/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtbase-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kL "${qtbase_url}" -o "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz.part"
    mv -fv "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz.part" "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz"
  fi
  mkdir -p "/usr/src/qtbase-${qt_ver}"
  tar Jxf "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz" -C "/usr/src/qtbase-${qt_ver}" --strip-components 1
  cd "/usr/src/qtbase-${qt_ver}"
  rm -fr CMakeCache.txt CMakeFiles
  if [ x"${TARGET_HOST}" = x"Windows" ]; then
    QT_BASE_EXTRA_CONF='-xplatform win32-g++'
  fi

  ./configure \
    -prefix "${CROSS_PREFIX}/opt/qt/" \
    -qt-host-path "${DOWNLOADS_DIR}/qt-host/${qt_ver}/gcc_64/" \
    -release \
    -static \
    -c++std c++17 \
    -optimize-size \
    -openssl \
    -openssl-linked \
    -no-gui \
    -no-dbus \
    -no-widgets \
    -no-feature-testlib \
    -no-feature-animation \
    -feature-optimize_full \
    -nomake examples \
    -nomake tests \
    ${QT_BASE_EXTRA_CONF} \
    -device-option "CROSS_COMPILE=${CROSS_HOST}-" \
    -- \
    -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
    -DCMAKE_C_COMPILER="${CROSS_HOST}-cc" \
    -DCMAKE_PREFIX_PATH="${CROSS_PREFIX}" \
    -DOPENSSL_ROOT_DIR="${CROSS_PREFIX}" \
    -DCMAKE_CXX_COMPILER="${CROSS_HOST}-c++"
  echo "========================================================"
  echo "Qt configuration:"
  cat config.summary
  cmake --build . --parallel
  cmake --install .
  export QT_BASE_DIR="${CROSS_PREFIX}/opt/qt"
  export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:${LD_LIBRARY_PATH}"
  export PATH="${QT_BASE_DIR}/bin:${PATH}"
}

prepare_libtorrent() {
  echo "libtorrent-rasterbar branch: ${LIBTORRENT_BRANCH}"
  libtorrent_git_url="https://github.com/arvidn/libtorrent.git"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    libtorrent_git_url="https://gh-proxy.com/${libtorrent_git_url}"
  fi
  if [ ! -d "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/" ]; then
    retry git clone --depth 1 --recursive --shallow-submodules --branch "${LIBTORRENT_BRANCH}" \
      "${libtorrent_git_url}" \
      "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
  fi
  cd "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
  if ! git pull; then
    # if pull failed, retry clone the repository.
    cd /
    rm -fr "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
    retry git clone --depth 1 --recursive --shallow-submodules --branch "${LIBTORRENT_BRANCH}" \
      "${libtorrent_git_url}" \
      "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
    cd "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
  fi
  rm -fr build/CMakeCache.txt
  # TODO: solve mingw build
  if [ x"${TARGET_HOST}" = x"Windows" ]; then
    find -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -print0 |
      xargs -0 -r sed -i 's/Windows\.h/windows.h/g;
                          s/Shellapi\.h/shellapi.h/g;
                          s/Shlobj\.h/shlobj.h/g;
                          s/Ntsecapi\.h/ntsecapi.h/g;
                          s/#include\s*<condition_variable>/#include "mingw.condition_variable.h"/g;
                          s/#include\s*<future>/#include "mingw.future.h"/g;
                          s/#include\s*<invoke>/#include "mingw.invoke.h"/g;
                          s/#include\s*<mutex>/#include "mingw.mutex.h"/g;
                          s/#include\s*<shared_mutex>/#include "mingw.shared_mutex.h"/g;
                          s/#include\s*<thread>/#include "mingw.thread.h"/g'
  fi
  cmake \
    -B build \
    -G "Ninja" \
    -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -Dstatic_runtime=on \
    -DBUILD_SHARED_LIBS=off \
    -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
    -DCMAKE_PREFIX_PATH="${CROSS_PREFIX}" \
    -DCMAKE_C_COMPILER="${CROSS_HOST}-cc" \
    -DCMAKE_CXX_COMPILER="${CROSS_HOST}-c++"
  cmake --build build
  cmake --install build
}

build_qbittorrent() {
  cd "${SELF_DIR}/../../"
  rm -fr build/CMakeCache.txt
  cmake \
    -B build \
    -G "Ninja" \
    -DGUI=off \
    -DQT_HOST_PATH="${DOWNLOADS_DIR}/qt-host/${qt_ver}/gcc_64/" \
    -DSTACKTRACE=off \
    -DBUILD_SHARED_LIBS=off \
    -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
    -DCMAKE_PREFIX_PATH="${QT_BASE_DIR}/lib/cmake/" \
    -DCMAKE_BUILD_TYPE="Release" \
    -DCMAKE_CXX_STANDARD="17" \
    -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
    -DCMAKE_CXX_COMPILER="${CROSS_HOST}-c++" \
    -DCMAKE_EXE_LINKER_FLAGS="-static -s"
  cmake --build build
  cmake --install build
  if [ x"${TARGET_HOST}" = x"Windows" ]; then
    cp -fv "src/release/qbittorrent-nox.exe" /tmp/
  else
    cp -fv "${CROSS_PREFIX}/bin/qbittorrent-nox" /tmp/
  fi
}

prepare_cmake
prepare_ninja
prepare_zlib
prepare_ssl
prepare_boost
prepare_qt
prepare_libtorrent
build_qbittorrent

# check
"${RUNNER_CHECKER}" /tmp/qbittorrent-nox* --version 2>/dev/null

# archive qbittorrent
zip -j9v "${SELF_DIR}/qbittorrent-enhanced-nox_${CROSS_HOST//-unknown/}_static.zip" /tmp/qbittorrent-nox*
