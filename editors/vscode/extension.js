// VS Code binding for yamllsp, NimYAML's language server.
//
// yamllsp does all the work: linting, JSON Schema validation and the
// %GLOBAL/%SCHEMA directive features. This extension only starts it over
// stdio and hands it YAML documents, so it stays a thin, build-free shim:
// plain CommonJS instead of TypeScript, because there is nothing here a
// type checker would catch that starting VS Code doesn't.
//
// The server is not bundled. It is a native binary built from this
// repository, and where it lives depends on the machine, so the command
// comes from the `yaml+lsp.path` and `yaml+lsp.args` settings
// and defaults to `yaml lsp`, with `yaml` looked up on PATH.
//
// yamllsp coexists with other YAML extensions (e.g. Red Hat's
// yaml-language-server): VS Code merges diagnostics, hovers and completions
// from every server attached to a document.
//
// The one part that is more than a shim is embedded languages (embedded/):
// code in block scalars is served by the extensions of its language, which
// only VS Code can reach. yamllsp still reports where the blocks are.
//
// The other is the grid (grid/), a custom editor that shows a file as
// nested tables; yamllsp reads and edits the documents for it, and its
// webview is the one piece of TypeScript, since it is all DOM code.
//
// And paths (paths/): the JSON Pointer or JSON Path of the node at the
// cursor in the status bar, commands that copy it, and "Go to Path…".
//
// And diff (diff/): a semantic diff of two YAML or JSON texts, which
// yamllsp computes and a quick pick lists.
//
// And comments (comments/): Enter in a comment continues it.
//
// And schemas (schemas/): VS Code's own `vscode://schemas/...`, which
// yamllsp cannot read, are given to it on request.
//
// Workspace Trust (`capabilities.untrustedWorkspaces` in package.yaml):
// yamllsp runs in a workspace the user has not trusted, since what it reads
// from the workspace (`.yaml` configs, schemas) is data, but the command
// that starts it must not come from there, so `yaml+lsp.path` and
// `yaml+lsp.args` are restricted settings: VS Code gives their user values
// until trust is granted, then reports them changed, which restarts the
// server below. Embedded languages (config.js) and schema downloads
// (schemas/) wait for trust too; the grid, paths, the semantic diff and
// comments touch nothing outside the editor and work as usual.

const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const { activateEmbedded } = require("./embedded");
const { registerGrid } = require("./grid");
const { registerPaths } = require("./paths");
const { registerDiff } = require("./diff");
const { registerComments } = require("./comments");
const { registerSchemas, initializationOptions } = require("./schemas");

let client;
let embedded;
let grid;
let paths;
let schemas;
let traceOutputChannel;

// Documents yamllsp is told about. `file` documents get their
// `.nimyaml-lint.yaml` and `file:` schemas resolved relative to their
// location; `untitled` ones are linted with the default configuration.
const documentSelector = [
  { scheme: "file", language: "yaml" },
  { scheme: "untitled", language: "yaml" },
];

function serverOptions() {
  const config = vscode.workspace.getConfiguration("yaml+lsp");
  return {
    command: config.get("path", "yaml"),
    args: config.get("args", ["lsp"]),
    transport: TransportKind.stdio,
  };
}

// vscode-languageclient traces only while its channel's log level is Trace,
// a per-channel choice in the Output view; `yaml+lsp.trace.server` is read
// only then, and "off" is read as "messages". This channel reports Trace
// exactly when the setting is not "off", so the setting decides alone, and
// writes the messages at the info level a channel shows by default.
function createTraceChannel() {
  const channel = vscode.window.createOutputChannel("yaml+lsp Trace", { log: true });
  const changed = new vscode.EventEmitter();
  const level = () =>
    vscode.workspace.getConfiguration("yaml+lsp").get("trace.server", "off") === "off"
      ? vscode.LogLevel.Off
      : vscode.LogLevel.Trace;
  let current = level();
  const listener = vscode.workspace.onDidChangeConfiguration((event) => {
    if (!event.affectsConfiguration("yaml+lsp.trace.server")) return;
    current = level();
    changed.fire(current);
  });
  return {
    get name() { return channel.name; },
    get logLevel() { return current; },
    onDidChangeLogLevel: changed.event,
    trace: (message, ...args) => channel.info(message, ...args),
    debug: (message, ...args) => channel.debug(message, ...args),
    info: (message, ...args) => channel.info(message, ...args),
    warn: (message, ...args) => channel.warn(message, ...args),
    error: (error, ...args) => channel.error(error, ...args),
    append: (value) => channel.append(value),
    appendLine: (value) => channel.appendLine(value),
    replace: (value) => channel.replace(value),
    clear: () => channel.clear(),
    show: (...args) => channel.show(...args),
    hide: () => channel.hide(),
    dispose: () => {
      listener.dispose();
      changed.dispose();
      channel.dispose();
    },
  };
}

async function start() {
  client = new LanguageClient(
    "yaml+lsp",
    "yaml+lsp",
    serverOptions(),
    {
      documentSelector,
      traceOutputChannel,
      middleware: embedded.middleware,
      initializationOptions,
    },
  );
  schemas.attach(client);
  try {
    await client.start();
    embedded.restarted();
    grid.restarted();
    paths.restarted();
  } catch (e) {
    vscode.window.showErrorMessage(
      `Could not start yamllsp (${e.message}). Build it with ` +
        "`nim yamllsp config.nims` and put it on PATH, or set " +
        "`yaml+lsp.path`.",
    );
  }
}

async function stop() {
  if (client) {
    const stopping = client;
    client = undefined;
    // A client whose server never started throws on stop; nothing to clean.
    try { await stopping.stop(); } catch (_) {}
  }
}

async function restart() {
  await stop();
  await start();
}

async function activate(context) {
  // one channel for every client, so a restart keeps the trace so far
  traceOutputChannel = createTraceChannel();
  context.subscriptions.push(
    traceOutputChannel,
    vscode.commands.registerCommand("yaml+lsp.restart", restart),
    // A different server command only takes effect in a new process; the
    // settings of paths/ are the client's alone.
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("yaml+lsp") &&
          !event.affectsConfiguration("yaml+lsp.paths")) restart();
    }),
  );
  embedded = await activateEmbedded(context, documentSelector, () => client);
  grid = registerGrid(context, () => client);
  context.subscriptions.push(grid.disposable);
  paths = registerPaths(() => client);
  context.subscriptions.push(paths.disposable);
  context.subscriptions.push(registerDiff(() => client));
  context.subscriptions.push(registerComments());
  schemas = registerSchemas(() => client);
  context.subscriptions.push(schemas.disposable);
  await start();
}

async function deactivate() {
  await embedded?.dispose();
  await stop();
}

module.exports = { activate, deactivate };
