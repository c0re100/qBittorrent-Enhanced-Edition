/*
 * Bittorrent Client using Qt and libtorrent.
 * Copyright (C) 2026  Art Clark (ArtClark)
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

#include "dialoggeometry.h"

#include <QByteArray>
#include <QSize>
#include <QWidget>

#include "base/settingsstorage.h"

namespace DialogGeometry
{
    namespace
    {
        SettingsStorage *settings()
        {
            return SettingsStorage::instance();
        }

        // ===================================================================
        // Cross-DPI guard.
        //
        // QWidget::saveGeometry() persists the client rect (qwidget.cpp:7421),
        // and restoreGeometry() feeds that same rect straight back into
        // setGeometry() (qwidget.cpp:7629); the frame rect it also stores is
        // read back and then never used. That round trip is lossless only as
        // long as the window keeps the same scale. The invisible borders are
        // part of the position the OS applies, so a rect measured at one
        // devicePixelRatio and re-applied at another comes back offset, and the
        // offset is written into the settings file again on the next close. The
        // dialog then sits a few logical pixels further off on every
        // open/close, linearly, without ever settling.
        //
        // Qt does try to catch the related case of a changed screen, at
        // qwidget.cpp:7561-7564, but it compares screen *widths*. Moving from a
        // 1280-logical-pixel screen at 150% to a 1366-logical-pixel screen at
        // 100% is a width ratio of 1.067, comfortably inside the 0.8-1.25
        // window it accepts, while the ratio that actually carries the error
        // is 1.5. So the check passes and the walk starts.
        //
        // We therefore record the scale a stored geometry was measured at and
        // refuse to re-apply it at a different one. On a mismatch we fall
        // through to the size-only handling below: the remembered size is still
        // good, the remembered position is not, and save() records the new
        // scale, so the very next open is an ordinary one. A geometry stored
        // before this key existed reads back as -1 and counts as a mismatch,
        // which gives every existing user one clean reset rather than a dialog
        // that walks forever.
        // ===================================================================

        // Kept as hundredths of a ratio so the value survives an INI round-trip
        // without depending on QVariant's double formatting.
        int scaleOf(QWidget *dlg)
        {
            return qRound(dlg->devicePixelRatioF() * 100.0);
        }

        QString scaleKey(const QString &geometryKey)
        {
            return geometryKey + QStringLiteral("Ratio");
        }

    }

    bool restore(QWidget *dlg, const QString &geometryKey, const QString &legacySizeKey)
    {
        // loadValue<QByteArray>() coalesces any leftover value of a different type
        // under this key (SettingsStorage guards the conversion) into an empty
        // array, and restoreGeometry() returns false for malformed blobs. Only when
        // both pass do we treat the stored geometry as effective; on any failure we
        // fall through to the legacy size-only value below.
        const QByteArray geometry = settings()->loadValue<QByteArray>(geometryKey);

        // See the cross-DPI guard above. A stored geometry only describes a
        // position that still means something if the scale it was measured at is
        // the scale we are about to restore it at. scaleOf() reads the widget's
        // screen, which before the first show is the primary one - the same
        // screen restoreGeometry() will clamp the rect onto, so this asks the
        // question that actually matters.
        const int storedScale = settings()->loadValue<int>(scaleKey(geometryKey), -1);
        const int currentScale = scaleOf(dlg);
        const bool scaleMatches = (storedScale == currentScale);

        if (!geometry.isEmpty() && scaleMatches)
        {
            if (dlg->restoreGeometry(geometry))
                return true;
        }

        // Backward compatibility with the previous size-only handling: keep the remembered
        // size (but not the position, which was never persisted before). Once a full
        // geometry has been saved, this legacy key is no longer written or consulted and
        // remains in the settings file as an inert orphan entry (harmless - every read is
        // type-guarded by SettingsStorage; a future cleanup may remove it).
        if (!legacySizeKey.isEmpty())
        {
            const QSize legacySize = settings()->loadValue<QSize>(legacySizeKey);
            if (legacySize.isValid())
            {
                dlg->resize(legacySize);
                return true;
            }
        }

        return false;
    }

    void save(QWidget *dlg, const QString &geometryKey)
    {
        settings()->storeValue(geometryKey, dlg->saveGeometry());
        // Recorded next to the geometry it describes; restore() refuses to
        // re-apply the position when this no longer matches the current scale.
        settings()->storeValue(scaleKey(geometryKey), scaleOf(dlg));
    }
}
