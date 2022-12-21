#pragma once

#include <libtorrent/version.hpp>

#if (LIBTORRENT_VERSION_NUM < 20000)
namespace libtorrent {
using client_data_t = void*;
}
#endif
