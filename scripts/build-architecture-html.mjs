#!/usr/bin/env node
// Builds site/architecture.html — a self-contained interactive architecture map
// — by inlining site/architecture-graph.json into site/architecture.template.html.
//
//   node scripts/build-architecture-html.mjs
//
// The graph JSON is the same shape Understand Anything's /understand emits; you
// can regenerate it any time and re-run this to refresh the committed artifact.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tpl = readFileSync(join(root, "site/architecture.template.html"), "utf-8");
const graph = JSON.parse(readFileSync(join(root, "site/architecture-graph.json"), "utf-8"));

const out = tpl.replace("/*__GRAPH_DATA__*/ {}", JSON.stringify(graph));
if (out === tpl) { console.error("ERROR: data placeholder not found in template"); process.exit(1); }

writeFileSync(join(root, "site/architecture.html"), out);
console.log(`built site/architecture.html — ${graph.nodes.length} nodes, ${graph.edges.length} edges, ${(out.length/1024).toFixed(0)}KB`);
