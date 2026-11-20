/* SPDX-License-Identifier: GPL-2.0-or-later */
import { expect, test } from "vitest";
import { readFileSync } from "node:fs";

test("group translations cover every message and preserve count placeholders", () => {
    const source = readFileSync("private/scripts/manual-groups.js", "utf8");
    const messages = [...new Set([...source.matchAll(/QBT_TR\((.*?)\)QBT_TR\[CONTEXT=ManualGroups\]/g)].map(match => match[1]))];
    for (const locale of ["de", "en", "en_AU", "en_GB", "es", "fr", "ja", "ko", "pt_BR", "ru", "zh_CN", "zh_HK", "zh_TW"]) {
        const xml = readFileSync(`translations/webui_${locale}.ts`, "utf8");
        const document = new DOMParser().parseFromString(xml, "text/xml");
        expect(document.querySelector("parsererror")).toBeNull();
        const context = [...document.querySelectorAll("context")].find(element => element.querySelector("name").textContent === "ManualGroups");
        const translations = new Map([...context.querySelectorAll("message")].map(message => [message.querySelector("source").textContent, message.querySelector("translation").textContent]));
        for (const message of messages) {
            expect(translations.get(message), `${locale}: ${message}`).toBeTruthy();
            expect(translations.get(message).includes("%1")).toBe(message.includes("%1"));
        }
    }
});
