/* SPDX-License-Identifier: GPL-2.0-or-later */
import { afterEach, beforeEach, expect, test, vi } from "vitest";

const hashes = "abcdef".split("").map(letter => letter.repeat(40));
const groupId = path => `manual-group:${JSON.stringify(path)}`;
let table;

beforeEach(async () => {
    vi.resetModules();
    document.body.innerHTML = '<button id="preferencesButton"></button><input id="torrentsFilterInput"><input id="torrentsFilterRegexBox" type="checkbox"><div id="table"><table><tbody></tbody></table></div>';
    window.qBittorrent = {
        LocalPreferences: { LocalPreferences: class {} },
        Misc: { friendlyUnit: String }
    };
    for (const key of ["selectedStatus", "selectedCategory", "selectedTag", "selectedTracker"])
        vi.stubGlobal(key, "");
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve({
        ok: true,
        json: () => Promise.resolve({
            [`qbt_manual_group_${hashes[1]}`]: ["Series", "Season"],
            [`qbt_manual_group_${hashes[3]}`]: ["Series", "Season"],
            [`qbt_manual_group_${hashes[4]}`]: "Series"
        })
    })));
    vi.spyOn(window, "setInterval").mockImplementation(() => 1);
    await import("../../private/scripts/manual-groups.js");
    await import("../../private/scripts/dynamicTable.js");
    table = new window.qBittorrent.DynamicTable.TorrentsTable();
    // Replace only the legacy MooTools Array helpers in this DOM test environment.
    const base = Object.getPrototypeOf(Object.getPrototypeOf(table));
    vi.spyOn(base, "deselectAll").mockImplementation(function() { this.selectedRows = []; });
    vi.spyOn(base, "isRowSelected").mockImplementation(function(id) { return this.selectedRows.includes(id); });
    table.dynamicTableDiv = document.getElementById("table");
    table.tableBody = document.querySelector("tbody");
    table.selectedRows = [];
    table.rows = new Map(hashes.map((rowId, index) => [rowId, { rowId: rowId, full_data: { name: String(index), size: 10 }, data: {} }]));
    table.columns = [{ name: "name", visible: "1", compareRows: (a, b) => a.full_data.name.localeCompare(b.full_data.name), dataProperties: ["name"], updateTd: (td, row) => { td.textContent = row.full_data.name; } }];
    table.sortedColumn = 0;
    table.reverseSort = "0";
    table.applyFilter = (row, status, category, tag, tracker, terms) => !terms || terms.includes(row.full_data.name);
    table.onSelectedRowChanged = vi.fn();
    window.qBittorrent.ManualGroups.init(table);
    await vi.waitFor(() => expect(table.getDisplayRows()).toHaveLength(4));
});

afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
});

const select = (id, modifiers = {}) => table.selectRowFromEvent(id, modifiers);
const expectSelection = ids => expect(table.selectedRowsIds()).toEqual(ids);
const header = () => table.getTrByRowId(groupId(["Series"]));

test("select all includes collapsed descendants exactly once in grouped visual order", () => {
    table.selectAll();
    expectSelection([hashes[0], hashes[1], hashes[3], hashes[4], hashes[2], hashes[5]]);
    expect(header().classList.contains("selected")).toBe(true);
    expect(header().querySelector(".manualGroupSelectionCount").textContent).toBe("3/3");
    expect(table.onSelectedRowChanged).toHaveBeenCalled();
});

test("shift crosses collapsed groups in both directions and keeps its anchor", () => {
    select(hashes[0]);
    select(hashes[5], { shiftKey: true });
    expect(table.selectedRowsIds()).toHaveLength(6);
    select(hashes[2], { shiftKey: true });
    expectSelection([hashes[0], hashes[1], hashes[3], hashes[4], hashes[2]]);
    select(hashes[5]);
    select(hashes[0], { shiftKey: true });
    expect(table.selectedRowsIds()).toHaveLength(6);
});

test("a group can be either end of a shift range without exposing synthetic IDs", () => {
    select(groupId(["Series"]));
    expectSelection([hashes[1], hashes[3], hashes[4]]);
    select(hashes[2], { shiftKey: true });
    expectSelection([hashes[1], hashes[3], hashes[4], hashes[2]]);
    select(hashes[0]);
    select(groupId(["Series"]), { shiftKey: true });
    expectSelection([hashes[0], hashes[1], hashes[3], hashes[4]]);
});

test("control or command toggles all group members without duplicates", () => {
    select(hashes[1]);
    expect(header().classList.contains("manualGroupPartialSelection")).toBe(true);
    header().querySelector("button").dispatchEvent(new MouseEvent("click", { bubbles: true, ctrlKey: true }));
    expectSelection([hashes[1], hashes[3], hashes[4]]);
    expect(header().querySelector("button").getAttribute("aria-expanded")).toBe("false");
    select(groupId(["Series"]), { metaKey: true });
    expectSelection([]);
    expect(header().querySelector(".manualGroupSelectionCount").hidden).toBe(true);
});

test("collapse and expansion retain hidden selections and nested partial indicators", () => {
    select(hashes[1]);
    header().querySelector("button").click();
    expect(table.getTrByRowId(groupId(["Series", "Season"])).classList.contains("manualGroupPartialSelection")).toBe(true);
    table.getTrByRowId(groupId(["Series", "Season"])).querySelector("button").click();
    expect(table.getTrByRowId(hashes[1]).classList.contains("selected")).toBe(true);
    header().querySelector("button").click();
    expectSelection([hashes[1]]);
    expect(header().querySelector(".manualGroupSelectionCount").textContent).toBe("1/3");
});

test("filtering prunes excluded members and limits select all and group ranges", () => {
    table.selectAll();
    document.getElementById("torrentsFilterInput").value = "0 3";
    table.updateTable();
    expectSelection([hashes[0], hashes[3]]);
    table.selectAll();
    expectSelection([hashes[0], hashes[3]]);
    select(groupId(["Series"]));
    expectSelection([hashes[3]]);
    document.getElementById("torrentsFilterRegexBox").checked = true;
    document.getElementById("torrentsFilterInput").value = "[";
    table.updateTable();
    table.selectAll();
    expectSelection([]);
});

test("additive shift includes the entire nested endpoint and preserves other selections", () => {
    select(hashes[5]);
    select(hashes[0], { ctrlKey: true });
    select(groupId(["Series", "Season"]), { ctrlKey: true, shiftKey: true });
    expectSelection([hashes[5], hashes[0], hashes[1], hashes[3]]);
});

test("reverse sorting recomputes ranges and virtual row recycling clears group selection state", () => {
    table.reverseSort = "1";
    table.updateTable();
    select(hashes[5]);
    select(groupId(["Series"]), { shiftKey: true });
    expectSelection([hashes[5], hashes[4], hashes[3], hashes[1]]);
    const tr = header();
    table.updateRowElement(tr, hashes[2]);
    table.updateRow(tr, true);
    expect(tr.dataset.displayOnly).toBeUndefined();
    expect(tr.hasAttribute("aria-selected")).toBe(false);
    expect(tr.querySelector(".manualGroupSelectionCount")).toBeNull();
});
