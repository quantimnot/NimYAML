// Grid: a custom editor that shows YAML and JSON files as nested, resizable
// tables, ported from greenflute/yaml-grid-viewer.
//
// Upstream parsed and edited with the `yaml` npm package and drew with Vue.
// Here yamllsp does the YAML (`nimyaml/grid` and `nimyaml/gridEdit`, see
// tools/yamllsp.nim), so the grid reads a file exactly as the rest of the
// extension does, `%GLOBAL` and all, and an edit rewrites only the node it
// changes, leaving comments and layout alone, through yaml/edit; and the
// webview (grid/webview) is plain TypeScript and CSS. Nothing is bundled
// that the extension did not already have.
//
// The provider is a CustomTextEditorProvider: the file stays a
// TextDocument, so the grid and text editors of it share undo, dirty state
// and saving, and the grid is redrawn on every change, whichever editor
// made it. The grid is offered by "Open With…" and by the
// `yaml+lsp.grid.open` command, never as the default editor.
//
// The server is asked with the text rather than the document's URI: JSON
// files are not documents yamllsp is given, and an edit must apply to
// exactly the version of the text it was computed from.

const vscode = require("vscode");
const crypto = require("crypto");
const { minimalEdit } = require("./edits");

const VIEW_TYPE = "yaml+lsp.grid";
// redraws while typing in a text editor of the same file wait this long
const UPDATE_DELAY_MS = 150;

/**
 * Registers the grid editor and its command. `getClient()` is yamllsp's
 * current client, replaced on restart. Returns the disposable and
 * `restarted()`, to be called when a client has started.
 */
function registerGrid(context, getClient) {
  const grids = new Set();
  const provider = {
    resolveCustomTextEditor(document, panel) {
      const grid = new Grid(context, document, panel, getClient);
      grids.add(grid);
      panel.onDidDispose(() => {
        grids.delete(grid);
        grid.dispose();
      });
    },
  };
  const disposable = vscode.Disposable.from(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, provider),
    vscode.commands.registerCommand("yaml+lsp.grid.open", (uri) => {
      const target = uri instanceof vscode.Uri ? uri : vscode.window.activeTextEditor?.document.uri;
      if (target) vscode.commands.executeCommand("vscode.openWith", target, VIEW_TYPE);
    }),
  );
  return {
    disposable,
    // grids opened before the server was up show that it is missing
    restarted: () => { for (const grid of grids) grid.update(); },
  };
}

class Grid {
  constructor(context, document, panel, getClient) {
    this.document = document;
    this.panel = panel;
    this.getClient = getClient;
    this.timer = undefined;
    this.sequence = 0; // of updates, so that a late answer cannot undo a newer one
    const dist = vscode.Uri.joinPath(context.extensionUri, "dist", "grid");
    panel.webview.options = { enableScripts: true, localResourceRoots: [dist] };
    panel.webview.html = html(panel.webview, dist);
    this.subscriptions = [
      vscode.workspace.onDidChangeTextDocument((event) => {
        if (event.document !== document) return;
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.update(), UPDATE_DELAY_MS);
      }),
      panel.webview.onDidReceiveMessage((message) => this.receive(message)),
    ];
  }

  get json() {
    return ["json", "jsonc"].includes(this.document.languageId);
  }

  // the client if it can be asked now
  client() {
    const client = this.getClient();
    return client && client.isRunning() ? client : undefined;
  }

  async update() {
    clearTimeout(this.timer);
    const sequence = ++this.sequence;
    const client = this.client();
    let message;
    if (!client) {
      message = { type: "update", documents: null, error: { message: notRunning, line: 0, character: 0 } };
    } else {
      try {
        const result = await client.sendRequest("nimyaml/grid",
          { text: this.document.getText(), json: this.json });
        message = { type: "update", ...result };
      } catch (e) {
        message = { type: "update", documents: null,
          error: { message: `yamllsp could not read the file: ${e.message}`, line: 0, character: 0 } };
      }
    }
    if (sequence === this.sequence) this.panel.webview.postMessage(message);
  }

  async receive(message) {
    switch (message.type) {
      case "ready":
        await this.update();
        break;
      case "assign":
      case "rename": {
        const error = await this.edit(message);
        this.panel.webview.postMessage({ type: "editResult", id: message.id, error });
        break;
      }
    }
  }

  /** Applies an edit of the webview; returns why it failed, if it did. */
  async edit(message) {
    const client = this.client();
    if (!client) return notRunning;
    const { document } = this;
    const version = document.version;
    const text = document.getText();
    const params = { text, json: this.json, document: message.document, path: message.path };
    if (message.type === "assign") params.value = message.value;
    else params.name = message.name;
    let result;
    try {
      result = await client.sendRequest("nimyaml/gridEdit", params);
    } catch (e) {
      return e.message;
    }
    if (document.version !== version) {
      return "The file changed while the edit was computed; try again.";
    }
    const change = minimalEdit(text, result.text);
    if (!change) return undefined;
    const edit = new vscode.WorkspaceEdit();
    edit.replace(document.uri,
      new vscode.Range(document.positionAt(change.start), document.positionAt(change.end)),
      change.text);
    return (await vscode.workspace.applyEdit(edit)) ? undefined : "VS Code did not apply the edit.";
  }

  dispose() {
    clearTimeout(this.timer);
    for (const s of this.subscriptions) s.dispose();
  }
}

const notRunning =
  "yamllsp is not running, and the grid needs it to read the file. " +
  "Run “YAML+: Restart yamllsp” once it is on PATH or `yaml+lsp.path` is set.";

// The page loads only the bundle and stylesheet in dist/grid, with a nonce
// for the script, as the webview guide recommends.
function html(webview, dist) {
  const nonce = crypto.randomBytes(16).toString("base64");
  const script = webview.asWebviewUri(vscode.Uri.joinPath(dist, "main.js"));
  const style = webview.asWebviewUri(vscode.Uri.joinPath(dist, "grid.css"));
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="Content-Security-Policy"
    content="default-src 'none'; style-src ${webview.cspSource}; script-src 'nonce-${nonce}';">
  <link href="${style}" rel="stylesheet">
  <title>YAML+ Grid</title>
</head>
<body>
  <div id="grid"></div>
  <script nonce="${nonce}" src="${script}"></script>
</body>
</html>`;
}

module.exports = { registerGrid, VIEW_TYPE };
