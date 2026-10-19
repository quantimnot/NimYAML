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
// comes from the `nimyaml.yamllsp.path` setting and defaults to looking up
// `yamllsp` on PATH.
//
// yamllsp coexists with other YAML extensions (e.g. Red Hat's
// yaml-language-server): VS Code merges diagnostics, hovers and completions
// from every server attached to a document.
//
// The one part that is more than a shim is embedded languages (embedded/):
// code in block scalars is served by the extensions of its language, which
// only VS Code can reach. yamllsp still reports where the blocks are.

const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const { activateEmbedded } = require("./embedded");

let client;
let embedded;

// Documents yamllsp is told about. `file` documents get their
// `.nimyaml-lint.yaml` and `file:` schemas resolved relative to their
// location; `untitled` ones are linted with the default configuration.
const documentSelector = [
  { scheme: "file", language: "yaml" },
  { scheme: "untitled", language: "yaml" },
];

function serverOptions() {
  const config = vscode.workspace.getConfiguration("nimyaml.yamllsp");
  return {
    command: config.get("path", "yamllsp"),
    args: config.get("args", []),
    transport: TransportKind.stdio,
  };
}

async function start() {
  client = new LanguageClient(
    "nimyaml",
    "NimYAML yamllsp",
    serverOptions(),
    { documentSelector, middleware: embedded.middleware },
  );
  try {
    await client.start();
    embedded.restarted();
  } catch (e) {
    vscode.window.showErrorMessage(
      `Could not start yamllsp (${e.message}). Build it with ` +
        "`nim yamllsp config.nims` and put it on PATH, or set " +
        "`nimyaml.yamllsp.path`.",
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
  context.subscriptions.push(
    vscode.commands.registerCommand("nimyaml.yamllsp.restart", restart),
    // A different server command only takes effect in a new process.
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("nimyaml.yamllsp")) restart();
    }),
  );
  embedded = await activateEmbedded(context, documentSelector, () => client);
  await start();
}

async function deactivate() {
  await embedded?.dispose();
  await stop();
}

module.exports = { activate, deactivate };
