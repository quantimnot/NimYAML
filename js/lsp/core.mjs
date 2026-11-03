// The language server's core as a step function over a batch of messages.
//
// tools/yamllsp.nim is the server; compiled into dist/nimyaml.mjs, it is
// reached through two exports: lspNew, a server with nothing open, and
// lspStep, which hands it a batch of messages (handleBatch: each document
// checked once per batch, stale requests answered ContentModified) and
// returns the messages to send and the documents to save. This module adds
// the one effect the compiled server cannot report itself: `read`. The
// server reads its configs and `file:` schemas synchronously, through the
// installed host; in a worker those files belong to the page, so the host
// is an in-memory one (hosts/memory.mjs) that answers "no such file" for a
// path it does not know and reports the miss. A step's misses are its
// `read` effect; once the driver has the answers it calls `answer`, which
// stores them in the host and returns the notification that makes the
// server read again, for the driver to queue as its next input (D-S1-092's
// `read` and `$/rei/read`, under this server's names).
//
// A step is
//
//   step(messages) -> { out: [message], save: [{uri, text}],
//                       read: [path], exited: bool, exitCode: number }
//
// and names no host or transport: drivers own those (lsp/driver.mjs).
//
// There is one server per module instance, since the compiled program has
// one host: a worker, or a process, runs one server.

import * as nimyaml from "../dist/nimyaml.mjs";
import { memoryHost } from "../hosts/memory.mjs";

export function createCore({ host = null, files = {}, cwd = "/" } = {}) {
  let misses = new Set();
  const own = host === null;
  if (own) {
    host = memoryHost({ files, cwd, onMiss: (path) => misses.add(path) });
  }
  nimyaml.installHost(host);
  const server = nimyaml.lspNew();

  return {
    host,
    step(messages) {
      misses = new Set();
      const { ok, error } = JSON.parse(
        nimyaml.lspStep(server, JSON.stringify(messages)));
      if (error) throw new Error(`yamllsp: ${error.message}`);
      return { ...ok, read: [...misses] };
    },
    /**
     * Stores the page's answers to a `read` effect — {path: text or null
     * for no such file} — and returns the message to queue next.
     */
    answer(files) {
      if (!own) throw new Error("answer needs the core's own memory host");
      for (const [path, text] of Object.entries(files)) host.put(path, text);
      return { jsonrpc: "2.0", method: "nimyaml/filesChanged" };
    },
  };
}

/** The driver's first input: whether the core emits `save` effects. */
export const configure = ({ persist }) =>
  ({ jsonrpc: "2.0", method: "$/nimyaml/configure", params: { persist } });
