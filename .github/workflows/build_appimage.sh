#!/bin/bash -e

# This scrip is for building AppImage
# Please run this scrip in docker image: ubuntu:20.04
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build ubuntu:20.04 /build/.github/workflows/build_appimage.sh
# If you need keep store build cache in docker volume, just like:
#   $ docker volume create qbee-cache
#   $ docker run --rm -v `git rev-parse --show-toplevel`:/build -v qbee-cache:/var/cache/apt -v qbee-cache:/usr/src ubuntu:20.04 /build/.github/workflows/build_appimage.sh
# Artifacts will copy to the same directory.

set -o pipefail

# match qt version prefix. E.g 5 --> 5.15.2, 5.12 --> 5.12.10
export QT_VER_PREFIX="6"
export LIBTORRENT_BRANCH="RC_1_2"
export LC_ALL="C.UTF-8"
export DEBIAN_FRONTEND=noninteractive
export PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig
SELF_DIR="$(dirname "$(readlink -f "${0}")")"

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

# join array to string. E.g join_by ',' "${arr[@]}"
join_by() {
  local separator="$1"
  shift
  local first="$1"
  shift
  printf "%s" "$first" "${@/#/$separator}"
}

prepare_baseenv() {
  rm -f /etc/apt/sources.list.d/*.list*
  # Ubuntu mirror for local building
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    source /etc/os-release
    cat >/etc/apt/sources.list <<EOF
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
    export PIP_INDEX_URL="https://repo.huaweicloud.com/repository/pypi/simple"
  fi

  # keep debs in container for store cache in docker volume
  rm -f /etc/apt/apt.conf.d/*
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
  echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

  # Since cmake 3.23.0 CMAKE_INSTALL_LIBDIR will force set to lib/<multiarch-tuple> on Debian
  echo '/usr/local/lib/x86_64-linux-gnu' >/etc/ld.so.conf.d/x86_64-linux-gnu-local.conf
  echo '/usr/local/lib64' >/etc/ld.so.conf.d/lib64-local.conf

  retry apt update
  retry apt install -y software-properties-common apt-transport-https
  retry apt-add-repository -yn ppa:savoury1/backports

  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    sed -i 's@http://ppa.launchpad.net@https://launchpad.proxy.ustclug.org@' /etc/apt/sources.list.d/*.list
  fi

  retry apt update
  retry apt install -y \
    curl \
    git \
    unzip \
    pkg-config \
    libssl-dev \
    libzstd-dev \
    zlib1g-dev \
    libbrotli-dev \
    libxcb1-dev \
    libicu-dev \
    libgtk2.0-dev \
    build-essential \
    libgl1-mesa-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxext-dev \
    libxfixes-dev \
    libxi-dev \
    libxrender-dev \
    libxcb1-dev \
    libxcb-cursor-dev \
    libxcb-glx0-dev \
    libxcb-keysyms1-dev \
    libxcb-image0-dev \
    libxcb-shm0-dev \
    libxcb-icccm4-dev \
    libxcb-sync-dev \
    libxcb-xfixes0-dev \
    libxcb-shape0-dev \
    libxcb-randr0-dev \
    libxcb-render-util0-dev \
    libxcb-util-dev \
    libxcb-xinerama0-dev \
    libxcb-xkb-dev \
    libxkbcommon-dev \
    libxkbcommon-x11-dev \
    libwayland-dev \
    libwayland-egl-backend-dev

  apt autoremove --purge -y
  # strip all compiled files by default
  export CFLAGS='-s'
  export CXXFLAGS='-s'
  # Force refresh ld.so.cache
  ldconfig
}

prepare_buildenv() {
  # install cmake and ninja-build
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry curl -ksSL --compressed https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://ghproxy.com/${cmake_binary_url}"
      cmake_sha256_url="https://ghproxy.com/${cmake_sha256_url}"
    fi
    if [ -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd /usr/src
      cmake_sha256="$(retry curl -ksSL --compressed "${cmake_sha256_url}" \| grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz")"
      if ! echo "${cmake_sha256}" | sha256sum -c; then
        rm -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry curl -kLo "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry curl -ksSL --compressed https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://ghproxy.com/${ninja_binary_url}"
    fi
    if [ ! -f "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok" ]; then
      rm -f "/usr/src/ninja-${ninja_ver}-linux.zip"
      retry curl -kLC- -o "/usr/src/ninja-${ninja_ver}-linux.zip" "${ninja_binary_url}"
      touch "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok"
    fi
    unzip -d /usr/local/bin "/usr/src/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_ssl() {
  openssl_filename="$(retry curl -ksSL --compressed https://www.openssl.org/source/ \| grep -o "'href=\"openssl-3.*tar.gz\"'" \| grep -o "'[^\"]*.tar.gz'" \| head -1)"
  openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
  echo "openssl version: ${openssl_ver}"
  openssl_latest_url="https://github.com/openssl/openssl/archive/refs/tags/${openssl_filename}"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    openssl_latest_url="https://ghproxy.com/${openssl_latest_url}"
  fi
  mkdir -p "/usr/src/openssl-${openssl_ver}/"
  if [ ! -f "/usr/src/openssl-${openssl_ver}/.unpack_ok" ]; then
    retry curl -kSL "${openssl_latest_url}" \| tar zxf - -C "/usr/src/openssl-${openssl_ver}/" --strip-components 1
    touch "/usr/src/openssl-${openssl_ver}/.unpack_ok"
  fi
  cd "/usr/src/openssl-${openssl_ver}"
  ./Configure --openssldir=/etc/ssl
  make -j$(nproc)
  make install_sw
  ldconfig
}

prepare_qt() {
  # install qt
  qt_major_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  qt_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/${qt_major_ver}/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  echo "Using qt version: ${qt_ver}"
  mkdir -p "/usr/src/qtbase-${qt_ver}" \
    "/usr/src/qttools-${qt_ver}" \
    "/usr/src/qtsvg-${qt_ver}" \
    "/usr/src/qtwayland-${qt_ver}"
  if [ ! -f "/usr/src/qtbase-${qt_ver}/.unpack_ok" ]; then
    qtbase_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtbase-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qtbase_url}" \| tar Jxf - -C "/usr/src/qtbase-${qt_ver}" --strip-components 1
    touch "/usr/src/qtbase-${qt_ver}/.unpack_ok"
  fi
  cd "/usr/src/qtbase-${qt_ver}"
  rm -fr CMakeCache.txt CMakeFiles
  ./configure \
    -ltcg \
    -release \
    -c++std c++17 \
    -optimize-size \
    -openssl-linked \
    -no-icu \
    -no-directfb \
    -no-linuxfb \
    -no-eglfs \
    -no-feature-testlib \
    -no-feature-vnc \
    -feature-optimize_full \
    -nomake examples \
    -nomake tests
  cmake --build . --parallel
  cmake --install .
  export QT_BASE_DIR="$(ls -rd /usr/local/Qt-* | head -1)"
  export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:${LD_LIBRARY_PATH}"
  export PATH="${QT_BASE_DIR}/bin:${PATH}"
  if [ ! -f "/usr/src/qtsvg-${qt_ver}/.unpack_ok" ]; then
    qtsvg_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtsvg-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qtsvg_url}" \| tar Jxf - -C "/usr/src/qtsvg-${qt_ver}" --strip-components 1
    touch "/usr/src/qtsvg-${qt_ver}/.unpack_ok"
  fi
  cd "/usr/src/qtsvg-${qt_ver}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cmake --build . --parallel
  cmake --install .
  if [ ! -f "/usr/src/qttools-${qt_ver}/.unpack_ok" ]; then
    qttools_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qttools-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qttools_url}" \| tar Jxf - -C "/usr/src/qttools-${qt_ver}" --strip-components 1
    touch "/usr/src/qttools-${qt_ver}/.unpack_ok"
  fi
  cd "/usr/src/qttools-${qt_ver}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cat config.summary
  cmake --build . --parallel
  cmake --install .

  # Remove qt-wayland until next release: https://bugreports.qt.io/browse/QTBUG-104318
  # qt-wayland
  if [ ! -f "/usr/src/qtwayland-${qt_ver}/.unpack_ok" ]; then
    qtwayland_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtwayland-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qtwayland_url}" \| tar Jxf - -C "/usr/src/qtwayland-${qt_ver}" --strip-components 1
    touch "/usr/src/qtwayland-${qt_ver}/.unpack_ok"
  fi
  cd "/usr/src/qtwayland-${qt_ver}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cat config.summary
  cmake --build . --parallel
  cmake --install .

  # install qt6gtk2 for better look
  if [ ! -d "/usr/src/qt6gtk2/" ]; then
    qt6gtk2_git_url="https://github.com/trialuser02/qt6gtk2.git"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      qt6gtk2_git_url="https://ghproxy.com/${qt6gtk2_git_url}"
    fi
    retry git clone --depth 1 --recursive "${qt6gtk2_git_url}" "/usr/src/qt6gtk2/"
  fi
  cd "/usr/src/qt6gtk2/"
  git pull
  git clean -fdx
  qmake
  make -j$(nproc) install
}

preapare_libboost() {
  # build latest boost
  boost_ver="$(retry curl -ksSfL --compressed https://www.boost.org/users/download/ \| grep "'>Version\s*'" \| sed -r "'s/.*Version\s*([^<]+).*/\1/'" \| head -1)"
  echo "boost version ${boost_ver}"
  mkdir -p "/usr/src/boost-${boost_ver}"
  if [ ! -f "/usr/src/boost-${boost_ver}/.unpack_ok" ]; then
    boost_latest_url="https://sourceforge.net/projects/boost/files/boost/${boost_ver}/boost_${boost_ver//./_}.tar.bz2/download"
    retry curl -kSL "${boost_latest_url}" \| tar -jxf - -C "/usr/src/boost-${boost_ver}" --strip-components 1
    touch "/usr/src/boost-${boost_ver}/.unpack_ok"
  fi
  cd "/usr/src/boost-${boost_ver}"
  if [ ! -f ./b2 ]; then
    ./bootstrap.sh
  fi
  ./b2 -d0 -q install --with-system variant=release link=shared runtime-link=shared
  cd "/usr/src/boost-${boost_ver}/tools/build"
  if [ ! -f ./b2 ]; then
    ./bootstrap.sh
  fi
  ./b2 -d0 -q install variant=release link=shared runtime-link=shared
}

