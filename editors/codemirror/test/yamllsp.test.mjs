// The parts of yamllsp.js and serve.mjs that need no browser: decoding the
// server's highlighting, the classes it is drawn with, answering the server's
// schema requests, and what the demo server will and will not serve.
// test/browser.mjs checks the rest, in the page.
//
//   node --test editors/codemirror/test/

import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeSemanticTokens, tokenClass, answeringSchemas, TOKEN_CLASSES } from "../yamllsp.js";
import { serve } from "../serve.mjs";

const legend = { tokenTypes: ["comment", "keyword", "string", "number", "property"],
                 tokenModifiers: ["declaration"] };

test("tokens are decoded from relative positions", () => {
  // "a: 1  # c" / "b: x": a key, a number, a comment; a key, a string
  const data = [0, 0, 1, 4, 0,  0, 3, 1, 3, 0,  0, 3, 3, 0, 0,  1, 0, 1, 4, 1,  0, 3, 1, 2, 0];
  assert.deepEqual(decodeSemanticTokens(data, legend), [
    { line: 0, character: 0, length: 1, type: "property", modifiers: [] },
    { line: 0, character: 3, length: 1, type: "number", modifiers: [] },
    { line: 0, character: 6, length: 3, type: "comment", modifiers: [] },
    { line: 1, character: 0, length: 1, type: "property", modifiers: ["declaration"] },
    { line: 1, character: 3, length: 1, type: "string", modifiers: [] },
  ]);
});

test("a token's classes: the highlighter's, its type's and its modifiers'", () => {
  assert.equal(tokenClass({ type: "property", modifiers: [] }), "tok-propertyName yamllsp-property");
  assert.equal(tokenClass({ type: "variable", modifiers: ["declaration"] }),
    "tok-labelName yamllsp-variable yamllsp-declaration");
  assert.equal(tokenClass({ type: "future", modifiers: [] }), "yamllsp-future");
});

test("every type of the server's legend has a highlighter class", () => {
  // HighlightKind in tools/yamllsp.nim
  for (const type of ["comment", "keyword", "string", "number", "property", "type",
                      "variable", "operator", "namespace", "parameter"]) {
    assert.ok(TOKEN_CLASSES[type], type);
  }
});

function fakeTransport() {
  const sent = [], handlers = new Set();
  return {
    sent,
    receive: (message) => { for (const h of handlers) h(JSON.stringify(message)); },
    send: (text) => sent.push(JSON.parse(text)),
    subscribe: (h) => handlers.add(h),
    unsubscribe: (h) => handlers.delete(h),
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("schema requests are answered, not passed on; the rest is", async () => {
  const inner = fakeTransport();
  const asked = [];
  const outer = answeringSchemas(inner, async (uri) => { asked.push(uri); return "type: object\n"; });
  const passed = [];
  outer.subscribe((text) => passed.push(JSON.parse(text)));

  inner.receive({ jsonrpc: "2.0", method: "textDocument/publishDiagnostics", params: {} });
  inner.receive({ jsonrpc: "2.0", id: "nimyaml/schemaContent/1", method: "nimyaml/schemaContent",
                  params: { uri: "https://x.example/s.json" } });
  await settle();
  assert.deepEqual(passed.map((m) => m.method), ["textDocument/publishDiagnostics"]);
  assert.deepEqual(asked, ["https://x.example/s.json"]);
  assert.deepEqual(inner.sent, [{ jsonrpc: "2.0", id: "nimyaml/schemaContent/1",
                                  result: "type: object\n" }]);

  outer.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }));
  assert.equal(inner.sent.at(-1).method, "initialize");
});

test("a schema that cannot be had is answered with the error", async () => {
  const inner = fakeTransport();
  answeringSchemas(inner, async () => { throw new Error("HTTP 404"); });
  inner.receive({ jsonrpc: "2.0", id: 7, method: "nimyaml/schemaContent", params: { uri: "https://x" } });
  await settle(); await settle();
  assert.deepEqual(inner.sent, [{ jsonrpc: "2.0", id: 7, error: { code: -32803, message: "HTTP 404" } }]);
});

test("the demo server serves its mounts and nothing above them", async (t) => {
  const components = new URL("./", import.meta.url).pathname;   // any folder will do
  const server = await serve({ components });
  t.after(() => server.close());
  const status = async (path) => (await fetch(server.url + path.replace(/^\//, ""))).status;
  assert.equal(await status("/"), 200);
  assert.equal(await status("/yamllsp.js"), 200);
  assert.equal(await status("/nimyaml/lsp/transport.mjs"), 200);
  assert.equal(await status("/ui/yamllsp.test.mjs"), 200);
  assert.equal(await status("/%2e%2e/%2e%2e/yaml.nim"), 404);
  assert.equal(await status("/nimyaml/%2e%2e/yaml.nim"), 404);
});
