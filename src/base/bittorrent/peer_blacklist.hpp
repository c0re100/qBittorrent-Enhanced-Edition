#pragma once

#include <regex>

#include <libtorrent/torrent_info.hpp>

#include <QCoreApplication>
#include <QHostAddress>
#include <QStringList>

#include "base/logger.h"
#include "base/net/geoipmanager.h"

#include "peer_filter_plugin.hpp"

#if !defined(NDEBUG)
// Ascertaining a call stack is only useful (and cheap enough to be free) in
// debug builds, where it is written to the log as raw return addresses. Resolve
// them against the matching PDB with a symbolizer (cdb, or a DIA-based tool)
// when reproducing a problem. Release builds compile this out entirely.
#  if defined(Q_OS_WIN)
#    include <windows.h> // ::CaptureStackBackTrace
#  elif defined(Q_OS_UNIX)
#    include <execinfo.h> // ::backtrace
#  endif

inline QString callStackToString()
{
    constexpr int maxFrames = 32;
    void *frames[maxFrames] = {};
    int firstFrame = 0;
    int count = 0;
#  if defined(Q_OS_WIN)
    count = ::CaptureStackBackTrace(1, maxFrames, frames, nullptr);
#  elif defined(Q_OS_UNIX)
    count = ::backtrace(frames, maxFrames);
    firstFrame = 1; // drop backtrace()'s own frame
#  endif

    QStringList addresses;
    addresses.reserve(count - firstFrame);
    for (int i = firstFrame; i < count; ++i)
        addresses.append(QStringLiteral("0x%1").arg(reinterpret_cast<quintptr>(frames[i]), 16, 16, QLatin1Char('0')));
    return addresses.join(QStringLiteral(", "));
}
#endif

// Resolve a peer's country code via GeoIP.
//
// The GeoIPManager singleton is created by the application on the main thread
// only *after* the torrent session has finished restoring (see the
// Session::restored handler in Application), while these filters run on
// libtorrent's thread and can be invoked during that restore. instance() may
// therefore return nullptr here; dereferencing it used to crash
// (GeoIPManager::lookup with a null `this`). Report the condition once and
// treat the peer as having no country, exactly as when geolocation lookups are
// disabled.
inline QString lookup_peer_country(const lt::peer_info &info)
{
    if (const Net::GeoIPManager *const geoIPManager = Net::GeoIPManager::instance())
        return geoIPManager->lookup(QHostAddress(info.ip.data()));

    static bool reported = false;
    if (!reported)
    {
        reported = true;
        LogMsg(QCoreApplication::translate("peer_blacklist",
                   "Peer filter ran before the IP geolocation database was "
                   "initialized; skipping the country check for this peer."),
               Log::WARNING);
#if !defined(NDEBUG)
        LogMsg(QCoreApplication::translate("peer_blacklist", "GeoIP guard call stack: %1")
                   .arg(callStackToString()),
               Log::WARNING);
#endif
    }
    return {};
}


// bad peer filter
inline bool is_bad_peer(const lt::peer_info& info)
{
  static const std::regex id_filter("-(XL|SD|XF|QD|BN|DL|TS|DT|HP)(\\d+)-");
  static const std::regex ua_filter(R"((\d+.\d+.\d+.\d+|cacao_torrent))");
  static const std::regex consume_filter(R"(((dt|hp|xm)/torrent|Gopeed dev|Rain 0.0.0|(Taipei-torrent( dev)?)))", std::regex_constants::icase);

  // TODO: trafficConsume by thank243(senis) but it's hard to determine GT0003 is legitimate client or not...
  // Anyway, block dt/torrent and Taipei-torrent with specific case first.
  QString country = lookup_peer_country(info);
  if (country == QLatin1String("CN") && std::regex_match(info.client, consume_filter)) {
      return true;
  }

  return std::regex_match(info.pid.data(), info.pid.data() + 8, id_filter) || std::regex_match(info.client, ua_filter);
}

// Unknown Peer filter
inline bool is_unknown_peer(const lt::peer_info& info)
{
  QString country = lookup_peer_country(info);
  return info.client.find("Unknown") != std::string::npos && country == QLatin1String("CN");
}

// Offline Downloader filter
inline bool is_offline_downloader(const lt::peer_info& info)
{
  static const std::regex id_filter("-LT(1220|2070)-");
  unsigned short port = info.ip.port();
  QString country = lookup_peer_country(info);
  // 115: Old data, may out of date.
  bool fake_transmission = port >= 65000 && country == QLatin1String("CN") && info.client.find("Transmission") != std::string::npos;
  // PikPak: PikPak is renting Worldstream server and announce as LT1220/LT2070, the best way is block the ip range via ip filter(?)
  // Xunlei: it seems Xunlei is using LT2070 too
  bool fake_libtorrent = (country == QLatin1String("NL") || country == QLatin1String("CN")) && std::regex_match(info.pid.data(), info.pid.data() + 8, id_filter);
  return fake_transmission || fake_libtorrent;
}

// BitTorrent Media Player Peer filter
inline bool is_bittorrent_media_player(const lt::peer_info& info)
{
  if (info.client.find("StellarPlayer") != std::string::npos || info.client.find("Elementum") != std::string::npos) {
    return true;
  }
  static const std::regex player_filter("-(UW\\w{4}|SP(([0-2]\\d{3})|(3[0-5]\\d{2})))-");
  return !!std::regex_match(info.pid.data(), info.pid.data() + 8, player_filter);
}


// drop connection action
inline void drop_connection(lt::peer_connection_handle ph)
{
  ph.disconnect(boost::asio::error::connection_refused, lt::operation_t::bittorrent, lt::disconnect_severity_t{0});
}


template<typename F>
auto wrap_filter(F filter)
{
  return [=](const lt::peer_info& info, bool handshake, bool* stop_filtering) {
    bool matched = filter(info);
    *stop_filtering = !handshake && !matched;
    return matched;
  };
}


inline std::shared_ptr<lt::torrent_plugin> create_peer_action_plugin(
    const lt::torrent_handle& th,
    filter_function filter,
    action_function action)
{
  // ignore private torrents
  if (th.torrent_file() && th.torrent_file()->priv())
    return nullptr;

  return std::make_shared<peer_action_plugin>(std::move(filter), std::move(action));
}


// plugins factory functions

inline std::shared_ptr<lt::torrent_plugin> create_drop_bad_peers_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_bad_peer), drop_connection);
}

inline std::shared_ptr<lt::torrent_plugin> create_drop_unknown_peers_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_unknown_peer), drop_connection);
}

inline std::shared_ptr<lt::torrent_plugin> create_drop_offline_downloader_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_offline_downloader), drop_connection);
}

inline std::shared_ptr<lt::torrent_plugin> create_drop_bittorrent_media_player_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_bittorrent_media_player), drop_connection);
}
