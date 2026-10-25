// Schemas: JSON Schemas yamllsp cannot read itself, given by VS Code.
//
// VS Code validates its own files (extension manifests, settings,
// keybindings, tasks, launch configurations, ...) with schemas it builds at
// runtime from the installed extensions and localizes into the display
// language. They are served as `vscode://schemas/...` and exist nowhere
// else, so a YAML document that names one, like the
// `%SCHEMA vscode://schemas/vscode-extensions` of package.yaml, can only be
// validated with VS Code's help.
//
// The other is `https:`: yamllsp never accesses the network, so schemas on
// the web (https://www.schemastore.org/package.json) are downloaded here,
// as VS Code's JSON support does, and only while its
// `json.schemaDownload.enable` allows it. The project can forbid them too,
// with `validate: {remote-schemas: false}` in its `.yaml` config; yamllsp
// then does not ask for them.
//
// yamllsp is told in `initialize` which schemes the client serves
// (`initializationOptions`), asks for a schema of them with
// `nimyaml/schemaContent`, and keeps the answer (see tools/yamllsp.nim).
// VS Code changes a schema when, say, an extension that contributes
// settings is installed, and downloads may be switched on or off; then
// yamllsp is sent `nimyaml/schemaChanged` and asks again.

const vscode = require("vscode");

// the URI schemes of the schemas given to yamllsp
const SCHEMES = ["vscode", "https"];

const initializationOptions = { schemaContentSchemes: SCHEMES };

function downloadsEnabled() {
  return vscode.workspace.getConfiguration("json").get("schemaDownload.enable", true);
}

// the text of the `https:` schema `uri`
async function download(uri) {
  if (!downloadsEnabled()) {
    throw new Error("schema download is disabled (json.schemaDownload.enable)");
  }
  let response;
  try {
    response = await fetch(uri, { headers: { Accept: "application/json, application/yaml, */*" } });
  } catch (e) {
    throw new Error(`cannot download ${uri}: ${e.message}`);
  }
  if (!response.ok) {
    throw new Error(`cannot download ${uri}: HTTP ${response.status} ${response.statusText}`);
  }
  return response.text();
}

/**
 * Answers yamllsp's requests for schemas and watches the ones given to it.
 * `getClient()` is yamllsp's current client, replaced on restart. Returns
 * the disposable and `attach(client)`, to be called with each new client
 * before it starts.
 */
function registerSchemas(getClient) {
  // VS Code's form of each `vscode:` URI given to the current client -> as
  // asked; and every `https:` URI asked for, given or not
  const given = new Map();
  const downloads = new Set();

  function attach(client) {
    given.clear();
    downloads.clear();
    client.onRequest("nimyaml/schemaContent", async ({ uri }) => {
      const parsed = vscode.Uri.parse(uri);
      if (parsed.scheme === "https") {
        downloads.add(uri);
        return download(uri);
      }
      if (parsed.scheme !== "vscode") {
        throw new Error(`VS Code does not serve ${uri}`);
      }
      const document = await vscode.workspace.openTextDocument(parsed);
      given.set(parsed.toString(), uri);
      return document.getText();
    });
  }

  function changed(uri) {
    const client = getClient();
    if (client && client.isRunning()) {
      client.sendNotification("nimyaml/schemaChanged", { uri });
    }
  }

  const disposable = vscode.Disposable.from(
    vscode.workspace.onDidChangeTextDocument((event) => {
      const uri = given.get(event.document.uri.toString());
      if (uri) changed(uri);
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("json.schemaDownload.enable")) {
        for (const uri of downloads) changed(uri);
      }
    }),
  );

  return { disposable, attach };
}

module.exports = { registerSchemas, initializationOptions };
