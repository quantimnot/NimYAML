#!/usr/bin/env node
// Builds dist/nimyaml.mjs, the compiled NimYAML that the modules of js/
// import.
//
// The Nim compiler's JavaScript backend writes a classic script: top-level
// functions and variables, nothing exported. The build compiles
// js/nimyaml_js.nim and makes the script the body of a function, which
// returns the functions named nimyaml_X, the names nimyaml_js.nim reserves
// for what it exports; the module exports each as X. The list is read from
// the output rather than kept here, so that a proc added there is exported
// without touching this file. The function, rather than the module's own
// top level, holds the script because a module's top level is stricter
// than a script's: the compiler may declare a function twice (a debug
// build does), which a script and a function body allow and a module's top
// level does not. The code is strict either way, as a module's is; the
// tests run it, so a violation fails them.
//
// Nim is found on PATH, or named by $NIM. The output goes to js/dist/,
// which is not committed: it is built from the sources like any binary.
// Pass --debug for a build without -d:release, with Nim's stack traces.
//
// Rejected: a bundler, which would add a dependency to do what one regular
// expression does; one compiled module per tool, which would carry the
// library once per tool (the yaml command contains the others anyway).

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, "dist");
const debug = process.argv.includes("--debug");

const work = mkdtempSync(join(tmpdir(), "nimyaml-js-"));
try {
  const script = join(work, "nimyaml.js");
  execFileSync(process.env.NIM || "nim", [
    "js", ...(debug ? [] : ["-d:release"]), "--hints:off", "--warnings:off",
    `--nimcache:${join(work, "cache")}`, `-o:${script}`,
    join(here, "nimyaml_js.nim"),
  ], { stdio: "inherit" });

  const code = readFileSync(script, "utf8");
  const names = [...new Set(
    [...code.matchAll(/^function (nimyaml_(\w+))\(/gm)].map((m) => m[1]))];
  if (names.length === 0) throw new Error("the build exports nothing");
  const short = (n) => n.slice("nimyaml_".length);
  const module = [
    "const nimyaml = (function () {",
    code,
    `return { ${names.map((n) => `${short(n)}: ${n}`).join(", ")} };`,
    "})();",
    ...names.map((n) => `export const ${short(n)} = nimyaml.${short(n)};`),
    "",
  ].join("\n");

  mkdirSync(dist, { recursive: true });
  writeFileSync(join(dist, "nimyaml.mjs"), module);
  const kb = (n) => `${(n / 1024).toFixed(0)} KB`;
  console.log(`dist/nimyaml.mjs: ${kb(module.length)}, ` +
    `${kb(gzipSync(module).length)} gzipped, ${names.length} exports`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
