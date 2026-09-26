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

#pragma once

#include <QString>

class QSize;
class QWidget;
// Helper functions to persist a dialog's geometry (position + size) across sessions.
// Unlike the historical size-only handling, this stores the full geometry so that
// a dialog keeps both its size and its position on screen.
namespace DialogGeometry
{
    // Restores a previously saved geometry. The stored `QByteArray` (using `QWidget::saveGeometry()`)
    // includes both the size and the position, and `QWidget::restoreGeometry()` clamps the dialog
    // back to a visible screen if it was saved on a now-unavailable monitor.
    //
    // `legacySizeKey` provides backward compatibility: dialogs that historically only stored their
    // size (as a `QSize`) and not their position will keep that remembered size on first run after
    // the upgrade, before a full geometry has been saved.
    //
    // Returns true if a geometry (or the legacy size) was successfully applied.
    bool restore(QWidget *dlg, const QString &geometryKey, const QString &legacySizeKey = {});

    // Saves the current geometry (position + size) of the dialog.
    void save(QWidget *dlg, const QString &geometryKey);
}
