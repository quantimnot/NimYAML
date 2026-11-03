// The event loop between a transport and the server's core, for any host.
//
// A driver waits on more than one thing: the next message, and whether more
// are already queued; in the worker also the page's answers to reads and a
// debounce timer for saving. The core cannot wait at all — it is a step
// function (lsp/core.mjs) — so this loop holds the queue and calls it.
// Messages that arrive before a scheduled step runs join its batch: the
// step takes the whole queue, in arrival order, so a burst of keystrokes
// costs one check of the document (D-S1-059). The driver never looks
// inside a message; it carries out the step's effects:
//
// * `out`: sent, in order, with `send`;
// * `save`: handed to `save(uri, text)`, which the worker debounces into
//   OPFS (the core emits saves only when configured to persist);
// * `read`: the paths are asked for with `requestFiles(paths)`, and the
//   answer, passed to `filesArrived`, is stored by the core and followed by
//   the core's notification to read again, queued like any message.
//
// `schedule` decides when a step runs after a message arrives: by default
// on a timer of `quietMs` (2 ms, the worker's quiet of the design's
// measurements), so that messages posted together land in one batch.
// Tests pass one they run by hand.
//
// The stdio driver (lsp/stdio.mjs) and the worker (lsp/server-worker.mjs)
// are this loop with a transport each.

export function createDriver({ core, send, save = () => {},
                               requestFiles = () => {}, onExit = () => {},
                               quietMs = 2,
                               schedule = (run) => setTimeout(run, quietMs) }) {
  const queue = [];
  let scheduled = false;
  let exited = false;
  const pending = new Set(); // paths asked for and not answered yet

  function run() {
    scheduled = false;
    if (exited || queue.length === 0) return;
    const batch = queue.splice(0, queue.length);
    let result;
    try {
      result = core.step(batch);
    } catch (e) {
      // the core answers errors of single messages itself; this is a bug of
      // the core or the build, and the batch's requests must still be answered
      for (const msg of batch) {
        if (msg.id !== undefined && msg.method) {
          send({ jsonrpc: "2.0", id: msg.id,
                 error: { code: -32603, message: String(e.message ?? e) } });
        }
      }
      return;
    }
    for (const msg of result.out) send(msg);
    for (const { uri, text } of result.save) save(uri, text);
    const wanted = result.read.filter((path) => !pending.has(path));
    if (wanted.length > 0) {
      for (const path of wanted) pending.add(path);
      requestFiles(wanted);
    }
    if (result.exited) {
      exited = true;
      onExit(result.exitCode);
    }
  }

  function enqueue(msg) {
    if (exited) return;
    queue.push(msg);
    if (!scheduled) {
      scheduled = true;
      schedule(run);
    }
  }

  return {
    /** A message from the client. */
    receive: enqueue,
    /** The answer to `requestFiles`: {path: text, or null for none}. */
    filesArrived(files) {
      for (const path of Object.keys(files)) pending.delete(path);
      enqueue(core.answer(files));
    },
    get exited() { return exited; },
  };
}
