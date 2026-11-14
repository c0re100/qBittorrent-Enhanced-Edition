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
    data = {
        [`qbt_manual_group_${hashA}`]: "Series", [`qbt_manual_group_${hashB}`]: "Series", qbt_unrelated: "keep" };
    failSave = false;
    window.qBittorrent = {
        Misc: { friendlyUnit: String },
        Dialog: { baseModalOptions: { addClass: "modalDialog" }, limitHeightToViewport: height => height }
    };
    vi.stubGlobal("MochaUI", {
        resizeWindow: vi.fn(),
        centerWindow: vi.fn(),
        Modal: class {
            constructor(options) {
                this.element = document.createElement("div");
                this.element.id = options.id;
                this.element.className = options.addClass;
                this.element.append(options.content);
                document.body.append(this.element);
                options.onContentLoaded();
            }

            close() {
                this.element.remove();
            }
        }
    });
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
    expect(layout.selectable.map(item => item.rowId)).toEqual([hashA, hashB, "c".repeat(40)]);
    expect(layout.ranges.get(layout.display[0].rowId)).toEqual({ start: 0, end: 2 });
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
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
    document.getElementById("manualGroupDestination").value = "";
    document.getElementById("manualGroupDestination").dispatchEvent(new Event("change"));
    document.querySelector(".manualGroupsDialog input").value = "New series";
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(data[`qbt_manual_group_${hashA}`]).toBe("New series"));
    expect(data[`qbt_manual_group_${hashB}`]).toBe("Series");
    expect(data.qbt_unrelated).toBe("keep");
});

test("failed writes keep membership and dialog intact", async () => {
    document.getElementById("manualGroupButton").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
    failSave = true;
    document.getElementById("manualGroupDestination").value = "";
    document.getElementById("manualGroupDestination").dispatchEvent(new Event("change"));
    document.querySelector(".manualGroupsDialog input").value = "New series";
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(document.querySelector('[role="alert"]').textContent).toContain("409"));
    expect(data[`qbt_manual_group_${hashA}`]).toBe("Series");
    expect(groups.layout([row(hashA, "/one")]).display[0].groupName).toBe("Series");
});

const refreshFixture = async () => {
    document.getElementById("manualGroupButton").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
    document.querySelectorAll(".manualGroupsDialog button")[2].click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).toBeNull());
};

const renderHeader = (header) => {
    const tr = document.createElement("tr");
    tr.append(document.createElement("td"));
    table.dynamicTableDiv.append(tr);
    groups.render(tr, header, [{ name: "name", visible: "1" }], false);
    return tr;
};

const manageRoot = async (rows) => {
    const header = groups.layout(rows).display[0];
    renderHeader(header).querySelectorAll("button")[1].click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
};

test("moves an existing group under another without changing other memberships", async () => {
    data[`qbt_manual_group_${"c".repeat(40)}`] = "Library";
    await refreshFixture();
    await manageRoot([row(hashA, "/one"), row(hashB, "/two")]);
    document.querySelector("#manualGroupParent").value = JSON.stringify(["Library"]);
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(data[`qbt_manual_group_${hashA}`]).toEqual(["Library", "Series"]));
    expect(data[`qbt_manual_group_${hashB}`]).toEqual(["Library", "Series"]);
    expect(data[`qbt_manual_group_${"c".repeat(40)}`]).toBe("Library");
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).toBeNull());
    expect(groups.layout([row(hashA, "/one")]).display[0].groupName).toBe("Library");
});

test("expands every level separately and counts descendants once", async () => {
    data[`qbt_manual_group_${hashA}`] = ["Library", "Series", "Season"];
    data[`qbt_manual_group_${hashB}`] = ["Library", "Series"];
    await refreshFixture();
    const rows = [row(hashA, "/one"), row(hashB, "/two")];
    let result = groups.layout(rows);
    expect(result.display).toHaveLength(1);
    expect(result.display[0].members).toHaveLength(2);
    renderHeader(result.display[0]).querySelector("button").click();
    result = groups.layout(rows);
    expect(result.display).toHaveLength(2);
    expect(result.selectable.map(item => item.rowId)).toEqual([hashA, hashB]);
    renderHeader(result.display[1]).querySelector("button").click();
    result = groups.layout(rows);
    expect(result.selectable.map(item => item.rowId)).toEqual([hashA, hashB]);
    expect(result.depths.get(hashB)).toBe(2);
    renderHeader(result.display[2]).querySelector("button").click();
    expect(groups.layout(rows).depths.get(hashA)).toBe(3);
});

test("rejects moving a group into itself or a descendant, even if the form is tampered with", async () => {
    data[`qbt_manual_group_${hashA}`] = ["Series", "Season"];
    await refreshFixture();
    await manageRoot([row(hashA, "/one"), row(hashB, "/two")]);
    const option = [...document.querySelector("#manualGroupParent").options].find(item => item.value === JSON.stringify(["Series", "Season"]));
    expect(option.disabled).toBe(true);
    option.disabled = false;
    option.selected = true;
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(document.querySelector('[role="alert"]').textContent).toContain("descendants"));
    expect(data[`qbt_manual_group_${hashA}`]).toEqual(["Series", "Season"]);
    expect(fetch.mock.calls.filter(([url]) => url.endsWith("store"))).toHaveLength(0);
});

