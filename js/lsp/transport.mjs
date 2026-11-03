// The page's side of the server worker (lsp/server-worker.mjs).
//
// startServer starts the worker and returns, among other things, a
// `transport`: the object @codemirror/lsp-client's LSPClient connects to
// ({send, subscribe, unsubscribe}, whole messages as JSON text), which is
// all an editor needs to talk to the server. The rest is what only the
// page can do:
//
// * answer the server's reads, with `readFile(path)` — the page's files,
//   from wherever it keeps them: text, or null when there is none;
// * take the documents the worker restored from OPFS (`restored`);
// * have the worker write a document at once (`flush`), when the page goes
//   away and the worker's debounced save would be lost with it.
//   flushOnHide wires that to the page's lifecycle: a dedicated worker
//   dies with its page, and a flush that waited for the editor's next
//   change and a step reached the worker in about one reload in five, so
//   the text goes with the request.
//
// The worker is given, or made from the module next to this one; a bundler
// that rewrites `new URL(..., import.meta.url)` finds it either way.

export function startServer({
  worker = new Worker(new URL("./server-worker.mjs", import.meta.url),
                      { type: "module" }),
  readFile = async () => null,
  persist = false,
} = {}) {
  const handlers = new Set();
  let resolveRestored, resolveExited;
  const restored = new Promise((resolve) => { resolveRestored = resolve; });
  const exited = new Promise((resolve) => { resolveExited = resolve; });

  worker.addEventListener("message", async ({ data }) => {
    if (data.lsp !== undefined) {
      const text = JSON.stringify(data.lsp);
      for (const handler of handlers) handler(text);
    } else if (data.read) {
      const entries = await Promise.all(data.read.map(async (path) => {
        try { return [path, (await readFile(path)) ?? null]; }
        catch { return [path, null]; }
      }));
      worker.postMessage({ files: Object.fromEntries(entries) });
    } else if (data.restored) {
      resolveRestored(data.restored);
    } else if (data.exited !== undefined) {
      resolveExited(data.exited);
    }
  });
  worker.postMessage({ configure: { persist } });

  return {
    /** For @codemirror/lsp-client: new LSPClient().connect(transport). */
    transport: {
      send: (message) => worker.postMessage({ lsp: message }),
      subscribe: (handler) => handlers.add(handler),
      unsubscribe: (handler) => handlers.delete(handler),
    },
    /** The documents saved in OPFS: [{uri, text, modified}], newest first. */
    restored,
    /** The server's exit code, once it exits. */
    exited,
    /** Has the worker save `text` as `uri` now. */
    flush: (uri, text) => worker.postMessage({ flush: { uri, text } }),
    worker,
  };
}

/**
 * Flushes the documents `documents()` returns — [{uri, text}] — whenever
 * the page may be going away. Returns a function that undoes it.
 */
export function flushOnHide(server, documents, target = globalThis) {
  const flushAll = () => {
    for (const { uri, text } of documents()) server.flush(uri, text);
  };
  const onVisibility = () => {
    if (target.document?.visibilityState === "hidden") flushAll();
  };
  target.addEventListener("pagehide", flushAll);
  target.addEventListener("beforeunload", flushAll);
  target.document?.addEventListener("visibilitychange", onVisibility);
  return () => {
    target.removeEventListener("pagehide", flushAll);
    target.removeEventListener("beforeunload", flushAll);
    target.document?.removeEventListener("visibilitychange", onVisibility);
  };
}
