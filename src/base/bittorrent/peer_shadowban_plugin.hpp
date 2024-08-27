#pragma once

#include <QString>
#include <libtorrent/extensions.hpp>
#include <libtorrent/peer_connection_handle.hpp>

#if (LIBTORRENT_VERSION_NUM >= 20000)
using client_data = lt::client_data_t;
#else
using client_data = void *;
#endif

using filter_function = std::function<bool(const lt::peer_info &, bool, bool *)>;

class peer_shadowban_plugin final : public lt::peer_plugin
{
public:
    peer_shadowban_plugin(lt::peer_connection_handle p)
        : m_peer_connection(p)
    {
    }

    bool on_request(lt::peer_request const &r) override
    {
        if (is_shadowbanned_peer())
        {
            return true;
        }
        return peer_plugin::on_request(r);
    }

    // don't send request if peer shadowbanned to prevent use this function to leech
    bool write_request(lt::peer_request const &r) override
    {
        if (is_shadowbanned_peer())
        {
            return true;
        }
        return peer_plugin::write_request(r);
    }

protected:
    bool is_shadowbanned_peer()
    {
        lt::peer_info info;
        m_peer_connection.get_peer_info(info);

        QString peer_ip = QString::fromStdString(info.ip.address().to_string());
        QStringList shadowbannedIPs =
            CachedSettingValue<QStringList>(u"State/ShadowBannedIPs"_s, QStringList(), Algorithm::sorted<QStringList>).get();

        return shadowbannedIPs.contains(peer_ip);
    }

private:
    lt::peer_connection_handle m_peer_connection;
};

class peer_shadowban_action_plugin : public lt::torrent_plugin
{
public:
    peer_shadowban_action_plugin()
    {
    }

    std::shared_ptr<lt::peer_plugin> new_connection(lt::peer_connection_handle const &p) override
    {
        return std::make_shared<peer_shadowban_plugin>(p);
    }
};

std::shared_ptr<lt::torrent_plugin> create_peer_shadowban_plugin(const lt::torrent_handle &th, client_data)
{
    // ignore private torrents
    if (th.torrent_file() && th.torrent_file()->priv())
        return nullptr;

    return std::make_shared<peer_shadowban_action_plugin>();
}
