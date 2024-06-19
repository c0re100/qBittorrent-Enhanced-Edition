#pragma once

#include <regex>

#include <libtorrent/torrent_info.hpp>

#include <QHostAddress>

#include "base/net/geoipmanager.h"

#include "peer_filter_plugin.hpp"
#include "peer_logger.hpp"

// bad peer filter
bool is_bad_peer(const lt::peer_info& info)
{
  static const std::regex id_filter("-(XL|SD|XF|QD|BN|DL|TS|DT|HP)(\\d+)-");
  static const std::regex ua_filter(R"((\d+.\d+.\d+.\d+|cacao_torrent))");
  static const std::regex consume_filter(R"(((dt|hp|xm)/torrent|Gopeed dev|Rain 0.0.0|(Taipei-torrent( dev)?)))", std::regex_constants::icase);

  // TODO: trafficConsume by thank243(senis) but it's hard to determine GT0003 is legitimate client or not...
  // Anyway, block dt/torrent and Taipei-torrent with specific case first.
  QString country = Net::GeoIPManager::instance()->lookup(QHostAddress(info.ip.data()));
  if (country == QLatin1String("CN") && std::regex_match(info.client, consume_filter)) {
      return true;
  }

  return std::regex_match(info.pid.data(), info.pid.data() + 8, id_filter) || std::regex_match(info.client, ua_filter);
}

// Unknown Peer filter
bool is_unknown_peer(const lt::peer_info& info)
{
  QString country = Net::GeoIPManager::instance()->lookup(QHostAddress(info.ip.data()));
  return info.client.find("Unknown") != std::string::npos && country == QLatin1String("CN");
}

// Offline Downloader filter
bool is_offline_downloader(const lt::peer_info& info)
{
  static const std::regex id_filter("-LT(1220|2070)-");
  unsigned short port = info.ip.port();
  QString country = Net::GeoIPManager::instance()->lookup(QHostAddress(info.ip.data()));
  // 115: Old data, may out of date.
  bool fake_transmission = port >= 65000 && country == QLatin1String("CN") && info.client.find("Transmission") != std::string::npos;
  // PikPak: PikPak is renting Worldstream server and announce as LT1220/LT2070, the best way is block the ip range via ip filter(?)
  // Xunlei: it seems Xunlei is using LT2070 too
  bool fake_libtorrent = (country == QLatin1String("NL") || country == QLatin1String("CN")) && std::regex_match(info.pid.data(), info.pid.data() + 8, id_filter);
  return fake_transmission || fake_libtorrent;
}

// BitTorrent Media Player Peer filter
bool is_bittorrent_media_player(const lt::peer_info& info)
{
  if (info.client.find("StellarPlayer") != std::string::npos || info.client.find("Elementum") != std::string::npos) {
    return true;
  }
  static const std::regex player_filter("-(UW\\w{4}|SP(([0-2]\\d{3})|(3[0-5]\\d{2})))-");
  return !!std::regex_match(info.pid.data(), info.pid.data() + 8, player_filter);
}


// drop connection action
void drop_connection(lt::peer_connection_handle ph)
{
  ph.disconnect(boost::asio::error::connection_refused, lt::operation_t::bittorrent, lt::disconnect_severity_t{0});
}


template<typename F>
auto wrap_filter(F filter, const std::string& tag)
{
  return [=](const lt::peer_info& info, bool handshake, bool* stop_filtering) {
    bool matched = filter(info);
    *stop_filtering = !handshake && !matched;
    if (matched)
      peer_logger_singleton::instance().log_peer(info, tag);
    return matched;
  };
}


std::shared_ptr<lt::torrent_plugin> create_peer_action_plugin(
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

std::shared_ptr<lt::torrent_plugin> create_drop_bad_peers_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_bad_peer, "bad peer"), drop_connection);
}

std::shared_ptr<lt::torrent_plugin> create_drop_unknown_peers_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_unknown_peer, "unknown peer"), drop_connection);
}

std::shared_ptr<lt::torrent_plugin> create_drop_offline_downloader_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_offline_downloader, "offline downloader"), drop_connection);
}

std::shared_ptr<lt::torrent_plugin> create_drop_bittorrent_media_player_plugin(lt::torrent_handle const& th, client_data)
{
  return create_peer_action_plugin(th, wrap_filter(is_bittorrent_media_player, "bittorrent media player"), drop_connection);
}
