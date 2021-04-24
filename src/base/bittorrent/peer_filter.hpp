#pragma once

#include <algorithm>
#include <fstream>
#include <string>

#include <QRegularExpression>
#include <QString>
#include <QVector>

#include <libtorrent/peer_info.hpp>

#include "base/logger.h"

namespace {

bool qregex_has_match(const QRegularExpression& re, const QString& str)
{
  auto m = re.match(str);
  return m.hasMatch();
}

}

class peer_filter
{
public:
  explicit peer_filter(const QString& filter_file)
  {
    std::ifstream ifs(filter_file.toStdString());
    std::string peer_id, client;
    while (ifs >> peer_id >> client) {
      QRegularExpression peer_id_re(QString::fromStdString(peer_id));
      QRegularExpression client_re(QString::fromStdString(client));

      QString msg_tmpl("whitelist: invalid %1 matching expression '%2' detected, ignoring rule");

      if (!peer_id_re.isValid())
        LogMsg(msg_tmpl.arg("peer id").arg(peer_id_re.pattern()), Log::WARNING);

      if (!client_re.isValid())
        LogMsg(msg_tmpl.arg("client name").arg(client_re.pattern()), Log::WARNING);

      if (peer_id_re.isValid() && client_re.isValid())
        m_filters.append({peer_id_re, client_re});
    }

    if (m_filters.isEmpty())
      LogMsg("whitelist: no rules were loaded, any connections will be dropped", Log::CRITICAL);
  }

  bool match_peer(const lt::peer_info& info, bool skip_name) const
  {
    QString peer_id = QString::fromLatin1(info.pid.data(), 8);
    QString client = QString::fromStdString(info.client);
    return std::any_of(m_filters.begin(), m_filters.end(),
                       [&](const auto& filter) {
                           return qregex_has_match(filter[0], peer_id) &&
                               (skip_name || qregex_has_match(filter[1], client));
                       });
  }

private:
  QVector<QVector<QRegularExpression>> m_filters;
};
