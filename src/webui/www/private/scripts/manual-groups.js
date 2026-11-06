/* SPDX-License-Identifier: GPL-2.0-or-later */
"use strict";

window.qBittorrent ??= {};
window.qBittorrent.ManualGroups = (() => {
    // One server-side key per torrent: independent edits never overwrite other groups.
    const prefix = "qbt_manual_group_";
    let memberships = new Map();
    const expanded = new Set();
    let table;
    let busy = false;
    let generation = 0;
    let ready = false;

    const request = async (action, body) => {
        const response = await fetch(`api/v2/clientdata/${action}`, {
            method: "POST",
            body: new URLSearchParams(body),
            cache: "no-store"
        });
        if (!response.ok)
            throw new Error(`${"QBT_TR(Unable to save/load groups)QBT_TR[CONTEXT=ManualGroups]"} (HTTP ${response.status})`);
        return action === "load" ? response.json() : null;
    };

    const refresh = async () => {
        const version = generation;
        const data = await request("load", {});
        if (busy || (version !== generation))
            return;
        memberships = new Map(Object.entries(data)
            .filter(([key, value]) => key.startsWith(prefix) && (typeof value === "string") && value.trim())
            .map(([key, value]) => [key.substring(prefix.length), value]));
        ready = true;
        table?.updateTable();
    };

    const save = async (hashes, name) => {
        if (busy || !ready)
            throw new Error("QBT_TR(Groups are not ready. Please retry.)QBT_TR[CONTEXT=ManualGroups]");
        const cleaned = name === null ? null : name.trim();
        if ((cleaned !== null) && (!cleaned || (cleaned.length > 100)))
            throw new Error("QBT_TR(Use a group name of 1–100 characters.)QBT_TR[CONTEXT=ManualGroups]");
        const ids = [...new Set(hashes)].filter(hash => /^[a-f\d]{40,64}$/i.test(hash));
        if (!ids.length)
            throw new Error("QBT_TR(Select torrents first.)QBT_TR[CONTEXT=ManualGroups]");
        busy = true;
        ++generation;
        try {
            await request("store", { data: JSON.stringify(Object.fromEntries(ids.map(hash => [prefix + hash, cleaned]))) });
            for (const hash of ids) {
                if (cleaned === null)
                    memberships.delete(hash);
                else
                    memberships.set(hash, cleaned);
            }
            table?.updateTable();
        }
        finally {
            busy = false;
        }
    };

    // Filtering and sorting precede grouping. Headers summarize only matching members.
    const layout = (rows) => {
        const groups = new Map();
        for (const row of rows) {
            const name = memberships.get(row.rowId);
            if (name) {
                if (!groups.has(name))
                    groups.set(name, []);
                groups.get(name).push(row);
            }
        }
        const display = [];
        const selectable = [];
        const emitted = new Set();
        for (const row of rows) {
            const name = memberships.get(row.rowId);
            if (!name) {
                display.push(row);
                selectable.push(row);
            }
            else if (!emitted.has(name)) {
                emitted.add(name);
                display.push({ rowId: `manual-group:${name}`, groupName: name, members: groups.get(name) });
                if (expanded.has(name)) {
                    display.push(...groups.get(name));
                    selectable.push(...groups.get(name));
                }
            }
        }
        return { display, selectable };
    };

    const button = (label, fn) => {
        const element = document.createElement("button");
        element.type = "button";
        element.textContent = label;
        element.onclick = fn;
        return element;
    };

    const edit = async (groupName = null) => {
        try {
            await refresh();
        }
        catch (error) {
            alert(error.message);
            return;
        }
        const hashes = groupName === null ? table.selectedRowsIds()
            : [...memberships].filter(([, name]) => name === groupName).map(([hash]) => hash);
        if (!hashes.length) {
            alert("QBT_TR(Select torrents with Ctrl/Shift first.)QBT_TR[CONTEXT=ManualGroups]");
            return;
        }
        const dialog = document.createElement("dialog");
        dialog.className = "manualGroupsDialog";
        const title = document.createElement("h3");
        title.textContent = groupName === null ? "QBT_TR(Group selected torrents)QBT_TR[CONTEXT=ManualGroups]" : "QBT_TR(Manage group)QBT_TR[CONTEXT=ManualGroups]";
        const count = document.createElement("p");
        count.textContent = `${hashes.length} ${"QBT_TR(torrents; files and download states stay unchanged)QBT_TR[CONTEXT=ManualGroups]"}`;
        const label = document.createElement("label");
        label.textContent = "QBT_TR(Group name (enter an existing name to join))QBT_TR[CONTEXT=ManualGroups]";
        const input = document.createElement("input");
        input.maxLength = 100;
        input.value = groupName ?? "";
        input.setAttribute("list", "manualGroupNames");
        label.append(input);
        const names = document.createElement("datalist");
        names.id = "manualGroupNames";
        for (const name of new Set(memberships.values())) {
            const option = document.createElement("option");
            option.value = name;
            names.append(option);
        }
        const errorText = document.createElement("p");
        errorText.setAttribute("role", "alert");
        const actions = document.createElement("div");
        const commit = async (name) => {
            for (const control of dialog.querySelectorAll("button, input"))
                control.disabled = true;
            try {
                await save(hashes, name);
                dialog.close();
            }
            catch (error) {
                errorText.textContent = error.message;
            }
            finally {
                for (const control of dialog.querySelectorAll("button, input"))
                    control.disabled = false;
            }
        };
        actions.append(button("QBT_TR(Save group)QBT_TR[CONTEXT=ManualGroups]", () => commit(input.value)),
            button(groupName === null ? "QBT_TR(Remove from group)QBT_TR[CONTEXT=ManualGroups]" : "QBT_TR(Dissolve group)QBT_TR[CONTEXT=ManualGroups]", () => commit(null)),
            button("QBT_TR(Cancel)QBT_TR[CONTEXT=ManualGroups]", () => dialog.close()));
        input.addEventListener("keydown", (event) => {
            if (event.key === "Enter") {
                event.preventDefault();
                commit(input.value);
            }
        });
        dialog.append(title, count, label, names, errorText, actions);
        dialog.addEventListener("close", () => dialog.remove(), { once: true });
        document.body.append(dialog);
        dialog.showModal();
        input.focus();
    };

    const render = (tr, row, columns, virtual) => {
        tr.dataset.displayOnly = "true";
        tr.classList.add("manualGroupHeader");
        const size = row.members.reduce((sum, member) => sum + (member.full_data.size || 0), 0);
        const completed = row.members.reduce((sum, member) => sum + ((member.full_data.size || 0) * (member.full_data.progress || 0)), 0);
        for (const [index, column] of columns.entries()) {
            const td = tr.children[index];
            if (column.name !== "name")
                td.replaceChildren();
            td.removeAttribute("title");
            td.className = ((column.visible === "0") || column.force_hide) ? "invisible" : "";
            if (virtual) {
                td.style.width = `${column.width}px`;
                td.style.maxWidth = `${column.width}px`;
            }
            if (column.name === "name") {
                let controls = td.querySelector(".manualGroupControls");
                if (!controls) {
                    controls = document.createElement("div");
                    controls.className = "manualGroupControls";
                    controls.append(button("", () => {}), button("", () => {}));
                    td.replaceChildren(controls);
                }
                const toggle = controls.children[0];
                toggle.textContent = `${expanded.has(row.groupName) ? "▼" : "▶"} ${row.groupName} (${row.members.length})`;
                toggle.onclick = () => {
                    if (expanded.has(row.groupName))
                        expanded.delete(row.groupName);
                    else
                        expanded.add(row.groupName);
                    table.updateTable();
                    table.onSelectedRowChanged?.();
                };
                toggle.setAttribute("aria-expanded", String(expanded.has(row.groupName)));
                toggle.title = toggle.textContent;
                controls.children[1].textContent = "QBT_TR(Manage)QBT_TR[CONTEXT=ManualGroups]";
                controls.children[1].onclick = () => edit(row.groupName);
            }
            else if (column.name === "size")
                {td.textContent = window.qBittorrent.Misc.friendlyUnit(size);}
            else if (column.name === "progress")
                {td.textContent = size ? `${((completed / size) * 100).toFixed(1)}%` : "—";}
            else if (column.name === "status")
                {td.textContent = `${row.members.length} ${"QBT_TR(matching torrents)QBT_TR[CONTEXT=ManualGroups]"}`;}
            else if (["dlspeed", "upspeed"].includes(column.name))
                {td.textContent = window.qBittorrent.Misc.friendlyUnit(row.members.reduce((sum, member) => sum + (member.full_data[column.name] || 0), 0), true);}
        }
    };

    const init = (torrentTable) => {
        table = torrentTable;
        const control = button("QBT_TR(Group…)QBT_TR[CONTEXT=ManualGroups]", () => edit());
        control.id = "manualGroupButton";
        document.getElementById("preferencesButton").after(control);
        // Display-only headers must never reach torrent actions or native selection handlers.
        for (const type of ["click", "dblclick", "contextmenu", "touchstart", "keydown"]) {
            table.dynamicTableDiv.addEventListener(type, (event) => {
                if (event.target.closest("tr")?.dataset.displayOnly !== "true")
                    return;
                if ((type === "click") && event.target.closest("button")) {
                    event.stopPropagation();
                    event.target.closest("button").onclick(event);
                }
                else if ((type === "keydown") && ["Enter", " "].includes(event.key) && event.target.closest("button")) {
                    event.preventDefault();
                    event.stopPropagation();
                    event.target.closest("button").onclick(event);
                }
                else if (type !== "keydown") {
                    event.preventDefault();
                    event.stopPropagation();
                }
            }, true);
        }
        const sync = () => refresh().catch(error => {
            control.title = error.message;
        });
        sync();
        window.setInterval(() => {
            if (!document.hidden && !busy)
                sync();
        }, 10000);
    };
    return { init, layout, render };
})();
