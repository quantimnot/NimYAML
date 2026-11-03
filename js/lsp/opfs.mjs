// The open documents, kept in the Origin Private File System, so that a
// reload or a crash of the page loses no text (D-S1-009, D-S1-098).
//
// The server worker saves what the core's `save` effects carry: each
// document's whole text, debounced 300 ms per document, so that typing
// writes once a pause rather than once a keystroke. A write goes through a
// FileSystemSyncAccessHandle, the one OPFS writer that replaces a file's
// bytes synchronously and so is never seen half written; it exists only in
// dedicated workers, which is one reason the server runs in one. Another
// window of the same app may hold the same file's handle at that moment
// (the handle is exclusive), so a write that finds it taken is retried
// shortly after, a bounded number of times.
//
// A document's file is named by its URI, percent-encoded, in a directory of
// its own; `readAll` lists them with their texts and modification times, for
// the page to offer the newest at start.
//
// A dedicated worker dies with its page without a chance to write, so the
// page sends the editor's text on pagehide and the like, and the worker
// writes it at once with `writeNow` (lsp/transport.mjs, flushOnHide).
//
// `root` is the directory to work in — by default the OPFS root, which a
// test replaces with a directory handle of its own making.

const encoder = new TextEncoder();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const busy = new Set(["NoModificationAllowedError", "InvalidStateError"]);

export function opfsStore({ root = null, directory = "nimyaml-documents",
                            debounceMs = 300, retryMs = 50, retries = 40 } = {}) {
  let dirPromise = null;
  const dir = () => dirPromise ??= (async () => {
    const base = root ?? await navigator.storage.getDirectory();
    return base.getDirectoryHandle(directory, { create: true });
  })();
  const timers = new Map();  // uri -> timeout of its debounced write
  const chains = new Map();  // uri -> promise of its last write

  async function write(uri, text) {
    const file = await (await dir()).getFileHandle(encodeURIComponent(uri),
      { create: true });
    const bytes = encoder.encode(text);
    for (let attempt = 0; ; attempt++) {
      let handle;
      try {
        handle = await file.createSyncAccessHandle();
      } catch (e) {
        if (!busy.has(e.name) || attempt >= retries) throw e;
        await sleep(retryMs);
        continue;
      }
      try {
        handle.truncate(0);
        handle.write(bytes, { at: 0 });
        handle.flush();
      } finally {
        handle.close();
      }
      return;
    }
  }

  // writes of one document happen in order, never at once
  function enqueue(uri, text) {
    const next = (chains.get(uri) ?? Promise.resolve())
      .catch(() => {}).then(() => write(uri, text));
    chains.set(uri, next);
    return next;
  }

  return {
    /** Saves `text` as `uri` once no newer text came for `debounceMs`. */
    schedule(uri, text) {
      clearTimeout(timers.get(uri));
      timers.set(uri, setTimeout(() => {
        timers.delete(uri);
        enqueue(uri, text).catch((e) => console.error("nimyaml: save", uri, e));
      }, debounceMs));
    },
    /** Saves `text` as `uri` now, superseding a scheduled save. */
    writeNow(uri, text) {
      clearTimeout(timers.get(uri));
      timers.delete(uri);
      return enqueue(uri, text);
    },
    /** Every saved document: [{uri, text, modified}], newest first. */
    async readAll() {
      const documents = [];
      for await (const [name, handle] of (await dir()).entries()) {
        if (handle.kind !== "file") continue;
        const file = await handle.getFile();
        documents.push({ uri: decodeURIComponent(name), text: await file.text(),
                         modified: file.lastModified });
      }
      return documents.sort((a, b) => b.modified - a.modified);
    },
  };
}
