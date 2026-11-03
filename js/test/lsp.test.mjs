// The language server's core and driver, on the in-memory host: what the
// server worker runs, minus postMessage and OPFS (see worker.test.mjs for
// those). Run with `node --test js/test/`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createCore, configure } from "../lsp/core.mjs";
import { createDriver } from "../lsp/driver.mjs";

const request = (id, method, params = {}) =>
  ({ jsonrpc: "2.0", id, method, params });
const notification = (method, params = {}) =>
  ({ jsonrpc: "2.0", method, params });
const didOpen = (uri, text) => notification("textDocument/didOpen",
  { textDocument: { uri, languageId: "yaml", version: 1, text } });
const didChange = (uri, text) => notification("textDocument/didChange",
  { textDocument: { uri, version: 2 }, contentChanges: [{ text }] });
const diagnosticsOf = (messages, uri) => messages.find((m) =>
  m.method === "textDocument/publishDiagnostics" && m.params.uri === uri)
  ?.params.diagnostics;

// A driver whose steps run when the test says, collecting what it sends.
function harness(options = {}) {
  const sent = [], saved = [], asked = [];
  let pending = null;
  const driver = createDriver({
    core: createCore(options),
    send: (m) => sent.push(m),
    save: (uri, text) => saved.push({ uri, text }),
    requestFiles: (paths) => asked.push(...paths),
    schedule: (run) => { pending = run; },
  });
  const step = () => { const run = pending; pending = null; run?.(); };
  return { driver, sent, saved, asked, step };
}

test("initialize, then diagnostics of an opened document", () => {
  const { driver, sent, step } = harness();
  driver.receive(request(1, "initialize", { capabilities: {} }));
  driver.receive(didOpen("untitled:a", "a: [\n"));
  step();
  assert.equal(sent[0].id, 1);
  assert.ok(sent[0].result.capabilities.hoverProvider);
  const diagnostics = diagnosticsOf(sent, "untitled:a");
  assert.equal(diagnostics.length, 1);
  assert.equal(diagnostics[0].severity, 1);
});

test("messages queued before a step are one batch: one check", () => {
  const { driver, sent, step } = harness();
  driver.receive(didOpen("untitled:b", "a: [\n"));
  driver.receive(didChange("untitled:b", "a: [1\n"));
  driver.receive(didChange("untitled:b", "a: 1\n"));
  driver.receive(request(7, "textDocument/hover",
    { textDocument: { uri: "untitled:b" }, position: { line: 0, character: 0 } }));
  step();
  const publishes = sent.filter((m) => m.method === "textDocument/publishDiagnostics");
  assert.equal(publishes.length, 1);
  assert.deepEqual(publishes[0].params.diagnostics, []);
  assert.ok(sent.some((m) => m.id === 7 && !m.error));
});

test("a config the server misses is read from the page, then applies", () => {
  const { driver, sent, asked, step } = harness();
  const uri = "file:///project/x.yaml";
  driver.receive(didOpen(uri, "k: yes\n"));
  step();
  // without a config, truthy values are a warning
  assert.equal(diagnosticsOf(sent, uri)[0].severity, 2);
  assert.ok(asked.includes("/project/.nimyaml-lint.yaml"), asked.join());
  // the page answers: one config, the rest do not exist
  const files = Object.fromEntries(asked.map((p) => [p, null]));
  files["/project/.nimyaml-lint.yaml"] = "rules:\n  truthy: {level: error}\n";
  sent.length = 0;
  driver.filesArrived(files);
  step();
  const diagnostics = diagnosticsOf(sent, uri);
  assert.equal(diagnostics.length, 1);
  assert.equal(diagnostics[0].severity, 1);
  assert.match(diagnostics[0].message, /boolean/);
});

test("documents are saved only when configured to persist", () => {
  const off = harness();
  off.driver.receive(didOpen("untitled:c", "a: 1\n"));
  off.step();
  assert.deepEqual(off.saved, []);
  const on = harness();
  on.driver.receive(configure({ persist: true }));
  on.driver.receive(didOpen("untitled:c", "a: 1\n"));
  on.driver.receive(didChange("untitled:c", "a: 2\n"));
  on.step();
  assert.deepEqual(on.saved, [{ uri: "untitled:c", text: "a: 2\n" }]);
});

test("shutdown, exit", () => {
  let code = null;
  const driver = createDriver({
    core: createCore(), send: () => {}, onExit: (c) => { code = c; },
    schedule: (run) => run(),
  });
  driver.receive(request(1, "shutdown"));
  driver.receive(notification("exit"));
  assert.equal(code, 0);
  assert.ok(driver.exited);
});
