#!/usr/bin/env node
// The YAML language server over standard streams, for editors that start
// one as a process: `node js/lsp/stdio.mjs` (or bun, or deno run -A).
//
// It is the driver of lsp/driver.mjs with LSP's base protocol as transport:
// messages framed by a Content-Length header, in and out. The driver frames
// bytes and never looks inside a message (D-S1-024). Messages that arrive
// while a step runs queue, and the next step takes them all as one batch.
// Files are the real ones, through hosts/node.mjs, read synchronously by
// the server, so there are no `read` effects to carry out; nor `save`
// effects, since the editor saves its own files.
//
// The compiled `yaml lsp` command cannot serve this way: it reads standard
// input through the host, which hands it over whole, at the end.

import process from "node:process";
import { nodeHost } from "../hosts/node.mjs";
import { createCore } from "./core.mjs";
import { createDriver } from "./driver.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function send(message) {
  const body = encoder.encode(JSON.stringify(message));
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

const driver = createDriver({
  core: createCore({ host: nodeHost() }),
  send,
  onExit: (code) => {
    process.exitCode = code;
    process.stdin.destroy();
  },
});

// The base protocol: headers up to an empty line, then Content-Length bytes.
let buffer = new Uint8Array(0);
const separator = encoder.encode("\r\n\r\n");

function indexOfSeparator(bytes) {
  outer: for (let i = 0; i + separator.length <= bytes.length; i++) {
    for (let j = 0; j < separator.length; j++) {
      if (bytes[i + j] !== separator[j]) continue outer;
    }
    return i;
  }
  return -1;
}

function frames() {
  for (;;) {
    const end = indexOfSeparator(buffer);
    if (end < 0) return;
    const headers = decoder.decode(buffer.subarray(0, end));
    const match = /^content-length:\s*(\d+)\s*$/im.exec(headers);
    const start = end + separator.length;
    if (!match) {
      console.error("yamllsp: a message without Content-Length");
      buffer = buffer.subarray(start);
      continue;
    }
    const length = Number(match[1]);
    if (buffer.length < start + length) return;
    const body = decoder.decode(buffer.subarray(start, start + length));
    buffer = buffer.subarray(start + length);
    try { driver.receive(JSON.parse(body)); }
    catch (e) { console.error("yamllsp: " + e.message); }
  }
}

process.stdin.on("data", (chunk) => {
  const joined = new Uint8Array(buffer.length + chunk.length);
  joined.set(buffer);
  joined.set(chunk, buffer.length);
  buffer = joined;
  frames();
});
process.stdin.on("end", () => {
  // the input ended without `exit`: an error, as natively
  if (!driver.exited) process.exitCode = 1;
});
