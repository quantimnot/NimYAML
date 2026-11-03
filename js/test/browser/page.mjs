// The browser test's page: runs the server worker as an app would and
// posts what it saw to the runner (run.mjs), which checks it. ?phase=save
// opens and edits documents, letting one save by the debounce and flushing
// the other as on pagehide; ?phase=restore, in the same profile afterwards,
// reports what the worker restored from OPFS.

import { startServer } from "../../lsp/transport.mjs";

const phase = new URLSearchParams(location.search).get("phase");
const report = (result) => fetch("/result", { method: "POST",
  body: JSON.stringify({ phase, ...result }) });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const server = startServer({
    persist: true,
    readFile: async (path) => path === "/p/.nimyaml-lint.yaml"
      ? "rules:\n  truthy: {level: error}\n" : null,
  });
  const restored = await server.restored;
  if (phase === "restore") return report({ restored });

  const notes = [];
  const answers = new Map();
  server.transport.subscribe((text) => {
    const m = JSON.parse(text);
    if (m.id !== undefined) answers.set(m.id, m); else notes.push(m);
  });
  const send = (m) => server.transport.send(JSON.stringify(m));
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } });
  const open = (uri, text) => send({ jsonrpc: "2.0", method: "textDocument/didOpen",
    params: { textDocument: { uri, languageId: "yaml", version: 1, text } } });
  const change = (uri, text) => send({ jsonrpc: "2.0", method: "textDocument/didChange",
    params: { textDocument: { uri, version: 2 }, contentChanges: [{ text }] } });
  open("file:///p/debounced.yaml", "k: yes\n");
  change("file:///p/debounced.yaml", "k: yes\nsaved: by the debounce\n");
  open("untitled:flushed", "a: 1\n");
  await sleep(1000);              // past the 300 ms debounce, and the reads
  server.flush("untitled:flushed", "a: 1\nsaved: by the flush\n");
  await sleep(300);
  const diagnostics = notes.filter((m) => m.method === "textDocument/publishDiagnostics"
    && m.params.uri === "file:///p/debounced.yaml").map((m) => m.params.diagnostics);
  report({ restored, initialized: !!answers.get(1)?.result, diagnostics });
}

main().catch((e) => report({ error: String(e?.stack ?? e) }));
