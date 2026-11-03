// lsp/opfs.mjs against a directory handle made here, with OPFS's rules:
// a file has one sync access handle at a time, and another window may
// hold it. No JavaScript runtime outside a browser has OPFS; a browser
// runs the real one in the server worker.

import { test } from "node:test";
import assert from "node:assert/strict";
import { opfsStore } from "../lsp/opfs.mjs";

function fakeDirectory() {
  const files = new Map();   // name -> { bytes, lastModified, held }
  const dirs = new Map();
  const busy = () => Object.assign(new Error("held"), { name: "NoModificationAllowedError" });
  const fileHandle = (name) => ({
    kind: "file",
    async createSyncAccessHandle() {
      const file = files.get(name);
      if (file.held) throw busy();
      file.held = true;
      return {
        truncate(n) { file.bytes = file.bytes.subarray(0, n); },
        write(bytes, { at }) {
          const next = new Uint8Array(Math.max(file.bytes.length, at + bytes.length));
          next.set(file.bytes);
          next.set(bytes, at);
          file.bytes = next;
          file.lastModified = Date.now();
          return bytes.length;
        },
        flush() {},
        close() { file.held = false; },
      };
    },
    async getFile() {
      const file = files.get(name);
      return { lastModified: file.lastModified,
               text: async () => new TextDecoder().decode(file.bytes) };
    },
  });
  const dir = {
    files,
    async getDirectoryHandle(name) {
      if (!dirs.has(name)) dirs.set(name, fakeDirectory());
      return dirs.get(name);
    },
    async getFileHandle(name, { create } = {}) {
      if (!files.has(name)) {
        if (!create) throw Object.assign(new Error("none"), { name: "NotFoundError" });
        files.set(name, { bytes: new Uint8Array(), lastModified: 0, held: false });
      }
      return fileHandle(name);
    },
    async *entries() {
      for (const name of files.keys()) yield [name, fileHandle(name)];
    },
  };
  return dir;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("saves are debounced per document; the last text wins", async () => {
  const root = fakeDirectory();
  const store = opfsStore({ root, debounceMs: 20 });
  store.schedule("file:///a.yaml", "a: 1\n");
  store.schedule("file:///a.yaml", "a: 12\n");
  store.schedule("untitled:b", "b: 1\n");
  assert.deepEqual(await store.readAll(), []);
  await sleep(80);
  const saved = await store.readAll();
  assert.deepEqual(saved.map((d) => [d.uri, d.text]).sort(),
    [["file:///a.yaml", "a: 12\n"], ["untitled:b", "b: 1\n"]]);
});

test("writeNow writes at once, superseding a scheduled save", async () => {
  const store = opfsStore({ root: fakeDirectory(), debounceMs: 1000 });
  store.schedule("untitled:c", "old\n");
  await store.writeNow("untitled:c", "new\n");
  assert.deepEqual((await store.readAll()).map((d) => d.text), ["new\n"]);
});

test("a file held by another window is written once it is free", async () => {
  const root = fakeDirectory();
  const store = opfsStore({ root, retryMs: 10 });
  await store.writeNow("untitled:d", "first\n");
  const inner = await root.getDirectoryHandle("nimyaml-documents");
  const file = inner.files.get(encodeURIComponent("untitled:d"));
  file.held = true;                          // the other window
  const written = store.writeNow("untitled:d", "second\n");
  await sleep(35);
  file.held = false;
  await written;
  assert.deepEqual((await store.readAll()).map((d) => d.text), ["second\n"]);
});
