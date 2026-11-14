/*
 * Bittorrent Client using Qt and libtorrent.
 * Copyright (C) 2025  Mike Tzou (Chocobo1)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * In addition, as a special exception, the copyright holders give permission to
 * link this program with the OpenSSL project's "OpenSSL" library (or with
 * modified versions of it that use the same license as the "OpenSSL" library),
 * and distribute the linked executables. You must obey the GNU General Public
 * License in all respects for all of the code used other than "OpenSSL".  If you
 * modify file(s), you may extend this exception to your version of the file(s),
 * but you are not obligated to do so. If you do not wish to do so, delete this
 * exception statement from your version.
 */

#include <algorithm>
#include <cstring>
#include <string>

#include <QBitArray>
#include <QHostAddress>
#include <QTest>

#include "base/bittorrent/peer_blacklist.hpp"
#include "base/bittorrent/peerinfo.h"
#include "base/logger.h"
#include "base/net/geoipmanager.h"

using namespace Qt::Literals::StringLiterals;

namespace
{
    lt::peer_info makePeer(const QString &ip = u"1.2.3.4"_s, const int port = 6881
            , const std::string &client = {}, const std::string &peerId = {})
    {
        lt::peer_info info;
        info.ip = decltype(info.ip)(lt::make_address(ip.toStdString()), static_cast<unsigned short>(port));
        info.client = client;
        // peer_info::pid is a fixed-size (160 bit) peer_id and the filters only
        // look at its first 8 bytes.
        std::memcpy(info.pid.data(), peerId.data(), std::min<std::size_t>(8, peerId.size()));
        return info;
    }
}

// Regression test for the startup crash (0xc0000005) reported in
// qBittorrent-Enhanced-Edition 5.2.3.10 / 5.2.4.10.
//
// The geo-IP filters are invoked from libtorrent's thread while the session is
// still restoring, i.e. before Application has had a chance to construct the
// GeoIPManager singleton on the main thread. The filters used to dereference
// `Net::GeoIPManager::instance()` (null at that point) unconditionally, which
// crashed inside GeoIPManager::lookup().
//
// The test reproduces that ordering: it calls the filters while no
// GeoIPManager exists (nothing ever calls GeoIPManager::initInstance()), and
// asserts that the filters neither crash nor apply the country-based rules,
// while the country-independent rules keep working.
class TestPeerFilter final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(TestPeerFilter)

public:
    TestPeerFilter() = default;

private slots:
    void initTestCase()
    {
        // LogMsg() needs the Logger singleton that the application would
        // otherwise set up. It does not need a QCoreApplication.
        Logger::initInstance();
    }

    void cleanupTestCase()
    {
        Logger::freeInstance();
    }

    void testGeoIPManagerIsMissing() const
    {
        // Precondition of this test: the singleton is only created by
        // GeoIPManager::initInstance(), which a unit test never calls.
        QVERIFY(Net::GeoIPManager::instance() == nullptr);
    }

    void testLookupWithoutManagerReturnsEmpty() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);
        QVERIFY(lookup_peer_country(makePeer()).isEmpty());
    }

    void testBadPeerPeerIdRuleStillApplies() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);

        // The PeerID based detection does not depend on GeoIP ...
        QVERIFY(is_bad_peer(makePeer(u"1.2.3.4"_s, 6881, "client", "-XL0012-")));
    }

    void testBadPeerCountryRuleIsSkipped() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);

        // ... but the rule that requires the peer to be located in CN cannot
        // fire without the database. This used to crash.
        QVERIFY(!is_bad_peer(makePeer(u"1.2.3.4"_s, 6881, "dt/torrent 1.0", "-AA0000-")));
    }

    void testUnknownPeerIsSkipped() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);
        QVERIFY(!is_unknown_peer(makePeer(u"1.2.3.4"_s, 6881, "Unknown 1.0", "-AA0000-")));
    }

    void testOfflineDownloaderIsSkipped() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);

        // Both rules require a country code, so neither can match here.
        QVERIFY(!is_offline_downloader(makePeer(u"1.2.3.4"_s, 65000, "Transmission 4.0.0", "-AA0000-")));
        QVERIFY(!is_offline_downloader(makePeer(u"1.2.3.4"_s, 6881, "libtorrent", "-LT1220-")));
    }

    void testMediaPlayerFilterIsUnaffected() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);
        QVERIFY(is_bittorrent_media_player(makePeer(u"1.2.3.4"_s, 6881, "StellarPlayer", "-AA0000-")));
    }

    void testPeerInfoCountryWithoutManager() const
    {
        QVERIFY(Net::GeoIPManager::instance() == nullptr);

        const BitTorrent::PeerInfo peerInfo(makePeer(u"1.2.3.4"_s, 6881, "client", "-AA0000-"), QBitArray());
        QVERIFY(peerInfo.country().isEmpty());
        QVERIFY(peerInfo.country().isEmpty()); // a second (cached) query must not crash either
    }
};

QTEST_APPLESS_MAIN(TestPeerFilter)
#include "testpeerfilter.moc"
