#!/bin/bash -e
# This scrip is for building AppImage
# Please run this scrip in docker image: ubuntu:16.04
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build ubuntu:16.04 /build/.github/workflows/build_appimage.sh
# Artifacts will copy to the same directory.

# Ubuntu mirror for local building
# source /etc/os-release
# cat >/etc/apt/sources.list <<EOF
# deb http://opentuna.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
# deb http://opentuna.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
# deb http://opentuna.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
# deb http://opentuna.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
# EOF
# export PIP_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"

apt update
apt install -y software-properties-common
apt-add-repository -y ppa:savoury1/backports
apt-add-repository -y ppa:savoury1/gcc-defaults-9
apt update
apt install -y --no-install-suggests --no-install-recommends \
  git \
  curl \
  gcc \
  g++ \
  make \
  autoconf \
  automake \
  pkg-config \
  file \
  zlib1g-dev \
  libssl-dev \
  libtool \
  python3-semantic-version \
  python3-lxml \
  python3-requests \
  python3-pip \
  python3-stdeb \
  libfontconfig1 \
  libgl1-mesa-dev \
  libxcb-icccm4 \
  libxcb-image0 \
  libxcb-keysyms1 \
  libxcb-render-util0 \
  libxcb-xinerama0 \
  libxcb-xkb1 \
  libxkbcommon-x11-0 \
  libpq5 \
  libxcb-randr0 \
  libxcb-shape0 \
  libodbc1 \
  libxcb-xfixes0 \
  libegl1-mesa

# Force refresh ld.so.cache
ldconfig
SELF_DIR="$(dirname "$(readlink -f "${0}")")"
export PYTHONWARNINGS=ignore:DEPRECATION

# install qt
if [ ! -d "${HOME}/Qt" ]; then
  pip3 install --upgrade 'pip<21' 'setuptools<51' 'setuptools_scm<6'
  pip3 install py7zr
  curl -sSkL --compressed https://cdn.jsdelivr.net/gh/engnr/qt-downloader@master/qt-downloader | python3 - linux desktop 5.15.2 gcc_64 -o "${HOME}/Qt" -m qtbase qttools qtsvg icu
fi
export QT_BASE_DIR="$(ls -rd "${HOME}/Qt"/*/gcc_64 | head -1)"
export QTDIR=$QT_BASE_DIR
export PATH=$QT_BASE_DIR/bin:$PATH
export LD_LIBRARY_PATH=$QT_BASE_DIR/lib:$LD_LIBRARY_PATH
export PKG_CONFIG_PATH=$QT_BASE_DIR/lib/pkgconfig:$PKG_CONFIG_PATH
export QT_QMAKE="${QT_BASE_DIR}/bin"
sed -i.bak 's/Enterprise/OpenSource/g;s/licheck.*//g' "${QT_BASE_DIR}/mkspecs/qconfig.pri"

# build latest boost
mkdir -p /usr/src/boost
if [ ! -f /usr/src/boost/.unpack_ok ]; then
  boost_latest_url="$(curl -ksSfL https://www.boost.org/users/download/ | grep -o 'http[^"]*.tar.bz2' | head -1)"
  curl -ksSfL "${boost_latest_url}" | tar -jxf - -C /usr/src/boost --strip-components 1
fi
touch "/usr/src/boost/.unpack_ok"
cd /usr/src/boost
./bootstrap.sh
./b2 install --with-system variant=release
cd /usr/src/boost/tools/build
./bootstrap.sh
./b2 install

# build libtorrent-rasterbar
if [ ! -d /usr/src/libtorrent-rasterbar/ ]; then
  git clone --depth 1 --recursive --shallow-submodules --branch RC_2_0 \
    https://github.com/arvidn/libtorrent.git \
    /usr/src/libtorrent-rasterbar/
fi
cd "/usr/src/libtorrent-rasterbar/"
b2 install crypto=openssl cxxstd=17 release
# force refresh ld.so.cache
ldconfig

# build qbittorrent
cd "${SELF_DIR}/../../"
./configure --prefix=/tmp/qbee/AppDir/usr --with-boost="/usr/local" --with-boost-libdir="/usr/local/lib" CXXFLAGS="-std=c++17" CPPFLAGS="-std=c++17" || (cat config.log && exit 1)
make install -j$(nproc)

# build AppImage
[ -x "/tmp/linuxdeploy-x86_64.AppImage" ] || curl -LC- -o /tmp/linuxdeploy-x86_64.AppImage "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
[ -x "/tmp/linuxdeploy-plugin-qt-x86_64.AppImage" ] || curl -LC- -o /tmp/linuxdeploy-plugin-qt-x86_64.AppImage "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"
chmod -v +x '/tmp/linuxdeploy-plugin-qt-x86_64.AppImage' '/tmp/linuxdeploy-x86_64.AppImage'
# Fix run in docker, see: https://github.com/linuxdeploy/linuxdeploy/issues/86
# and https://github.com/linuxdeploy/linuxdeploy/issues/154#issuecomment-741936850
dd if=/dev/zero of=/tmp/linuxdeploy-plugin-qt-x86_64.AppImage conv=notrunc bs=1 count=3 seek=8
dd if=/dev/zero of=/tmp/linuxdeploy-x86_64.AppImage conv=notrunc bs=1 count=3 seek=8
cd "/tmp/qbee"
mkdir -p "/tmp/qbee/AppDir/apprun-hooks/"
echo 'export XDG_DATA_DIRS="${APPDIR:-"$(dirname "${BASH_SOURCE[0]}")/.."}/usr/share:${XDG_DATA_DIRS}:/usr/share:/usr/local/share"' >"/tmp/qbee/AppDir/apprun-hooks/xdg_data_dirs.sh"
APPIMAGE_EXTRACT_AND_RUN=1 \
  OUTPUT='qBittorrent-Enhanced-Edition.AppImage' \
  UPDATE_INFORMATION="zsync|https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/qBittorrent-Enhanced-Edition.AppImage.zsync" \
  /tmp/linuxdeploy-x86_64.AppImage --appdir="/tmp/qbee/AppDir" --output=appimage --plugin qt

cp -fv /tmp/qbee/qBittorrent-Enhanced-Edition.AppImage /tmp/qbee/qBittorrent-Enhanced-Edition.AppImage.zsync "${SELF_DIR}"
