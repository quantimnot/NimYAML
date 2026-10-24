// Paths: where the cursor is, as a JSON Pointer or a JSON Path, and
// navigation by them, after skorth/vscode-yamlnav.
//
// The status bar shows the path of the node at the cursor and copies it
// when clicked; "Copy JSON Pointer" and "Copy JSON Path" in the editor's
// context menu copy either. "Go to Path…" lists every node of the file by
// its path, with the values of scalars, and moves the cursor to the one
// picked, previewing each as it is selected.
//
// yamllsp names the nodes (`nimyaml/pathAt` and `nimyaml/paths`, see
// tools/yamllsp.nim). Like the grid, it is given the text rather than the
// URI, so JSON and JSONC files, which it is not given as documents, work
// too; and a text being typed keeps the paths up to its first error.

const vscode = require("vscode");
const { formatOf, pathText, displayText, pickItems } = require("./format");

const LANGUAGES = ["yaml", "json", "jsonc"];
// cursor moves and typing wait this long before the status bar is updated
const UPDATE_DELAY_MS = 100;

function config() {
  return vscode.workspace.getConfiguration("yaml+lsp.paths");
}

function supported(editor) {
  return editor && LANGUAGES.includes(editor.document.languageId);
}

function params(document) {
  return { text: document.getText(), json: document.languageId !== "yaml" };
}

/**
 * Registers the status bar item and the commands. `getClient()` is
 * yamllsp's current client, replaced on restart. Returns the disposable and
 * `restarted()`, to be called when a client has started.
 */
function registerPaths(getClient) {
  const item = vscode.window.createStatusBarItem("yaml+lsp.paths",
    vscode.StatusBarAlignment.Right, 100);
  item.name = "YAML+ Path";
  let timer;
  let sequence = 0; // of updates, so that a late answer cannot undo a newer one

  const client = () => {
    const c = getClient();
    return c && c.isRunning() ? c : undefined;
  };

  // the node at the cursor of `editor`, or null
  async function nodeAt(editor) {
    const c = client();
    if (!c) return null;
    const { line, character } = editor.selection.active;
    try {
      return await c.sendRequest("nimyaml/pathAt",
        { ...params(editor.document), position: { line, character } });
    } catch (_) {
      return null; // e.g. a yamllsp without the request
    }
  }

  async function update() {
    clearTimeout(timer);
    const current = ++sequence;
    const editor = vscode.window.activeTextEditor;
    if (!config().get("statusBar", true) || !supported(editor)) {
      item.hide();
      return;
    }
    const node = await nodeAt(editor);
    if (current !== sequence) return;
    if (!node) {
      item.hide();
      return;
    }
    const format = formatOf(config().get("format"));
    item.text = `$(symbol-key) ${displayText(node, config().get("format"))}`;
    item.tooltip = `${format.name} of the node at the cursor` +
      (node.documents > 1 ? `, in document ${node.document + 1} of ${node.documents}` : "") +
      ". Click to copy it.";
    item.command = {
      title: `Copy ${format.name}`,
      command: format.key === "path" ? "yaml+lsp.paths.copyPath" : "yaml+lsp.paths.copyPointer",
    };
    item.show();
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(update, UPDATE_DELAY_MS);
  }

  async function copy(name) {
    const editor = vscode.window.activeTextEditor;
    if (!supported(editor)) return;
    const node = await nodeAt(editor);
    if (!node) {
      vscode.window.showWarningMessage(client()
        ? `No node at the cursor has a ${formatOf(name).name}.`
        : "yamllsp is not running.");
      return;
    }
    const text = pathText(node, name);
    await vscode.env.clipboard.writeText(text);
    vscode.window.setStatusBarMessage(`Copied ${formatOf(name).name} ${text || "(root)"}`, 2000);
  }

  async function goTo() {
    const editor = vscode.window.activeTextEditor;
    if (!supported(editor)) return;
    const c = client();
    if (!c) {
      vscode.window.showWarningMessage("yamllsp is not running.");
      return;
    }
    const document = editor.document;
    let nodes;
    try {
      ({ nodes } = await c.sendRequest("nimyaml/paths", params(document)));
    } catch (e) {
      vscode.window.showErrorMessage(`yamllsp could not list the paths: ${e.message}`);
      return;
    }
    const rangeOf = (node) => new vscode.Range(
      node.range.start.line, node.range.start.character,
      node.range.end.line, node.range.end.character);
    const pick = vscode.window.createQuickPick();
    pick.items = pickItems(nodes, config().get("format"));
    pick.placeholder = `${formatOf(config().get("format")).name} of the node to go to`;
    pick.matchOnDescription = true;
    const selections = editor.selections;
    const visible = editor.visibleRanges[0];
    let accepted = false;
    pick.onDidChangeActive(([active]) => {
      if (active?.node) {
        editor.revealRange(rangeOf(active.node), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
      }
    });
    pick.onDidAccept(() => {
      const node = pick.selectedItems[0]?.node;
      if (!node) return;
      accepted = true;
      pick.hide();
      const start = rangeOf(node).start;
      editor.selection = new vscode.Selection(start, start);
      editor.revealRange(rangeOf(node), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
      vscode.window.showTextDocument(document, editor.viewColumn);
    });
    pick.onDidHide(() => {
      pick.dispose();
      if (!accepted) {
        editor.selections = selections;
        if (visible) editor.revealRange(visible, vscode.TextEditorRevealType.AtTop);
      }
    });
    pick.show();
  }

  const disposable = vscode.Disposable.from(
    item,
    vscode.commands.registerCommand("yaml+lsp.paths.copyPointer", () => copy("pointer")),
    vscode.commands.registerCommand("yaml+lsp.paths.copyPath", () => copy("path")),
    vscode.commands.registerCommand("yaml+lsp.paths.goTo", goTo),
    vscode.window.onDidChangeActiveTextEditor(update),
    vscode.window.onDidChangeTextEditorSelection((event) => {
      if (event.textEditor === vscode.window.activeTextEditor) schedule();
    }),
    vscode.workspace.onDidChangeTextDocument((event) => {
      if (event.document === vscode.window.activeTextEditor?.document) schedule();
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("yaml+lsp.paths")) update();
    }),
    { dispose: () => clearTimeout(timer) },
  );
  return { disposable, restarted: update };
}

module.exports = { registerPaths };
