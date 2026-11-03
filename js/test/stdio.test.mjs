// lsp/stdio.mjs as an editor sees it: a process speaking framed LSP.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const server = fileURLToPath(new URL("../lsp/stdio.mjs", import.meta.url));
const frame = (message) => {
  const body = Buffer.from(JSON.stringify(message));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
};

function parseFrames(bytes) {
  const messages = [];
  let rest = bytes;
  for (;;) {
    const end = rest.indexOf("\r\n\r\n");
    if (end < 0) return messages;
    const length = Number(/Content-Length: (\d+)/i.exec(rest.subarray(0, end))[1]);
    messages.push(JSON.parse(rest.subarray(end + 4, end + 4 + length)));
    rest = rest.subarray(end + 4 + length);
  }
}

test("initialize, diagnostics, shutdown and exit over stdio", async () => {
  const child = spawn(process.execPath, [server], { stdio: ["pipe", "pipe", "inherit"] });
  const chunks = [];
  child.stdout.on("data", (c) => chunks.push(c));
  const exited = new Promise((resolve) => child.on("exit", resolve));
  // é makes the byte length differ from the character length
  child.stdin.write(Buffer.concat([
    frame({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } }),
    frame({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument:
      { uri: "untitled:x", languageId: "yaml", version: 1, text: "é: [\n" } } }),
  ]));
  await new Promise((resolve) => setTimeout(resolve, 300));
  child.stdin.write(Buffer.concat([
    frame({ jsonrpc: "2.0", id: 2, method: "shutdown" }),
    frame({ jsonrpc: "2.0", method: "exit" }),
  ]));
  assert.equal(await exited, 0);
  const messages = parseFrames(Buffer.concat(chunks));
  assert.equal(messages[0].id, 1);
  const published = messages.find((m) => m.method === "textDocument/publishDiagnostics");
  assert.equal(published.params.diagnostics.length, 1);
  assert.ok(messages.some((m) => m.id === 2 && m.result === null));
});
