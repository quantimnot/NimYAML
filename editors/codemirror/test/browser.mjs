#!/usr/bin/env node
// The demo page in a real browser: serves it as serve.mjs does, opens it with
// ?test in headless Chromium, and fails unless every check of test/checks.js
// holds — diagnostics, highlighting, links, the cursor's path, schema edits,
// formatting and schema inference, from the worker's server through
// lsp-client into <code-editor>.
//
//   UI_COMPONENTS=../ui-web-component/packages/ui-components node editors/codemirror/test/browser.mjs
//
// It needs js/dist/nimyaml.mjs (node js/build.mjs) and the component's
// codemirror.js (ninja, in the collection's code-editor/). The browser is
// $CHROMIUM, else the first Chromium or Chrome found as js/test/browser/run.mjs
// finds one. Without a browser or a collection the test is skipped (exit 0,
// with a message): neither is a dependency of NimYAML.

import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serve } from "../serve.mjs";

function findBrowser() {
  if (process.env.CHROMIUM) return process.env.CHROMIUM;
  for (const name of ["chromium", "chromium-browser", "google-chrome", "chrome"]) {
    try { return execFileSync("which", [name], { encoding: "utf8" }).trim(); }
    catch { /* not on PATH */ }
  }
  for (const app of ["/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]) {
    if (existsSync(app)) return app;
  }
  return null;
}

const argAt = process.argv.indexOf("--components");
const components = argAt > 0 ? process.argv[argAt + 1] : process.env.UI_COMPONENTS;
const browser = findBrowser();
if (!components || !browser) {
  console.log(`browser test skipped: ${!components
    ? "no component collection (set UI_COMPONENTS)" : "no Chromium (set $CHROMIUM)"}`);
  process.exit(0);
}
if (!existsSync(join(components, "code-editor", "codemirror.js"))) {
  console.error(`${components}/code-editor/codemirror.js is missing: build it with ninja there`);
  process.exit(1);
}

let deliver;
const reported = new Promise((resolve) => { deliver = resolve; });
const server = await serve({
  components,
  answer(req, res) {
    if (req.method !== "POST" || req.url !== "/result") return false;
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => { res.end(); deliver(JSON.parse(body)); });
    return true;
  },
});
const profile = mkdtempSync(join(tmpdir(), "yamllsp-codemirror-"));
const child = spawn(browser, ["--headless=new", "--no-first-run", "--no-default-browser-check",
  `--user-data-dir=${profile}`, `${server.url}?test`], { stdio: "ignore" });
const timeout = setTimeout(() =>
  deliver([{ name: "the page reports within 120 s", ok: false }]), 120000);

let failed = 0;
try {
  for (const { name, ok, detail } of await reported) {
    console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
    if (!ok) failed++;
  }
} finally {
  clearTimeout(timeout);
  child.kill();
  server.close();
  await new Promise((resolve) => child.on("exit", resolve));
  rmSync(profile, { recursive: true, force: true });
}
console.log(failed ? `${failed} check(s) failed` : `browser test passed: ${browser}`);
process.exit(failed ? 1 : 0);
