#!/bin/bash -e

# This script is for building AppImage
# Please run this script in docker image: ubuntu:20.04
# E.g: docker run --rm -v "$(git rev-parse --show-toplevel):/build" ubuntu:20.04 /build/.github/workflows/build_appimage.sh
# Downloaded source archives are cached in .github/workflows/downloads/ for reuse across targets.
# Artifacts will copy to the same directory.

set -o pipefail

# match qt version prefix. E.g 5 --> 5.15.2, 5.12 --> 5.12.10
export QT_VER_PREFIX="6"
export LIBTORRENT_BRANCH="RC_1_2"
export LC_ALL="C.UTF-8"
export DEBIAN_FRONTEND=noninteractive
export PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig
export ARCH="$(uname -m)"
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
    REPO_FILE=/etc/apt/sources.list
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
      REPO_FILE=/etc/apt/sources.list.d/ubuntu.sources
    fi
    sed -i \
      -e 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.nju.edu.cn/ubuntu/|g' \
      -e 's|http://security.ubuntu.com/ubuntu/|http://mirrors.nju.edu.cn/ubuntu/|g' \
      -e 's|http://ports.ubuntu.com/ubuntu-ports/|http://mirrors.nju.edu.cn/ubuntu-ports/|g' \
      "${REPO_FILE}"
    export PIP_INDEX_URL="https://mirrors.nju.edu.cn/pypi/web/simple"
  fi

  # keep debs in container for store cache in docker volume
  rm -f /etc/apt/apt.conf.d/*
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
  echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

  # Since cmake 3.23.0 CMAKE_INSTALL_LIBDIR will force set to lib/<multiarch-tuple> on Debian
  echo "/usr/local/lib/${ARCH}-linux-gnu" >/etc/ld.so.conf.d/${ARCH}-linux-gnu-local.conf
  echo '/usr/local/lib64' >/etc/ld.so.conf.d/lib64-local.conf

  retry apt update
  retry apt install -y \
    build-essential \
    curl \
    make \
    file \
    desktop-file-utils \
    git \
    libbrotli-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libgl1-mesa-dev \
    libgtk-3-dev \
    libicu-dev \
    libssl-dev \
    libwayland-dev \
    libwayland-egl-backend-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxcb1-dev \
    libxcb1-dev \
    libxcb-cursor-dev \
    libxcb-glx0-dev \
    libxcb-icccm4-dev \
    libxcb-image0-dev \
    libxcb-keysyms1-dev \
    libxcb-randr0-dev \
    libxcb-render-util0-dev \
    libxcb-shape0-dev \
    libxcb-shm0-dev \
    libxcb-sync-dev \
    libxcb-util-dev \
    libxcb-xfixes0-dev \
    libxcb-xinerama0-dev \
    libxcb-xkb-dev \
    libxext-dev \
    libxfixes-dev \
    libxi-dev \
    libxkbcommon-dev \
    libxkbcommon-x11-dev \
    libxrender-dev \
    libzstd-dev \
    pkg-config \
    bzip2 \
    unzip \
    xz-utils \
    zlib1g-dev \
    zsync

  apt autoremove --purge -y
  # strip all compiled files by default
  export LDFLAGS='-Wl,-s'
  # Force refresh ld.so.cache
  ldconfig
}

prepare_buildenv() {
  # install cmake and ninja-build
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry curl -ksSL --compressed https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-${ARCH}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://gh-proxy.org/${cmake_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-${ARCH}.tar.gz" ]; then
      retry curl -kLo "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-${ARCH}.tar.gz.part" "${cmake_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-${ARCH}.tar.gz.part" "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-${ARCH}.tar.gz"
    fi
    tar -zxf "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-${ARCH}.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry curl -ksSL --compressed https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_arch_suffix=""
    if [ "${ARCH}" != "x86_64" ]; then
      ninja_arch_suffix="-${ARCH}"
    fi
    ninja_local_name="ninja-${ninja_ver}-linux${ninja_arch_suffix}"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux${ninja_arch_suffix}.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://gh-proxy.org/${ninja_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux${ninja_arch_suffix}.zip" ]; then
      retry curl -kLC- -o "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux${ninja_arch_suffix}.zip.part" "${ninja_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux${ninja_arch_suffix}.zip.part" "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux${ninja_arch_suffix}.zip"
    fi
    unzip -d /usr/local/bin "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux${ninja_arch_suffix}.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_ssl() {
  openssl_filename="$(retry curl -ksSL --compressed https://openssl-library.org/source/ \| grep -o "'>openssl-3\(\.[0-9]*\)*tar.gz<'" \| grep -o "'[^>]*.tar.gz'" \| head -1)"
  openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
  echo "openssl version: ${openssl_ver}"
  openssl_latest_url="https://github.com/openssl/openssl/archive/refs/tags/${openssl_filename}"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    openssl_latest_url="https://gh-proxy.org/${openssl_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" ]; then
    retry curl -kSL "${openssl_latest_url}" -o "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part"
    mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz"
  fi
  mkdir -p "/usr/src/openssl-${openssl_ver}/"
  tar zxf "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" -C "/usr/src/openssl-${openssl_ver}/" --strip-components 1
  cd "/usr/src/openssl-${openssl_ver}"
  ./Configure no-apps no-tests --openssldir=/etc/ssl
  make -j$(nproc)
  make install_sw
  ldconfig
}

prepare_qt() {
  # install qt
  QT_DOWNLOAD_URL_BASE="https://download.qt.io"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      QT_DOWNLOAD_URL_BASE="https://mirrors.nju.edu.cn/qt"
  fi
  qt_major_ver="$(retry curl -ksSL --compressed "https://download.qt.io/official_releases/qt/" \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  qt_ver="$(retry curl -ksSL --compressed "https://download.qt.io/official_releases/qt/${qt_major_ver}/" \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  echo "Using qt version: ${qt_ver}"
  if [ ! -f "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz" ]; then
    qtbase_url="${QT_DOWNLOAD_URL_BASE}/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtbase-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qtbase_url}" -o "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz.part"
    mv -fv "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz.part" "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz"
  fi
  mkdir -p "/usr/src/qtbase-${qt_ver}"
  tar Jxf "${DOWNLOADS_DIR}/qtbase-everywhere-src-${qt_ver}.tar.xz" -C "/usr/src/qtbase-${qt_ver}" --strip-components 1
  cd "/usr/src/qtbase-${qt_ver}"
  rm -fr CMakeCache.txt CMakeFiles
  ./configure \
    -ltcg \
    -release \
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
  echo "========================================================"
  echo "Qt configuration:"
  cat config.summary
  cmake --build . --parallel
  cmake --install .
  export QT_BASE_DIR="$(ls -rd /usr/local/Qt-* | head -1)"
  export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:${LD_LIBRARY_PATH}"
  export PATH="${QT_BASE_DIR}/bin:${PATH}"
  if [ ! -f "${DOWNLOADS_DIR}/qtsvg-everywhere-src-${qt_ver}.tar.xz" ]; then
    qtsvg_url="${QT_DOWNLOAD_URL_BASE}/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtsvg-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qtsvg_url}" -o "${DOWNLOADS_DIR}/qtsvg-everywhere-src-${qt_ver}.tar.xz.part"
    mv -fv "${DOWNLOADS_DIR}/qtsvg-everywhere-src-${qt_ver}.tar.xz.part" "${DOWNLOADS_DIR}/qtsvg-everywhere-src-${qt_ver}.tar.xz"
  fi
  mkdir -p "/usr/src/qtsvg-${qt_ver}"
  tar Jxf "${DOWNLOADS_DIR}/qtsvg-everywhere-src-${qt_ver}.tar.xz" -C "/usr/src/qtsvg-${qt_ver}" --strip-components 1
  cd "/usr/src/qtsvg-${qt_ver}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cmake --build . --parallel
  cmake --install .
  if [ ! -f "${DOWNLOADS_DIR}/qttools-everywhere-src-${qt_ver}.tar.xz" ]; then
    qttools_url="${QT_DOWNLOAD_URL_BASE}/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qttools-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qttools_url}" -o "${DOWNLOADS_DIR}/qttools-everywhere-src-${qt_ver}.tar.xz.part"
    mv -fv "${DOWNLOADS_DIR}/qttools-everywhere-src-${qt_ver}.tar.xz.part" "${DOWNLOADS_DIR}/qttools-everywhere-src-${qt_ver}.tar.xz"
  fi
  mkdir -p "/usr/src/qttools-${qt_ver}"
  tar Jxf "${DOWNLOADS_DIR}/qttools-everywhere-src-${qt_ver}.tar.xz" -C "/usr/src/qttools-${qt_ver}" --strip-components 1
  cd "/usr/src/qttools-${qt_ver}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cat config.summary
  cmake --build . --parallel
  cmake --install .

  # qt-wayland
  if [ ! -f "${DOWNLOADS_DIR}/qtwayland-everywhere-src-${qt_ver}.tar.xz" ]; then
    qtwayland_url="${QT_DOWNLOAD_URL_BASE}/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtwayland-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kSL --compressed "${qtwayland_url}" -o "${DOWNLOADS_DIR}/qtwayland-everywhere-src-${qt_ver}.tar.xz.part"
    mv -fv "${DOWNLOADS_DIR}/qtwayland-everywhere-src-${qt_ver}.tar.xz.part" "${DOWNLOADS_DIR}/qtwayland-everywhere-src-${qt_ver}.tar.xz"
  fi
  mkdir -p "/usr/src/qtwayland-${qt_ver}"
  tar Jxf "${DOWNLOADS_DIR}/qtwayland-everywhere-src-${qt_ver}.tar.xz" -C "/usr/src/qtwayland-${qt_ver}" --strip-components 1
  cd "/usr/src/qtwayland-${qt_ver}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cat config.summary
  cmake --build . --parallel
  cmake --install .
}

preapare_libboost() {
  # Boost >= 1.69: boost::system is header-only.
  # libtorrent only links Boost::headers (see CMakeLists.txt).
  boost_ver="1.86.0"
  echo "boost version ${boost_ver}"
  if [ ! -f "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2" ]; then
    boost_latest_url="https://sourceforge.net/projects/boost/files/boost/${boost_ver}/boost_${boost_ver//./_}.tar.bz2/download"
    retry curl -kSL "${boost_latest_url}" -o "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2.part"
    mv -fv "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2.part" "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2"
  fi
  mkdir -p "/usr/src/boost-${boost_ver}"
  tar -jxf "${DOWNLOADS_DIR}/boost-${boost_ver}.tar.bz2" --strip-components=1 -C "/usr/src/boost-${boost_ver}"
  cp -rf "/usr/src/boost-${boost_ver}/boost" /usr/local/include/
}

prepare_libtorrent() {
  # build libtorrent-rasterbar
  echo "libtorrent-rasterbar branch: ${LIBTORRENT_BRANCH}"
  libtorrent_git_url="https://github.com/arvidn/libtorrent.git"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    libtorrent_git_url="https://gh-proxy.org/${libtorrent_git_url}"
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
    -DCMAKE_BUILD_TYPE=Release
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
    -DCMAKE_PREFIX_PATH="${QT_BASE_DIR}/lib/cmake/" \
    -DCMAKE_BUILD_TYPE="Release" \
    -DCMAKE_INSTALL_PREFIX="/tmp/qbee/AppDir/usr"
  cmake --build build
  rm -fr /tmp/qbee/
  cmake --install build
}

build_appimage() {
  # build AppImage
  linuxdeploy_tool_urls=(
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage"
    "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${ARCH}.AppImage"
    "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-${ARCH}.AppImage"
    # fetched into memory by the appimagetool bundled in linuxdeploy-plugin-appimage on every run;
    # passed to it via LDAI_RUNTIME_FILE below to skip the download
    "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-${ARCH}"
  )
  for tool_url in "${linuxdeploy_tool_urls[@]}"; do
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      tool_url="https://gh-proxy.org/${tool_url}"
    fi
    tool_file="${DOWNLOADS_DIR}/$(basename "${tool_url}")"
    if [ ! -s "${tool_file}" ]; then
      retry curl -kSLC- -o "${tool_file}.part" "${tool_url}"
      mv -fv "${tool_file}.part" "${tool_file}"
    fi
    chmod -v +x "${tool_file}"
  done
  cd "/tmp/qbee"
  ln -svf usr/share/icons/hicolor/scalable/apps/qbittorrent.svg /tmp/qbee/AppDir/
  ln -svf qbittorrent.svg /tmp/qbee/AppDir/.DirIcon
  cat >/tmp/qbee/AppDir/AppRun <<EOF
#!/bin/bash -e

this_dir="\$(readlink -f "\$(dirname "\$0")")"
export XDG_DATA_DIRS="\${this_dir}/usr/share:\${XDG_DATA_DIRS}:/usr/share:/usr/local/share"
export QT_QPA_PLATFORMTHEME=gtk3
unset QT_STYLE_OVERRIDE

# Force set openssl config directory to an invalid directory to fallback to use default openssl config.
# This can avoid some distributions (mainly Fedora) having some strange patches or configurations
# for openssl that make the libssl in Appimage bundle unavailable.
export OPENSSL_CONF="\${this_dir}"

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

  exclude_libs=(
    # host desktop/system stacks: never bundle, resolve from the system at runtime.
    # entries are basename globs (fnmatch) applied by linuxdeploy util::isInExcludelist,
    # also honored for missing-dependency errors during ldd closure scanning.
    # quoted: array is defined while cwd=/tmp/qbee, bare globs would pathname-expand
    'libatk-*.so*' 'libatspi.so*'
    'libgtk*.so*' 'libgdk*.so*'
    'libpango*.so*' 'libcairo*.so*' 'libpixman-1.so.*' 'libgraphite2.so.*' 'libdatrie.so.*' 'libthai.so.*'
    'libglib*.so*' 'libgio*.so*' 'libgobject*.so*' 'libgmodule*.so*'
    'libX*.so*' 'libxcb*.so*' 'libxkbcommon*.so*'
    'libwayland-*.so*'
    'libdbus-1.so.*' 'libepoxy.so.*'
    'libbsd.so.*' 'libmd.so.*' 'libffi.so.*' 'libcap.so.*'
    'libblkid.so.*' 'libmount.so.*' 'libselinux.so.*'
    'libsystemd.so.*' 'libgcrypt.so.*' 'liblz4.so.*' 'liblzma.so.*'
    'libpcre.so.*' 'libpcre2-8.so.*'
    # fossils from old build hosts (ubuntu 16.04 boost / mir / capnp), kept as safety net
    'libboost_*.so*' 'libmir*.so*' 'libcapnp-*.so*' 'libkj-*.so*' 'libprotobuf-lite.so.*'
  )

  # fix AppImage output file name, maybe not needed anymore since appimagetool lets you set output file name?
  sed -i 's/Name=qBittorrent.*/Name=qBittorrent-Enhanced-Edition/;/SingleMainWindow/d' /tmp/qbee/AppDir/usr/share/applications/*.desktop

  export APPIMAGE_EXTRACT_AND_RUN=1

  # package as AppImage, embed update information and generate the .zsync file
  LDAI_UPDATE_INFORMATION="zsync|https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/qBittorrent-Enhanced-Edition-${ARCH}.AppImage.zsync" \
  LDAI_RUNTIME_FILE="${DOWNLOADS_DIR}/runtime-${ARCH}" \
  LDAI_OUTPUT="/tmp/qbee/qBittorrent-Enhanced-Edition-${ARCH}.AppImage" \
  LDAI_NO_APPSTREAM=1 \
  LINUXDEPLOY_EXCLUDED_LIBRARIES="$(join_by ';' "${exclude_libs[@]}")" \
  EXTRA_QT_MODULES="svg;waylandcompositor" \
  DEPLOY_PLATFORM_THEMES=1 \
  EXTRA_PLATFORM_PLUGINS="libqwayland.so" \
  DISABLE_COPYRIGHT_FILES_DEPLOYMENT=1 \
  "${DOWNLOADS_DIR}/linuxdeploy-${ARCH}.AppImage" \
    --appdir=/tmp/qbee/AppDir \
    --plugin qt \
    --output appimage
}

move_artifacts() {
  # output file name should be qBittorrent-Enhanced-Edition-x86_64.AppImage
  cp -fv /tmp/qbee/qBittorrent-Enhanced-Edition*.AppImage* "${SELF_DIR}/"
}

prepare_baseenv
prepare_buildenv
# compile openssl 3.x. qBittorrent >= 5.0 required openssl 3.x
prepare_ssl
prepare_qt
preapare_libboost
prepare_libtorrent
build_qbee
build_appimage
move_artifacts
