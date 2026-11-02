// Schema inference: the JSON Schema that some example documents have in
// common, as a starting point for one written by hand. Each location gets
// the types seen there, the members of its objects (and, as `required`,
// those every object has) and one schema for the items of its arrays; see
// yaml/schemainfer.nim for the rules, which the `yaml+lsp.infer.*`
// settings adjust.
//
// Two commands: one infers from the active YAML, JSON, JSONC or JSON Lines
// editor (all its documents), the other from the files selected in the
// explorer, together. The schema opens in a new untitled YAML editor, to
// be saved where it belongs.
//
// yamllsp infers (`nimyaml/inferSchema`, see tools/yamllsp.nim). It is
// given the texts, not URIs, so unsaved editors and files that are not
// open work alike; `yaml schema` does the same on the command line.

const vscode = require("vscode");
const path = require("path");
const { inputFormat, inferOptions, requestParams, schemaDocument, errorMessage } =
  require("./format");

/**
 * Registers the commands. `getClient()` is yamllsp's current client,
 * replaced on restart.
 */
function registerInfer(getClient) {
  const client = () => {
    const c = getClient();
    return c && c.isRunning() ? c : undefined;
  };

  function options() {
    const config = vscode.workspace.getConfiguration("yaml+lsp.infer");
    return inferOptions((name, fallback) => config.get(name, fallback));
  }

  /** An input that is an open document, as its text is now. */
  function documentInput(document, format) {
    return { label: path.basename(document.uri.path), text: document.getText(), ...format };
  }

  /** An input that is a file: its open document if there is one, else as saved. */
  async function fileInput(uri, format) {
    const open = vscode.workspace.textDocuments.find((d) => d.uri.toString() === uri.toString());
    if (open) return documentInput(open, format);
    const bytes = await vscode.workspace.fs.readFile(uri);
    return { label: path.basename(uri.path), text: Buffer.from(bytes).toString("utf8"), ...format };
  }

  async function infer(inputs) {
    const c = client();
    if (!c) {
      vscode.window.showWarningMessage("yamllsp is not running.");
      return;
    }
    let result;
    try {
      result = await c.sendRequest("nimyaml/inferSchema", requestParams(inputs, options()));
    } catch (e) {
      vscode.window.showErrorMessage(`yamllsp could not infer a schema: ${e.message}`);
      return;
    }
    const labels = inputs.map((input) => input.label);
    if (result.error) {
      vscode.window.showErrorMessage(`Cannot infer a schema: ${errorMessage(result.error, labels)}`);
      return;
    }
    if (result.documents === 0) {
      vscode.window.showWarningMessage("There are no documents to infer a schema from.");
      return;
    }
    const document = await vscode.workspace.openTextDocument({
      language: "yaml",
      content: schemaDocument(result.schema, labels, result.documents),
    });
    await vscode.window.showTextDocument(document, { viewColumn: vscode.ViewColumn.Beside });
  }

  async function fromDocument() {
    const document = vscode.window.activeTextEditor?.document;
    const format = document && inputFormat(document.languageId);
    if (!format) {
      vscode.window.showWarningMessage(
        "A schema is inferred from YAML, JSON, JSONC and JSON Lines files.");
      return;
    }
    await infer([documentInput(document, format)]);
  }

  // from the explorer: the file clicked and all files selected
  async function fromSelected(clicked, all) {
    const uris = all?.length ? all : [clicked].filter(Boolean);
    const readable = uris.filter((uri) => inputFormat(uri.path));
    if (readable.length === 0) {
      vscode.window.showWarningMessage(
        "Select YAML, JSON, JSONC or JSON Lines files to infer a schema from.");
      return;
    }
    if (readable.length < uris.length) {
      vscode.window.showWarningMessage(
        `Skipped ${uris.length - readable.length} file(s) that are not YAML, JSON, JSONC or JSON Lines.`);
    }
    let inputs;
    try {
      inputs = await Promise.all(readable.map((uri) => fileInput(uri, inputFormat(uri.path))));
    } catch (e) {
      vscode.window.showErrorMessage(`Cannot read the files: ${e?.message ?? e}`);
      return;
    }
    await infer(inputs);
  }

  return vscode.Disposable.from(
    vscode.commands.registerCommand("yaml+lsp.infer.fromDocument", fromDocument),
    vscode.commands.registerCommand("yaml+lsp.infer.fromSelected", fromSelected),
  );
}

module.exports = { registerInfer };
