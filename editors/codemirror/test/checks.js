// The demo page's checks, run in it with ?test (demo.js imports this): what a
// person would see, from the server through lsp-client and yamllsp.js into
// <code-editor>. Each check waits for its condition, since the server answers
// a quiet moment after each change, and the results are posted to /result for
// test/browser.mjs, which fails unless every check holds.

const { cm, server, files, editors, show, viewOf, yaml } = window.demo;

// The diagnostics the server last published, per document, from the raw
// transport the page and the client share.
const diagnostics = new Map();
server.transport.subscribe((text) => {
  const message = JSON.parse(text);
  if (message.method === "textDocument/publishDiagnostics") {
    diagnostics.set(message.params.uri, message.params.diagnostics);
  }
});

const results = [];
async function check(name, condition, timeoutMs = 20000) {
  const start = Date.now();
  let value, error;
  while (Date.now() - start < timeoutMs) {
    try { value = await condition(); error = undefined; if (value) break; }
    catch (e) { error = e; }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  results.push({ name, ok: !!value, detail: error ? String(error) : undefined });
}

const CONFIG = "file:///project/config.yaml";
// a violation of the schema's maximum for port, however the message words it
const overMaximum = () => (diagnostics.get(CONFIG) ?? []).some((d) =>
  d.code === "schema-validation" && /maximum|65535/.test(d.message));
const config = () => editors.get("/project/config.yaml");
const inside = (selector) => config().shadowRoot.querySelector(selector);

try {
  await check("lint diagnostics: the lint config makes truthy an error",
    () => (diagnostics.get(CONFIG) ?? []).some((d) => d.code === "truthy" && d.severity === 1));
  await check("schema diagnostics: port is over the schema's maximum",
    overMaximum);
  await check("diagnostics are drawn in the editor", () => inside(".cm-lintRange-error"));
  await check("the server's highlighting is drawn: keys, anchors, directives",
    () => inside(".yamllsp-property.tok-propertyName") && inside(".yamllsp-variable")
      && inside(".yamllsp-keyword"));
  await check("%SCHEMA's reference is a link to schema.yaml",
    () => inside('.cm-yamllsp-link[data-target="file:///project/schema.yaml"]'));

  const view = viewOf(config());
  const portAt = view.state.doc.toString().indexOf("80800");
  view.dispatch({ selection: { anchor: portAt } });
  await check("the panel names the node at the cursor",
    () => inside(".cm-yamllsp-path")?.textContent === "/port");

  // the schema edited in its own editor: config.yaml is validated against the new one
  show("/project/schema.yaml");
  const schemaView = viewOf(editors.get("/project/schema.yaml"));
  const schemaText = schemaView.state.doc.toString();
  const at = schemaText.indexOf("65535");
  schemaView.dispatch({ changes: { from: at, to: at + 5, insert: "100000" }, userEvent: "input.type" });
  await check("an edit of the schema revalidates the document that names it",
    () => files.get("/project/schema.yaml").includes("100000")
      && diagnostics.has(CONFIG) && !overMaximum());

  show("/project/config.yaml");
  cm.formatDocument(view);
  await check("formatting rewrites the document as yaml format would",
    () => view.state.doc.toString().includes("tags: [api, internal]"));

  const inferred = await yaml.inferSchema([files.get("/project/config.yaml")]);
  await check("inferSchema writes a schema of the document",
    () => /properties:/.test(inferred.schema) && /port:/.test(inferred.schema));
} catch (e) {
  results.push({ name: "the checks ran", ok: false, detail: String(e?.stack ?? e) });
}

await fetch("/result", { method: "POST", body: JSON.stringify(results) }).catch(() => {});
window.__results = results;
