// The YAML language server in a browser: a dedicated worker that the page
// talks LSP to by postMessage (the design's server worker, D-S1-007).
//
// Why a worker of its own: a check of a large document must not stall the
// editor, and a runaway one kills only the worker. Why a dedicated worker
// and not a service worker: the page's editor is its only client, it needs
// FileSystemSyncAccessHandle to save documents (lsp/opfs.mjs), which only a
// dedicated worker has, and a service worker may be stopped by the browser
// whenever it is idle, taking the server's open documents with it.
//
// The worker is the driver of lsp/driver.mjs with postMessage as transport.
// It owns no file system: the files the server reads (configs, `file:`
// schemas) belong to the page, which the worker asks for with a `read`
// message and which answers with `files`. Messages, page to worker:
//
//   {lsp: MESSAGE}                 an LSP message, as text or object
//   {files: {PATH: TEXT | null}}   the answer to a read; null: no such file
//   {configure: {persist: BOOL}}   whether to save open documents in OPFS;
//                                  the first message, if any
//   {flush: {uri, text}}           write this text now (page is going away)
//
// and worker to page:
//
//   {restored: [{uri, text, modified}]}  what OPFS holds, newest first,
//                                         sent once, before anything else
//   {lsp: MESSAGE}                 an LSP message, as an object
//   {read: [PATH]}                 files the server needs
//   {flushed: URI}                 a flush was written
//   {exited: CODE}                 the server exited
//
// At start, before the server is even loaded, the worker hands the page what
// OPFS holds (D-S1-098), so that the page can show the newest text at once.
// Messages that arrive meanwhile wait, in order, for the server.
// lsp/transport.mjs is the page's side of all this.

import { opfsStore } from "./opfs.mjs";

const post = (message) => self.postMessage(message);
const waiting = [];
let handle = (message) => waiting.push(message);
self.onmessage = (event) => handle(event.data);

const store = self.navigator?.storage?.getDirectory ? opfsStore() : null;

async function restore() {
  if (!store) return [];
  try { return await store.readAll(); }
  catch (e) { console.error("nimyaml: restoring documents", e); return []; }
}

post({ restored: await restore() });

const { createCore, configure } = await import("./core.mjs");
const { createDriver } = await import("./driver.mjs");

const driver = createDriver({
  core: createCore(),
  send: (message) => post({ lsp: message }),
  save: (uri, text) => store?.schedule(uri, text),
  requestFiles: (paths) => post({ read: paths }),
  onExit: (code) => post({ exited: code }),
});

handle = (message) => {
  if (message.lsp !== undefined) {
    driver.receive(typeof message.lsp === "string"
      ? JSON.parse(message.lsp) : message.lsp);
  } else if (message.files) {
    driver.filesArrived(message.files);
  } else if (message.configure) {
    driver.receive(configure({ persist: !!message.configure.persist && !!store }));
  } else if (message.flush) {
    const { uri, text } = message.flush;
    store?.writeNow(uri, text).then(() => post({ flushed: uri }),
      (e) => console.error("nimyaml: flushing", uri, e));
  }
};
for (const message of waiting.splice(0)) handle(message);
