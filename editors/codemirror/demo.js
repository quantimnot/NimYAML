// The demo page's wiring: a project of three YAML files, edited in
// <code-editor>s and checked by yamllsp in a worker.
//
// The project lives in this page, in `files`, a map from path to text, as an
// application would keep its documents in memory or behind its own storage.
// The worker has no file system of its own (js/lsp/server-worker.mjs): when the
// server needs a file — the config beside a document, a `%SCHEMA` it names —
// it asks, and readFile answers from the map. Each file has an editor of its
// own, made the first time it is shown and hidden while another is: one view
// per document is what lsp-client's workspace allows, and an editor kept is
// an undo history kept.
//
// The server reads a file once and keeps it. So a change to any file is
// posted to the worker as well, a moment after the typing stops: config.yaml
// is validated against schema.yaml as it is being written, and editing the
// lint config changes the diagnostics of every document.
//
// Links between files (the `%SCHEMA schema.yaml` of config.yaml, opened with
// Ctrl/Cmd+click) open the file in its editor; links to the web open a tab.

import * as cm from "/ui/code-editor/codemirror.js";
import { startServer } from "/nimyaml/lsp/transport.mjs";
import { yamlLanguageServer } from "./yamllsp.js";

const ROOT = "file:///project/";

const files = new Map(Object.entries({
  "/project/config.yaml": `%SCHEMA schema.yaml
---
# A service, checked against schema.yaml and linted by .nimyaml-lint.yaml.
# Ctrl/Cmd+click the schema's name above to open it; Shift+Alt+F formats.
name: inventory
port: 80800        # the schema allows at most 65535
enabled: yes       # a string in YAML 1.2, which the lint config makes an error
replicas: 3
tags: [api,   internal]
owner: &team platform
backup: *team
`,
  "/project/schema.yaml": `$schema: https://json-schema.org/draft/2020-12/schema
title: service
type: object
required: [name, port]
properties:
  name: {type: string}
  port: {type: integer, minimum: 1, maximum: 65535}
  enabled: {type: boolean}
  replicas: {type: integer, minimum: 1}
  tags: {type: array, items: {type: string}}
`,
  "/project/.nimyaml-lint.yaml": `# The config of the files beside it: lint rules, validation and format.
rules:
  truthy: {level: error}
`,
}));

const pathOf = (uri) => decodeURIComponent(new URL(uri).pathname);
const uriOf = (path) => new URL(path.replace(/^\//, ""), "file:///").href;

// The path panel's format is the reader's choice, kept in this browser.
const FORMAT_KEY = "yamllsp-demo.pathFormat";
const storage = {
  get: () => { try { return localStorage.getItem(FORMAT_KEY); } catch { return null; } },
  set: (format) => { try { localStorage.setItem(FORMAT_KEY, format); } catch { /* not kept */ } },
};

const server = startServer({ readFile: async (path) => files.get(path) ?? null });
const status = document.getElementById("status");
const yaml = yamlLanguageServer({
  cm, transport: server.transport, rootUri: ROOT,
  pathFormat: storage.get() ?? "pointer",
  onPathFormatChange: storage.set,
  openLink: (target) => {
    if (target.startsWith("file:") && files.has(pathOf(target))) show(pathOf(target));
    else if (/^https?:/.test(target)) open(target, "_blank", "noopener");
  },
});
yaml.client.initializing.then(() => { status.textContent = "server ready"; },
  (e) => { status.textContent = `server failed: ${e.message ?? e}`; });

await customElements.whenDefined("code-editor");

const nav = document.getElementById("files");
const main = document.getElementById("editors");
const editors = new Map();   // path → <code-editor>
let current = null;

function fileButton(path) {
  const button = document.createElement("button");
  // a file name reads in its own direction (".yaml" keeps its dot first),
  // isolated so that the button keeps the page's alignment
  const name = document.createElement("bdi");
  name.textContent = path.slice("/project/".length);
  button.append(name);
  button.dataset.path = path;
  button.addEventListener("click", () => show(path));
  nav.append(button);
}

// Posted to the worker a moment after the last keystroke, for the server to
// read the file again (the documents open in it get their didChange anyway).
const pendingPosts = new Map();
function changed(path, text) {
  files.set(path, text);
  clearTimeout(pendingPosts.get(path));
  pendingPosts.set(path, setTimeout(() => {
    server.worker.postMessage({ files: { [path]: files.get(path) } });
  }, 400));
}

function editorFor(path) {
  if (editors.has(path)) return editors.get(path);
  const editor = document.createElement("code-editor");
  editor.setAttribute("language", "yaml");
  editor.setAttribute("label", path);
  editor.value = files.get(path);
  editor.extensions = yaml.extensions(uriOf(path));
  editor.addEventListener("valuechange", (e) => changed(path, e.detail.value));
  editors.set(path, editor);
  main.append(editor);
  return editor;
}

function show(path) {
  for (const [other, editor] of editors) editor.hidden = other !== path;
  editorFor(path).hidden = false;
  for (const button of nav.children) {
    button.setAttribute("aria-current", String(button.dataset.path === path));
  }
  current = path;
}

/** The EditorView inside a <code-editor>. */
const viewOf = (editor) => cm.EditorView.findFromDOM(editor.shadowRoot.querySelector(".cm-editor"));

function addFile(path, text) {
  if (!files.has(path)) fileButton(path);
  files.set(path, text);
  if (editors.has(path)) editors.get(path).value = text;
  show(path);
}

document.getElementById("format").addEventListener("click", () => {
  cm.formatDocument(viewOf(editorFor(current)));
});

document.getElementById("infer").addEventListener("click", async () => {
  const { schema, error } = await yaml.inferSchema([files.get(current)]);
  if (error) { status.textContent = `cannot infer: ${error.message}`; return; }
  addFile(current.replace(/(\.ya?ml)?$/, ".schema.yaml"), schema);
});

for (const path of files.keys()) fileButton(path);
show("/project/config.yaml");

// For test/checks.js, and for poking at it from the console.
window.demo = { cm, yaml, server, files, editors, show, viewOf, addFile };

if (new URLSearchParams(location.search).has("test")) import("./test/checks.js");