prepare_libtorrent() {
  # build libtorrent-rasterbar
  echo "libtorrent-rasterbar branch: ${LIBTORRENT_BRANCH}"
  libtorrent_git_url="https://github.com/arvidn/libtorrent.git"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    libtorrent_git_url="https://ghproxy.com/${libtorrent_git_url}"
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
  cmake \
    -B build \
    -G "Ninja" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17
  cmake --build build
  cmake --install build
  # force refresh ld.so.cache
  ldconfig
}

build_qbee() {
  # build qbittorrent
  cd "${SELF_DIR}/../../"
  rm -fr build/CMakeCache.txt
  cmake \
    -B build \
    -G "Ninja" \
    -DQT6=ON \
    -DCMAKE_PREFIX_PATH="${QT_BASE_DIR}/lib/cmake/" \
    -DCMAKE_BUILD_TYPE="Release" \
    -DCMAKE_CXX_STANDARD="17" \
    -DCMAKE_INSTALL_PREFIX="/tmp/qbee/AppDir/usr"
  cmake --build build
  rm -fr /tmp/qbee/
  cmake --install build
}

build_appimage() {
  # build AppImage
  linuxdeploy_qt_download_url="https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    linuxdeploy_qt_download_url="https://ghproxy.com/${linuxdeploy_qt_download_url}"
  fi
  [ -x "/tmp/linuxdeployqt-continuous-x86_64.AppImage" ] || retry curl -kSLC- -o /tmp/linuxdeployqt-continuous-x86_64.AppImage "${linuxdeploy_qt_download_url}"
  chmod -v +x '/tmp/linuxdeployqt-continuous-x86_64.AppImage'
  cd "/tmp/qbee"
  ln -svf usr/share/icons/hicolor/scalable/apps/qbittorrent.svg /tmp/qbee/AppDir/
  ln -svf qbittorrent.svg /tmp/qbee/AppDir/.DirIcon
  cat >/tmp/qbee/AppDir/AppRun <<EOF
#!/bin/bash -e

this_dir="\$(readlink -f "\$(dirname "\$0")")"
export XDG_DATA_DIRS="\${this_dir}/usr/share:\${XDG_DATA_DIRS}:/usr/share:/usr/local/share"
export QT_QPA_PLATFORMTHEMES=gtk2
export QT_STYLE_OVERRIDE=qt6gtk2

# Find the system certificates location
# https://gitlab.com/probono/platformissues/blob/master/README.md#certificates
possible_locations=(
  "/etc/ssl/certs/ca-certificates.crt"                # Debian/Ubuntu/Gentoo etc.
  "/etc/pki/tls/certs/ca-bundle.crt"                  # Fedora/RHEL
  "/etc/ssl/ca-bundle.pem"                            # OpenSUSE
  "/etc/pki/tls/cacert.pem"                           # OpenELEC
  "/etc/ssl/certs"                                    # SLES10/SLES11, https://golang.org/issue/12139
  "/usr/share/ca-certs/.prebuilt-store/"              # Clear Linux OS; https://github.com/knapsu/plex-media-player-appimage/issues/17#issuecomment-437710032
  "/system/etc/security/cacerts"                      # Android
  "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" # CentOS/RHEL 7
  "/etc/ssl/cert.pem"                                 # Alpine Linux
)

for location in "\${possible_locations[@]}"; do
  if [ -r "\${location}" ]; then
    export SSL_CERT_FILE="\${location}"
    break
  fi
done

exec "\${this_dir}/usr/bin/qbittorrent" "\$@"
EOF
  chmod 755 -v /tmp/qbee/AppDir/AppRun

  extra_plugins=(
    iconengines
    imageformats
    platforminputcontexts
    platforms
    platformthemes
    sqldrivers
    styles
    tls
    wayland-decoration-client
    wayland-graphics-integration-client
    wayland-shell-integration
  )
  exclude_libs=(
    libatk-1.0.so.0
    libatk-bridge-2.0.so.0
    libatspi.so.0
    libblkid.so.1
    libboost_filesystem.so.1.58.0
    libboost_system.so.1.58.0
    libboost_system.so.1.65.1
    libbsd.so.0
    libcairo-gobject.so.2
    libcairo.so.2
    libcapnp-0.5.3.so
    libcapnp-0.6.1.so
    libdatrie.so.1
    libdbus-1.so.3
    libepoxy.so.0
    libffi.so.6
    libgcrypt.so.20
    libgdk-3.so.0
    libgdk_pixbuf-2.0.so.0
    libgdk-x11-2.0.so.0
    libgio-2.0.so.0
    libglib-2.0.so.0
    libgmodule-2.0.so.0
    libgobject-2.0.so.0
    libgraphite2.so.3
    libgtk-3.so.0
    libgtk-x11-2.0.so.0
    libkj-0.5.3.so
    libkj-0.6.1.so
    libmirclient.so.9
    libmircommon.so.7
    libmircore.so.1
    libmirprotobuf.so.3
    libmount.so.1
    libpango-1.0.so.0
    libpangocairo-1.0.so.0
    libpangoft2-1.0.so.0
    libpixman-1.so.0
    libprotobuf-lite.so.9
    libselinux.so.1
    libsystemd.so.0
    libwayland-client.so.0
    libwayland-cursor.so.0
    libwayland-egl.so.1
    libwayland-server.so.0
    libX11-xcb.so.1
    libXau.so.6
    libxcb-cursor.so.0
    libxcb-glx.so.0
    libxcb-icccm.so.4
    libxcb-image.so.0
    libxcb-keysyms.so.1
    libxcb-randr.so.0
    libxcb-render.so.0
    libxcb-render-util.so.0
    libxcb-shape.so.0
    libxcb-shm.so.0
    libxcb-sync.so.1
    libxcb-util.so.1
    libxcb-xfixes.so.0
    libxcb-xkb.so.1
    libXcomposite.so.1
    libXcursor.so.1
    libXdamage.so.1
    libXdmcp.so.6
    libXext.so.6
    libXfixes.so.3
    libXinerama.so.1
    libXi.so.6
    libxkbcommon.so.0
    libxkbcommon-x11.so.0
    libXrandr.so.2
    libXrender.so.1
  )

  # fix AppImage output file name
  sed -i 's/Name=qBittorrent.*/Name=qBittorrent-Enhanced-Edition/;/SingleMainWindow/d' /tmp/qbee/AppDir/usr/share/applications/*.desktop

  APPIMAGE_EXTRACT_AND_RUN=1 \
    /tmp/linuxdeployqt-continuous-x86_64.AppImage \
    /tmp/qbee/AppDir/usr/share/applications/*.desktop \
    -always-overwrite \
    -appimage \
    -no-copy-copyright-files \
    -updateinformation="zsync|https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/qBittorrent-Enhanced-Edition-x86_64.AppImage.zsync" \
    -extra-plugins="$(join_by ',' "${extra_plugins[@]}")" \
    -exclude-libs="$(join_by ',' "${exclude_libs[@]}")"
}

move_artifacts() {
  # output file name should be qBittorrent-Enhanced-Edition-x86_64.AppImage
  cp -fv /tmp/qbee/qBittorrent-Enhanced-Edition*.AppImage* "${SELF_DIR}/"
}

prepare_baseenv
prepare_buildenv
# compile openssl 3.x. But fedora doesn't work
# prepare_ssl
prepare_qt
preapare_libboost
prepare_libtorrent
build_qbee
build_appimage
move_artifacts
