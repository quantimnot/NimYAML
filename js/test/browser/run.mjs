#!/usr/bin/env node
// The server worker in a real browser, with real OPFS: serves js/ over
// HTTP on a free port (module workers and OPFS need an origin, and
// localhost is a secure one), opens page.mjs's page in headless Chromium
// twice with one profile, and checks what the pages report.
//
// The browser is $CHROMIUM, else the first of chromium, chromium-browser,
// google-chrome and chrome on PATH, else Chromium or Google Chrome where
// macOS installs applications. Without one the test is skipped (exit 0,
// with a message), since a browser is not a dependency of the build.
//
//   node js/test/browser/run.mjs

import { createServer } from "node:http";
import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = fileURLToPath(new URL("../../", import.meta.url));
const types = { ".mjs": "text/javascript", ".js": "text/javascript",
                ".html": "text/html" };

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

const browser = findBrowser();
if (!browser) {
  console.log("browser test skipped: no Chromium (set $CHROMIUM)");
  process.exit(0);
}

let deliver = null;
const server = createServer((req, res) => {
  if (req.method === "POST" && req.url === "/result") {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => { res.end(); deliver?.(JSON.parse(body)); });
    return;
  }
  const path = new URL(req.url, "http://x").pathname;
  if (path === "/") {
    res.setHeader("content-type", "text/html");
    res.end('<!doctype html><script type="module" src="/test/browser/page.mjs' +
      `?${new URL(req.url, "http://x").searchParams}"></script>`);
    return;
  }
  const file = normalize(join(root, path));
  if (!file.startsWith(root) || !existsSync(file)) { res.statusCode = 404; res.end(); return; }
  res.setHeader("content-type", types[extname(file)] ?? "application/octet-stream");
  res.end(readFileSync(file));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const profile = mkdtempSync(join(tmpdir(), "nimyaml-browser-"));

async function visit(phase) {
  const result = new Promise((resolve) => { deliver = resolve; });
  const child = spawn(browser, ["--headless=new", "--no-first-run",
    "--no-default-browser-check", `--user-data-dir=${profile}`,
    `http://127.0.0.1:${port}/?phase=${phase}`], { stdio: "ignore" });
  const timeout = setTimeout(() => deliver?.({ error: `${phase}: no report in 60 s` }), 60000);
  const report = await result;
  clearTimeout(timeout);
  child.kill();
  await new Promise((resolve) => child.on("exit", resolve));
  if (report.error) throw new Error(report.error);
  return report;
}

try {
  const saved = await visit("save");
  assert.deepEqual(saved.restored, []);
  assert.ok(saved.initialized);
  // published twice: before and after the page's config arrived
  assert.equal(saved.diagnostics.at(-1)[0].severity, 1);
  const { restored } = await visit("restore");
  const texts = Object.fromEntries(restored.map((d) => [d.uri, d.text]));
  assert.deepEqual(texts, {
    "file:///p/debounced.yaml": "k: yes\nsaved: by the debounce\n",
    "untitled:flushed": "a: 1\nsaved: by the flush\n",
  });
  console.log("browser test passed:", browser);
} finally {
  server.close();
  rmSync(profile, { recursive: true, force: true });
}
