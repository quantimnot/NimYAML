// Semantic diff: what changed between two YAML or JSON texts, by meaning
// rather than by line. Key order, styles, quotes, comments, anchors and
// aliases make no difference, numbers are compared by value, and an item
// inserted into a sequence is one change, not a change of every item after
// it; YAML can be compared with JSON.
//
// Four commands compare the active editor with a file, with its saved
// version or with its version in git's HEAD, or two files selected in the
// explorer. The changes are listed in a quick pick, like "Go to Path…":
// the one selected is shown in its text, the old one beside the new one,
// and the quick pick's buttons open the JSON Patch that makes the changes,
// or VS Code's text diff.
//
// yamllsp compares (`nimyaml/diff`, see tools/yamllsp.nim). It is given
// the texts, so unsaved editors, JSON files and versions that are not
// files work alike; versions that are not files are shown read-only
// through a content provider.

const vscode = require("vscode");
const path = require("path");
const { sideOf, summary, pickItems, isJson, errorMessage } = require("./format");

const SCHEME = "yaml+lsp-diff";
const LANGUAGES = ["yaml", "json", "jsonc"];

/**
 * Registers the commands and the content provider of versions that are
 * not files. `getClient()` is yamllsp's current client, replaced on restart.
 */
function registerDiff(getClient) {
  // texts of versions that are not files, by the path of their URI
  const versions = new Map();
  const provider = {
    provideTextDocumentContent: (uri) => versions.get(uri.path) ?? "",
  };

  const client = () => {
    const c = getClient();
    return c && c.isRunning() ? c : undefined;
  };

  function format() {
    return vscode.workspace.getConfiguration("yaml+lsp.paths").get("format");
  }

  /** A side that is an open document, as its text is now. */
  function documentSide(document) {
    return {
      label: path.basename(document.uri.path),
      uri: document.uri,
      text: document.getText(),
      json: isJson(document.languageId),
    };
  }

  /** A side that is a file, as it is saved. */
  async function fileSide(uri) {
    const bytes = await vscode.workspace.fs.readFile(uri);
    return {
      label: path.basename(uri.path),
      uri,
      text: Buffer.from(bytes).toString("utf8"),
      json: isJson(uri.path),
    };
  }

  /**
   * A side that is a version of `uri` with no file of its own, shown
   * read-only as `yaml+lsp-diff:/VERSION/…/NAME`, so that it keeps the
   * name, and thus the language, of the file.
   */
  function versionSide(uri, version, text) {
    const versionPath = `/${version}${uri.path}`;
    versions.set(versionPath, text);
    return {
      label: `${path.basename(uri.path)} (${version})`,
      uri: vscode.Uri.from({ scheme: SCHEME, path: versionPath }),
      text,
      json: isJson(uri.path),
    };
  }

  function activeDocument() {
    const editor = vscode.window.activeTextEditor;
    if (editor && LANGUAGES.includes(editor.document.languageId)) return editor.document;
    vscode.window.showWarningMessage("Semantic diff compares YAML, JSON and JSONC files.");
    return undefined;
  }

  const range = (r) => new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character);

  async function compare(old, now) {
    const c = client();
    if (!c) {
      vscode.window.showWarningMessage("yamllsp is not running.");
      return;
    }
    let result;
    try {
      result = await c.sendRequest("nimyaml/diff", {
        old: { text: old.text, json: old.json },
        new: { text: now.text, json: now.json },
        patch: true,
      });
    } catch (e) {
      vscode.window.showErrorMessage(`yamllsp could not compare: ${e.message}`);
      return;
    }
    const labels = { old: old.label, new: now.label };
    if (result.error) {
      vscode.window.showErrorMessage(`Cannot compare: ${errorMessage(result.error, labels)}`);
      return;
    }
    const title = `${old.label} ↔ ${now.label}`;
    const textDiff = () => vscode.commands.executeCommand("vscode.diff", old.uri, now.uri, title);
    if (result.changes.length === 0) {
      const choice = await vscode.window.showInformationMessage(
        `${old.label} and ${now.label} mean the same.`, "Open Text Diff");
      if (choice) textDiff();
      return;
    }
    showChanges(result, old, now, title, textDiff);
  }

  function showChanges(result, old, now, title, textDiff) {
    const patchButton = { iconPath: new vscode.ThemeIcon("json"), tooltip: "Open as JSON Patch" };
    const diffButton = { iconPath: new vscode.ThemeIcon("diff"), tooltip: "Open Text Diff" };
    const pick = vscode.window.createQuickPick();
    pick.title = `${title}: ${summary(result.changes)}`;
    pick.placeholder = "Change to show";
    pick.items = pickItems(result, format());
    pick.matchOnDescription = true;
    pick.buttons = result.patch === undefined ? [diffButton] : [patchButton, diffButton];
    // the new side where the active editor is, the old one beside it
    const columns = { new: vscode.window.activeTextEditor?.viewColumn ?? vscode.ViewColumn.One };
    columns.old = columns.new === vscode.ViewColumn.One ? vscode.ViewColumn.Two : vscode.ViewColumn.One;

    async function show(change, focus) {
      const side = sideOf(change);
      const at = change[side + "Range"];
      const { uri } = side === "old" ? old : now;
      if (!at || !uri) return;
      const document = await vscode.workspace.openTextDocument(uri);
      const editor = await vscode.window.showTextDocument(document, {
        viewColumn: columns[side], preserveFocus: !focus, preview: true,
      });
      editor.selection = new vscode.Selection(range(at).start, range(at).end);
      editor.revealRange(range(at), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
    }

    pick.onDidChangeActive(([active]) => {
      if (active?.change) show(active.change, false);
    });
    pick.onDidAccept(() => {
      const change = pick.selectedItems[0]?.change;
      if (!change) return;
      pick.hide();
      show(change, true);
    });
    pick.onDidTriggerButton(async (button) => {
      pick.hide();
      if (button === diffButton) {
        textDiff();
        return;
      }
      const document = await vscode.workspace.openTextDocument({
        language: now.json ? "json" : "yaml",
        content: result.patch,
      });
      vscode.window.showTextDocument(document, { viewColumn: vscode.ViewColumn.Beside });
    });
    pick.onDidHide(() => pick.dispose());
    pick.show();
  }

  async function withFile() {
    const document = activeDocument();
    if (!document) return;
    const [uri] = await vscode.window.showOpenDialog({
      title: `Compare ${path.basename(document.uri.path)} with`,
      openLabel: "Compare",
      defaultUri: document.uri.scheme === "file" ? document.uri : undefined,
      filters: { "YAML and JSON": ["yaml", "yml", "json", "jsonc"], "All files": ["*"] },
    }) ?? [];
    if (!uri) return;
    await compare(await fileSide(uri), documentSide(document));
  }

  async function withSaved() {
    const document = activeDocument();
    if (!document) return;
    if (document.isUntitled) {
      vscode.window.showWarningMessage("The file has not been saved yet.");
      return;
    }
    const saved = await fileSide(document.uri);
    await compare(versionSide(document.uri, "saved", saved.text), documentSide(document));
  }

  async function withHead() {
    const document = activeDocument();
    if (!document) return;
    const git = vscode.extensions.getExtension("vscode.git");
    let text;
    try {
      if (!git) throw new Error("VS Code's Git extension is not enabled");
      const api = (git.isActive ? git.exports : await git.activate()).getAPI(1);
      const repository = api.getRepository(document.uri);
      if (!repository) throw new Error("the file is not in a git repository");
      text = await repository.show("HEAD", document.uri.fsPath);
    } catch (e) {
      vscode.window.showErrorMessage(`Cannot read the file in HEAD: ${e?.message ?? e}`);
      return;
    }
    await compare(versionSide(document.uri, "HEAD", text), documentSide(document));
  }

  // from the explorer: the file clicked and all files selected
  async function selected(clicked, all) {
    const uris = all?.length ? all : [clicked].filter(Boolean);
    if (uris.length !== 2) {
      vscode.window.showWarningMessage("Select two files to compare.");
      return;
    }
    // an open document as it is now, unsaved changes and all
    const side = (uri) => {
      const open = vscode.workspace.textDocuments.find((d) => d.uri.toString() === uri.toString());
      return open ? documentSide(open) : fileSide(uri);
    };
    await compare(await side(uris[0]), await side(uris[1]));
  }

  return vscode.Disposable.from(
    vscode.workspace.registerTextDocumentContentProvider(SCHEME, provider),
    vscode.commands.registerCommand("yaml+lsp.diff.withFile", withFile),
    vscode.commands.registerCommand("yaml+lsp.diff.withSaved", withSaved),
    vscode.commands.registerCommand("yaml+lsp.diff.withHead", withHead),
    vscode.commands.registerCommand("yaml+lsp.diff.selected", selected),
  );
}

module.exports = { registerDiff };
