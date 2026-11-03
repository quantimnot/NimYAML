#!/usr/bin/env node
// Serves the demo page (index.html) with what it is made of, at the URLs it
// asks for them by:
//
//   /           this folder: the page, demo.js and yamllsp.js
//   /nimyaml/   js/, NimYAML compiled to JavaScript and its server worker
//               (build js/dist/nimyaml.mjs first: node js/build.mjs)
//   /ui/        the web component collection <code-editor> belongs to: its
//               folder, then the framework beneath it (node_modules/webcomponents),
//               which is how that collection's own server stacks them
//
// The collection is not part of this repository, so where it is comes from
// the command line or the environment, never from this file:
//
//   node editors/codemirror/serve.mjs --components ../ui-web-component/packages/ui-components
//   UI_COMPONENTS=... node editors/codemirror/serve.mjs [--port 8080]
//
// Module workers need http:, not file:, and 127.0.0.1 is a secure origin, so
// OPFS works too. `serve` is also what the browser test (test/browser.mjs) runs.
//
// Rejected: copying the component into this folder, a second copy that goes
// stale; the collection's own server, which knows nothing of /nimyaml/.

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
                ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml",
                ".yaml": "text/yaml", ".png": "image/png" };

/** The folders a URL prefix is answered from, first match wins. */
export function mounts(components) {
  const ui = resolve(components);
  return [
    { at: "/nimyaml/", folders: [resolve(here, "../../js")] },
    { at: "/ui/", folders: [ui, join(ui, "node_modules", "webcomponents")] },
    { at: "/", folders: [here] },
  ];
}

async function fileFor(table, urlPath) {
  const path = decodeURIComponent(urlPath.split("?")[0]);
  const mount = table.find(({ at }) => path.startsWith(at));
  const relative = path.slice(mount.at.length) || "index.html";
  for (const folder of mount.folders) {
    const file = resolve(folder, relative);
    if (file !== folder && !file.startsWith(folder + sep)) return null;   // ../ out of it
    try { if ((await stat(file)).isFile()) return file; } catch { /* not in this one */ }
  }
  return null;
}

/**
 * Starts the server on `port` (0: a free one) and resolves to it, with `url`.
 * `answer(req, res)` may handle a request first, returning true if it did.
 */
export async function serve({ components, port = 0, answer = () => false }) {
  const table = mounts(components);
  const server = createServer(async (req, res) => {
    if (await answer(req, res)) return;
    const file = await fileFor(table, new URL(req.url, "http://x").pathname);
    if (!file) { res.statusCode = 404; res.end(); return; }
    res.setHeader("content-type", types[extname(file)] ?? "application/octet-stream");
    res.end(await readFile(file));
  });
  await new Promise((done) => server.listen(port, "127.0.0.1", done));
  server.url = `http://127.0.0.1:${server.address().port}/`;
  return server;
}

function option(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const components = option("components") ?? process.env.UI_COMPONENTS;
  if (!components) {
    console.error("usage: serve.mjs --components DIR [--port N]   (or set UI_COMPONENTS)\n" +
      "DIR is the web component collection that has code-editor/ in it.");
    process.exit(2);
  }
  const server = await serve({ components, port: Number(option("port") ?? 0) });
  console.log(`yamllsp for CodeMirror: ${server.url}`);
}
