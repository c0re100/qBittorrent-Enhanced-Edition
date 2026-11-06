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

    const keyOf = path => JSON.stringify(path);
    const within = (path, ancestor) => (path.length >= ancestor.length)
        && ancestor.every((name, index) => path[index] === name);
    const decodePath = value => {
        const path = typeof value === "string" ? [value] : value;
        return Array.isArray(path) && (path.length > 0) && (path.length <= 32)
            && path.every(name => (typeof name === "string") && name.trim() && (name.length <= 100))
            ? path : null;
    };
    const encodePath = path => !path.length ? null : (path.length === 1 ? path[0] : path);

    const refresh = async () => {
        const version = generation;
        const data = await request("load", {});
        if (busy || (version !== generation))
            return;
        memberships = new Map(Object.entries(data)
            .filter(([key, value]) => key.startsWith(prefix) && decodePath(value))
            .map(([key, value]) => [key.substring(prefix.length), decodePath(value)]));
        ready = true;
        table?.updateTable();
    };

    const allPaths = () => {
        const paths = new Map();
        for (const path of memberships.values()) {
            for (let depth = 1; depth <= path.length; ++depth) {
                const parent = path.slice(0, depth);
                paths.set(keyOf(parent), parent);
            }
        }
        return [...paths.values()].sort((a, b) => a.join(" / ").localeCompare(b.join(" / ")));
    };

    const save = async (hashes, name, parent = [], source = null) => {
        if (busy || !ready)
            throw new Error("QBT_TR(Groups are not ready. Please retry.)QBT_TR[CONTEXT=ManualGroups]");
        const cleaned = name === null ? null : name.trim();
        if ((cleaned !== null) && (!cleaned || (cleaned.length > 100)))
            throw new Error("QBT_TR(Use a group name of 1–100 characters.)QBT_TR[CONTEXT=ManualGroups]");
        if (source && (cleaned !== null) && within(parent, source))
            throw new Error("QBT_TR(A group cannot be placed inside itself or its descendants.)QBT_TR[CONTEXT=ManualGroups]");
        const target = cleaned === null ? (source?.slice(0, -1) ?? []) : [...parent, cleaned];
        const changes = new Map();
        if (source) {
            // Rewrite only this subtree; other groups and client settings stay untouched.
            for (const [hash, path] of memberships) {
                if (within(path, source))
                    changes.set(hash, [...target, ...path.slice(source.length)]);
            }
        }
        else {
            for (const hash of new Set(hashes)) {
                if (/^[a-f\d]{40,64}$/i.test(hash))
                    changes.set(hash, target);
            }
        }
        if (!changes.size)
            throw new Error("QBT_TR(Select torrents first.)QBT_TR[CONTEXT=ManualGroups]");
        if ([...changes.values()].some(path => path.length > 32))
            throw new Error("QBT_TR(A group can have at most 32 levels.)QBT_TR[CONTEXT=ManualGroups]");
        busy = true;
        ++generation;
        try {
            await request("store", { data: JSON.stringify(Object.fromEntries([...changes].map(([hash, path]) => [prefix + hash, encodePath(path)]))) });
            for (const [hash, path] of changes) {
                if (!path.length)
                    memberships.delete(hash);
                else
                    memberships.set(hash, path);
            }
            if (source) {
                const openPaths = [...expanded].map(key => JSON.parse(key));
                for (const path of openPaths) {
                    if (within(path, source)) {
                        expanded.delete(keyOf(path));
                        const moved = [...target, ...path.slice(source.length)];
                        if (moved.length)
                            expanded.add(keyOf(moved));
                    }
                }
            }
            table?.updateTable();
            table?.onSelectedRowChanged?.();
        }
        finally {
            busy = false;
        }
    };

    // Build ancestors after filtering: each member contributes once to each ancestor.
    const layout = (rows) => {
        const root = { entries: [], children: new Map() };
        for (const row of rows) {
            let node = root;
            const path = memberships.get(row.rowId) ?? [];
            for (let depth = 0; depth < path.length; ++depth) {
                const name = path[depth];
                if (!node.children.has(name)) {
                    const groupPath = path.slice(0, depth + 1);
                    const child = {
                        rowId: `manual-group:${keyOf(groupPath)}`,
                        groupName: name,
                        groupPath: groupPath,
                        groupKey: keyOf(groupPath),
                        depth: depth,
                        members: [],
                        entries: [],
                        children: new Map()
                    };
                    node.children.set(name, child);
                    node.entries.push(child);
                }
                node = node.children.get(name);
                node.members.push(row);
            }
            node.entries.push(row);
        }
        const display = [];
        const selectable = [];
        const depths = new Map();
        const visit = (node, depth) => {
            for (const entry of node.entries) {
                display.push(entry);
                if (entry.groupPath) {
                    if (expanded.has(entry.groupKey))
                        visit(entry, depth + 1);
                }
                else {
                    selectable.push(entry);
                    depths.set(entry.rowId, depth);
                }
            }
        };
        visit(root, 0);
        return { display, selectable, depths };
    };

    const button = (label, fn) => {
        const element = document.createElement("button");
        element.type = "button";
        element.textContent = label;
        element.onclick = fn;
        return element;
    };

    const edit = async (groupPath = null) => {
        try {
            await refresh();
        }
        catch (error) {
            alert(error.message);
            return;
        }
        const hashes = groupPath === null ? table.selectedRowsIds()
            : [...memberships].filter(([, path]) => within(path, groupPath)).map(([hash]) => hash);
        if (!hashes.length) {
            alert("QBT_TR(Select torrents with Ctrl/Shift first.)QBT_TR[CONTEXT=ManualGroups]");
            return;
        }
        const dialog = document.createElement("dialog");
        dialog.className = "manualGroupsDialog";
        const title = document.createElement("h3");
        title.textContent = groupPath === null ? "QBT_TR(Group selected torrents)QBT_TR[CONTEXT=ManualGroups]" : "QBT_TR(Manage group)QBT_TR[CONTEXT=ManualGroups]";
        const count = document.createElement("p");
        count.textContent = `${hashes.length} ${"QBT_TR(torrents; files and download states stay unchanged)QBT_TR[CONTEXT=ManualGroups]"}`;
        const label = document.createElement("label");
        label.textContent = "QBT_TR(Group name (enter an existing name to join))QBT_TR[CONTEXT=ManualGroups]";
        const input = document.createElement("input");
        input.maxLength = 100;
        input.value = groupPath?.at(-1) ?? "";
        input.setAttribute("list", "manualGroupNames");
        label.append(input);
        const names = document.createElement("datalist");
        names.id = "manualGroupNames";
        for (const name of new Set(allPaths().map(path => path.at(-1)))) {
            const option = document.createElement("option");
            option.value = name;
            names.append(option);
        }
        const parentLabel = document.createElement("label");
        parentLabel.textContent = "QBT_TR(Parent group)QBT_TR[CONTEXT=ManualGroups]";
        const parentSelect = document.createElement("select");
        parentSelect.id = "manualGroupParent";
        const top = document.createElement("option");
        top.value = "[]";
        top.textContent = "QBT_TR(Top level)QBT_TR[CONTEXT=ManualGroups]";
        parentSelect.append(top);
        for (const path of allPaths()) {
            const option = document.createElement("option");
            option.value = keyOf(path);
            option.textContent = path.join(" / ");
            option.disabled = (groupPath !== null) && within(path, groupPath);
            parentSelect.append(option);
        }
        parentSelect.value = keyOf(groupPath?.slice(0, -1) ?? []);
        parentLabel.append(parentSelect);
        const hint = document.createElement("p");
        hint.textContent = "QBT_TR(Dissolving a group moves its torrents and subgroups up one level.)QBT_TR[CONTEXT=ManualGroups]";
        const errorText = document.createElement("p");
        errorText.setAttribute("role", "alert");
        const actions = document.createElement("div");
        const commit = async (name) => {
            for (const control of dialog.querySelectorAll("button, input, select"))
                control.disabled = true;
            try {
                await save(hashes, name, JSON.parse(parentSelect.value), groupPath);
                dialog.close();
            }
            catch (error) {
                errorText.textContent = error.message;
            }
            finally {
                for (const control of dialog.querySelectorAll("button, input, select"))
                    control.disabled = false;
            }
        };
        actions.append(button("QBT_TR(Save group)QBT_TR[CONTEXT=ManualGroups]", () => commit(input.value)),
            button(groupPath === null ? "QBT_TR(Remove from group)QBT_TR[CONTEXT=ManualGroups]" : "QBT_TR(Dissolve group)QBT_TR[CONTEXT=ManualGroups]", () => commit(null)),
            button("QBT_TR(Cancel)QBT_TR[CONTEXT=ManualGroups]", () => dialog.close()));
        input.addEventListener("keydown", (event) => {
            if (event.key === "Enter") {
                event.preventDefault();
                commit(input.value);
            }
        });
        dialog.append(title, count, label, names, parentLabel);
        if (groupPath)
            dialog.append(hint);
        dialog.append(errorText, actions);
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
            td.style.paddingInlineStart = "";
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
                toggle.textContent = `${expanded.has(row.groupKey) ? "▼" : "▶"} ${row.groupName} (${row.members.length})`;
                toggle.onclick = () => {
                    if (expanded.has(row.groupKey))
                        expanded.delete(row.groupKey);
                    else
                        expanded.add(row.groupKey);
                    table.updateTable();
                    table.onSelectedRowChanged?.();
                };
                toggle.setAttribute("aria-expanded", String(expanded.has(row.groupKey)));
                toggle.title = row.groupPath.join(" / ");
                controls.style.marginInlineStart = `${row.depth * 16}px`;
                controls.children[1].textContent = "QBT_TR(Manage)QBT_TR[CONTEXT=ManualGroups]";
                controls.children[1].onclick = () => edit(row.groupPath);
            }
            else if (column.name === "size") { td.textContent = window.qBittorrent.Misc.friendlyUnit(size); }
            else if (column.name === "progress") { td.textContent = size ? `${((completed / size) * 100).toFixed(1)}%` : "—"; }
            else if (column.name === "status") { td.textContent = `${row.members.length} ${"QBT_TR(matching torrents)QBT_TR[CONTEXT=ManualGroups]"}`; }
            else if (["dlspeed", "upspeed"].includes(column.name)) { td.textContent = window.qBittorrent.Misc.friendlyUnit(row.members.reduce((sum, member) => sum + (member.full_data[column.name] || 0), 0), true); }
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
