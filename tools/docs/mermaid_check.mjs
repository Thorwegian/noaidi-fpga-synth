// mermaid_check.mjs — parse every Mermaid graph in the given Markdown files
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// GitHub renders Mermaid in the browser, so a graph with a syntax error
// (a pipe in a label, an unquoted bracket) is found by the reader, not
// the author. This runs the same parser ahead of the commit:
//
//     npm install --no-save mermaid jsdom     (once, in the repository's root:
//                                              node_modules there is ignored)
//     node tools/docs/mermaid_check.mjs docs/*.md
//
// Exit status is the number of graphs that failed; each failure prints
// the file, the graph's ordinal in it and the parser's first lines.

import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
for (const name of ["Element", "HTMLElement", "SVGElement", "Node", "DocumentFragment", "navigator"]) {
    try {
        globalThis[name] = dom.window[name];
    } catch {
        // a read-only global on this Node: the parser does without it
    }
}

const mermaid = (await import("mermaid")).default;
mermaid.initialize({ startOnLoad: false });

const GRAPH = /```mermaid\n([\s\S]*?)```/g;
let failures = 0;

for (const file of process.argv.slice(2)) {
    const text = readFileSync(file, "utf8");
    const graphs = [...text.matchAll(GRAPH)].map((match) => match[1]);
    for (const [index, graph] of graphs.entries()) {
        try {
            await mermaid.parse(graph);
            console.log(`${file} graph ${index + 1}: ok`);
        } catch (error) {
            failures += 1;
            const reason = String(error.message).split("\n").slice(0, 3).join(" / ");
            console.log(`${file} graph ${index + 1}: ERROR ${reason}`);
        }
    }
}

process.exit(failures);
