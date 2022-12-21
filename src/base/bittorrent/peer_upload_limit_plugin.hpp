#pragma once

#include <libtorrent/extensions.hpp>

#include <libtorrent/ip_filter.hpp>

#include <libtorrent/peer_connection_handle.hpp>
#include <libtorrent/peer_info.hpp>

#include <libtorrent/session_handle.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>

#include "peer_logger.hpp"
#include "peer_plugins_compat.hpp"

class peer_timed_check_plugin final : public lt::peer_plugin
{
public:
  using filter_function_t = std::function<bool(const lt::peer_info&)>;
  using action_function_t = std::function<void(lt::peer_connection_handle)>;

  peer_timed_check_plugin(lt::peer_connection_handle ph, filter_function_t filter, action_function_t action)
    : m_connection(std::move(ph))
    , m_filter(std::move(filter))
    , m_action(std::move(action))
  {
  }

  void tick() override
  {
    lt::peer_info info;
    m_connection.get_peer_info(info);

    if (m_filter(info))
      m_action(m_connection);
  }

private:
  lt::peer_connection_handle m_connection;
  filter_function_t m_filter;
  action_function_t m_action;
};


class peer_upload_limit_plugin final : public lt::torrent_plugin
{
public:
  peer_upload_limit_plugin(lt::session_handle sh, lt::torrent_handle th)
    : m_session(std::move(sh))
    , m_torrent(std::move(th))
  {
  }

  std::shared_ptr<lt::peer_plugin> new_connection(lt::peer_connection_handle const& conn) override
  {
    // *INDENT-OFF*
    return std::make_shared<peer_timed_check_plugin>(conn,
        [this](auto&& info) { return filter(info); },
        [this](auto&& conn) { action(conn); });
    // *INDENT-ON*
  }

private:
  bool filter(const lt::peer_info& info)
  {
    lt::torrent_status status = m_torrent.status(lt::torrent_handle::query_accurate_download_counters);
    if (info.total_upload > status.total_wanted_done) {
      peer_logger_singleton::instance().log_peer(info, "upload limit");
      // peer is considered suspicious (downloaded too much)
      // just dropping connection is not enough - it will be able to download after reconnect
      // so ban its IP (ban should be NOT permanent - only for current session)
      lt::ip_filter ip_filter = m_session.get_ip_filter();
      ip_filter.add_rule(info.ip.address(), info.ip.address(), lt::ip_filter::blocked);
      m_session.set_ip_filter(ip_filter);
      return true;
    }
    return false;
  }

  void action(lt::peer_connection_handle conn)
  {
    conn.disconnect(boost::asio::error::connection_refused, lt::operation_t::bittorrent, lt::disconnect_severity_t{0});
  }

private:
  lt::session_handle m_session;
  lt::torrent_handle m_torrent;
};


class peer_upload_limit_session_plugin final : public lt::plugin
{
public:
  void added(lt::session_handle const& sess) override
  {
    m_session = sess;
  }

  std::shared_ptr<lt::torrent_plugin> new_torrent(const lt::torrent_handle& th, lt::client_data_t) override
  {
    // ignore private torrents
    if (th.torrent_file() && th.torrent_file()->priv())
      return nullptr;

    return std::make_shared<peer_upload_limit_plugin>(m_session, th);
  }

private:
  lt::session_handle m_session;
};