test("moving a subtree preserves its descendants and dissolving promotes one level", async () => {
    data[`qbt_manual_group_${hashA}`] = ["Series", "Season"];
    data[`qbt_manual_group_${"c".repeat(40)}`] = "Library";
    await refreshFixture();
    const rows = [row(hashA, "/one"), row(hashB, "/two")];
    await manageRoot(rows);
    document.querySelector("#manualGroupParent").value = JSON.stringify(["Library"]);
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).toBeNull());
    expect(data[`qbt_manual_group_${hashA}`]).toEqual(["Library", "Series", "Season"]);
    await manageRoot(rows);
    document.querySelectorAll(".manualGroupsDialog button")[1].click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).toBeNull());
    expect(data[`qbt_manual_group_${hashA}`]).toEqual(["Series", "Season"]);
    expect(data[`qbt_manual_group_${hashB}`]).toBe("Series");
    expect(data[`qbt_manual_group_${"c".repeat(40)}`]).toBeUndefined();
});

test("legacy names with slashes remain single groups", async () => {
    data[`qbt_manual_group_${hashA}`] = "Literal / name";
    await refreshFixture();
    expect(groups.layout([row(hashA, "/one")]).display[0].groupPath).toEqual(["Literal / name"]);
});

test("moving back to top level and merging preserves descendant groups", async () => {
    data[`qbt_manual_group_${hashA}`] = ["Parent", "Series", "Season"];
    data[`qbt_manual_group_${hashB}`] = "Target";
    await refreshFixture();
    const rows = [row(hashA, "/one"), row(hashB, "/two")];
    renderHeader(groups.layout(rows).display[0]).querySelector("button").click();
    const child = groups.layout(rows).display.find(item => item.groupName === "Series");
    renderHeader(child).querySelectorAll("button")[1].click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
    document.getElementById("manualGroupDestination").value = JSON.stringify(["Target"]);
    document.getElementById("manualGroupDestination").dispatchEvent(new Event("change"));
    expect(document.getElementById("manualGroupFields").hidden).toBe(true);
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).toBeNull());
    expect(data[`qbt_manual_group_${hashA}`]).toEqual(["Target", "Season"]);
    expect(data[`qbt_manual_group_${hashB}`]).toBe("Target");
    const filtered = groups.layout([row(hashA, "/one")]);
    expect(filtered.display[0].members).toHaveLength(1);
});

test("rejects depth overflow without persisting a partial subtree", async () => {
    data[`qbt_manual_group_${hashA}`] = Array.from({ length: 32 }, (_, index) => `Level ${index}`);
    data[`qbt_manual_group_${hashB}`] = "Target";
    await refreshFixture();
    await manageRoot([row(hashA, "/one"), row(hashB, "/two")]);
    document.querySelector("#manualGroupParent").value = JSON.stringify(["Target"]);
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(document.querySelector('[role="alert"]').textContent).toContain("32"));
    expect(data[`qbt_manual_group_${hashA}`]).toHaveLength(32);
    expect(fetch.mock.calls.filter(([url]) => url.endsWith("store"))).toHaveLength(0);
});

test("chooses an existing nested destination without typing, distinguishing equal leaf names", async () => {
    data[`qbt_manual_group_${hashB}`] = ["Library", "Series"];
    document.getElementById("manualGroupButton").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
    const select = document.getElementById("manualGroupDestination");
    expect([...select.options].map(option => option.textContent)).toContain("Library / Series");
    select.value = JSON.stringify(["Library", "Series"]);
    select.dispatchEvent(new Event("change"));
    expect(document.getElementById("manualGroupFields").hidden).toBe(true);
    document.querySelector(".manualGroupsDialog button").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).toBeNull());
    expect(data[`qbt_manual_group_${hashA}`]).toEqual(["Library", "Series"]);
    expect(data[`qbt_manual_group_${hashB}`]).toEqual(["Library", "Series"]);
});

test("uses the shared modal, contains keyboard shortcuts and closes without saving on Escape", async () => {
    document.getElementById("manualGroupButton").click();
    await vi.waitFor(() => expect(document.querySelector(".manualGroupsDialog")).not.toBeNull());
    expect(document.getElementById("manualGroupsPage").classList.contains("manualGroupsWindow")).toBe(true);
    const shortcut = vi.fn();
    document.body.addEventListener("keydown", shortcut);
    try {
        const select = document.getElementById("manualGroupDestination");
        select.dispatchEvent(new KeyboardEvent("keydown", { key: "Delete", bubbles: true }));
        expect(shortcut).not.toHaveBeenCalled();
        select.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        expect(document.querySelector(".manualGroupsDialog")).toBeNull();
        expect(fetch.mock.calls.filter(([url]) => url.endsWith("store"))).toHaveLength(0);
    }
    finally {
        document.body.removeEventListener("keydown", shortcut);
    }
});
