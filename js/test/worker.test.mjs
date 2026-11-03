// The server worker through lsp/transport.mjs, as a page uses it, in a real
// module Worker: `deno test -A js/test/worker.test.mjs` or
// `bun test js/test/worker.test.mjs`. Node has no Web Worker and skips it.
// There is no OPFS outside a browser, so nothing is persisted here; the
// browser test (js/test/browser/) covers that.

import { test } from "node:test";
import assert from "node:assert/strict";
import { startServer } from "../lsp/transport.mjs";

const hasWorker = typeof Worker !== "undefined";

function connect(server) {
  // what @codemirror/lsp-client does with a transport, in miniature
  const waiting = new Map(), notes = [];
  let nextId = 1;
  server.transport.subscribe((text) => {
    const message = JSON.parse(text);
    if (message.id !== undefined && waiting.has(message.id)) {
      waiting.get(message.id)(message);
      waiting.delete(message.id);
    } else {
      notes.push(message);
    }
  });
  return {
    notes,
    request(method, params) {
      const id = nextId++;
      server.transport.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
      return new Promise((resolve) => waiting.set(id, resolve));
    },
    notify(method, params) {
      server.transport.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
    },
    async published(uri, count = 1) {
      for (let i = 0; i < 200; i++) {
        const found = notes.filter((m) =>
          m.method === "textDocument/publishDiagnostics" && m.params.uri === uri);
        if (found.length >= count) return found[count - 1].params.diagnostics;
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      throw new Error(`no diagnostics for ${uri}`);
    },
  };
}

test("the server worker answers over postMessage and reads the page's files",
  { skip: !hasWorker && "no Web Worker in this runtime" }, async () => {
    const files = { "/p/.nimyaml-lint.yaml": "rules:\n  truthy: {level: error}\n" };
    const read = [];
    const server = startServer({
      readFile: async (path) => { read.push(path); return files[path] ?? null; },
    });
    try {
      assert.deepEqual(await server.restored, []);
      const client = connect(server);
      const init = await client.request("initialize", { capabilities: {} });
      assert.ok(init.result.capabilities.semanticTokensProvider);
      client.notify("textDocument/didOpen", { textDocument:
        { uri: "file:///p/x.yaml", languageId: "yaml", version: 1, text: "k: yes\n" } });
      // first without the config, as a warning; then the page's config makes
      // it an error
      assert.equal((await client.published("file:///p/x.yaml", 1))[0].severity, 2);
      const second = await client.published("file:///p/x.yaml", 2);
      assert.equal(second[0].severity, 1);
      assert.ok(read.includes("/p/.nimyaml-lint.yaml"));
      const hover = await client.request("textDocument/hover", {
        textDocument: { uri: "file:///p/x.yaml" }, position: { line: 0, character: 0 } });
      assert.equal(hover.error, undefined);
      await client.request("shutdown");
      client.notify("exit");
      assert.equal(await server.exited, 0);
    } finally {
      server.worker.terminate();
    }
  });
