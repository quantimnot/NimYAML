// Schemas: VS Code's own JSON Schemas, for yamllsp.
//
// VS Code validates its own files (extension manifests, settings,
// keybindings, tasks, launch configurations, ...) with schemas it builds at
// runtime from the installed extensions and localizes into the display
// language. They are served as `vscode://schemas/...` and exist nowhere
// else, so a YAML document that names one, like the
// `# yaml-language-server: $schema=vscode://schemas/vscode-extensions` of
// package.yaml, can only be validated with VS Code's help.
//
// yamllsp is told in `initialize` which schemes the client serves
// (`initializationOptions`), asks for a schema of them with
// `nimyaml/schemaContent`, and keeps the answer (see tools/yamllsp.nim).
// VS Code changes a schema when, say, an extension that contributes
// settings is installed; then yamllsp is sent `nimyaml/schemaChanged` and
// asks again.

const vscode = require("vscode");

// the URI schemes of the schemas VS Code serves
const SCHEMES = ["vscode"];

const initializationOptions = { schemaContentSchemes: SCHEMES };

/**
 * Watches the schemas given to yamllsp. `getClient()` is yamllsp's current
 * client, replaced on restart. Returns the disposable and `attach(client)`,
 * to be called with each new client before it starts.
 */
function registerSchemas(getClient) {
  // VS Code's form of each URI given to the current client -> as asked
  const given = new Map();

  function attach(client) {
    given.clear();
    client.onRequest("nimyaml/schemaContent", async ({ uri }) => {
      const parsed = vscode.Uri.parse(uri);
      if (!SCHEMES.includes(parsed.scheme)) {
        throw new Error(`VS Code does not serve ${uri}`);
      }
      const document = await vscode.workspace.openTextDocument(parsed);
      given.set(parsed.toString(), uri);
      return document.getText();
    });
  }

  const disposable = vscode.workspace.onDidChangeTextDocument((event) => {
    const uri = given.get(event.document.uri.toString());
    const client = getClient();
    if (uri && client && client.isRunning()) {
      client.sendNotification("nimyaml/schemaChanged", { uri });
    }
  });

  return { disposable, attach };
}

module.exports = { registerSchemas, initializationOptions };
