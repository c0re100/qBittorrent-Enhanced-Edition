/* SPDX-License-Identifier: GPL-2.0-or-later */
import { afterEach, beforeEach, expect, test, vi } from "vitest";

const hashA = "a".repeat(40);
const hashB = "b".repeat(40);
let data;
let table;
let groups;
let failSave;
const row = (hash, path) => ({ rowId: hash, full_data: { save_path: path, size: 100, progress: 0.5 } });

beforeEach(async () => {
    vi.resetModules();
    document.body.innerHTML = '<button id="preferencesButton"></button><div id="table"></div>';
    document.documentElement.lang = "en";
    data = { [`qbt_manual_group_${hashA}`]: "Series", [`qbt_manual_group_${hashB}`]: "Series", qbt_unrelated: "keep" };
    failSave = false;
    window.qBittorrent = { Misc: { friendlyUnit: String } };
    vi.stubGlobal("fetch", vi.fn((url, options) => {
        if (url.endsWith("load"))
            return Promise.resolve({ ok: true, json: () => Promise.resolve({ ...data }) });
        if (failSave)
            return Promise.resolve({ ok: false, status: 409 });
        const changes = JSON.parse(options.body.get("data"));
        for (const [key, value] of Object.entries(changes)) {
            if (value === null)
                delete data[key];
            else
                data[key] = value;
        }
        return Promise.resolve({ ok: true });
    }));
    vi.spyOn(window, "setInterval").mockImplementation(() => 1);
    table = { dynamicTableDiv: document.getElementById("table"), updateTable: vi.fn(), selectedRowsIds: () => [hashA] };
    await import("../../private/scripts/manual-groups.js");
    groups = window.qBittorrent.ManualGroups;
    groups.init(table);
    await vi.waitFor(() => expect(table.updateTable).toHaveBeenCalled());
});

afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
});

test("groups manually selected torrents across paths without adding selectable header IDs", () => {
    const layout = groups.layout([row(hashA, "/one"), row(hashB, "/two"), row("c".repeat(40), "/one")]);
    expect(layout.display).toHaveLength(2);
    expect(layout.display[0].members).toHaveLength(2);
    expect(layout.selectable.map(item => item.rowId)).toEqual(["c".repeat(40)]);
});

test("filtering excludes unmatched members from totals and display", () => {
    const layout = groups.layout([row(hashB, "/two")]);
    expect(layout.display[0].members).toHaveLength(1);
    expect(groups.layout([]).display).toEqual([]);
});

test("header toggle expands members in their sorted order", () => {
    const rows = [row(hashB, "/two"), row(hashA, "/one")];
    const tr = document.createElement("tr");
    tr.append(document.createElement("td"));
    table.dynamicTableDiv.append(tr);
    groups.render(tr, groups.layout(rows).display[0], [{ name: "name", visible: "1" }], false);
    tr.querySelector("button").click();
    expect(groups.layout(rows).selectable.map(item => item.rowId)).toEqual([hashB, hashA]);
    expect(table.selectedRowsIds()).toEqual([hashA]);
});

test("saving only changes selected membership keys and preserves unrelated client data", async () => {
    document.getElementById("manualGroupButton").click();
    await vi.waitFor(() => expect(document.querySelector("dialog")).not.toBeNull());
    document.querySelector("dialog input").value = "New series";
    document.querySelector("dialog button").click();
    await vi.waitFor(() => expect(data[`qbt_manual_group_${hashA}`]).toBe("New series"));
    expect(data[`qbt_manual_group_${hashB}`]).toBe("Series");
    expect(data.qbt_unrelated).toBe("keep");
});

test("failed writes keep membership and dialog intact", async () => {
    document.getElementById("manualGroupButton").click();
    await vi.waitFor(() => expect(document.querySelector("dialog")).not.toBeNull());
    failSave = true;
    document.querySelector("dialog input").value = "New series";
    document.querySelector("dialog button").click();
    await vi.waitFor(() => expect(document.querySelector('[role="alert"]').textContent).toContain("409"));
    expect(data[`qbt_manual_group_${hashA}`]).toBe("Series");
    expect(groups.layout([row(hashA, "/one")]).display[0].groupName).toBe("Series");
});
