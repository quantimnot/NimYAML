// Embedded languages: language features for code in YAML block scalars.
//
// yamllsp reports where the block scalars are (`nimyaml/blockScalars`);
// here a language is chosen for each (core.js), the literal ones are
// written to files of that language (projection.js), and requests in them
// are forwarded to whatever serves those files (providers.js,
// diagnostics.js). Colour comes from the TextMate injection grammar in
// syntaxes/, and from the embedded servers' semantic tokens, merged into
// yamllsp's here.
//
// How much works depends on the language: a server that analyzes any file
// (Python, TypeScript, JSON, CSS, shell) provides everything, diagnostics
// included; one that needs project membership (gopls, rust-analyzer,
// clangd) answers requests but has nothing sound to say about a file
// outside its package or crate; a language without a file extension
// cannot be projected. *NimYAML: Show Embedded Regions* shows what was
// found and why.

const vscode = require("vscode");
const { mergeSemanticTokens } = require("./core");
const { readConfig } = require("./config");
const { LanguageRegistry } = require("./languages");
const { ProjectionStore } = require("./projection");
const { DiagnosticBridge } = require("./diagnostics");
const { registerProviders } = require("./providers");

/**
 * Sets up embedded languages for the documents `selector` matches.
 * `getClient()` is yamllsp's current client, which is replaced on restart.
 * Returns the middleware yamllsp's client must be created with.
 */
async function activateEmbedded(context, selector, getClient) {
  const registry = new LanguageRegistry();
  await registry.refresh();
  const store = new ProjectionStore(registry, (doc) =>
    getClient().sendRequest("nimyaml/blockScalars", { textDocument: { uri: doc.uri.toString() } }));
  const bridge = new DiagnosticBridge(store);
  const timers = new Map();
  const isHost = (doc) => vscode.languages.match(selector, doc) > 0 && !store.isProjection(doc.uri);
  // diagnostics need projections before anyone asks; everything else
  // projects on demand
  const eager = () => readConfig().enabled && readConfig().diagnosticsEnabled;

  const schedule = (doc, delay = readConfig().debounceMs) => {
    const key = doc.uri.toString();
    clearTimeout(timers.get(key));
    timers.set(key, setTimeout(() => {
      timers.delete(key);
      store.ensure(doc).catch((e) => console.error("nimyaml: projection failed", e));
    }, delay));
  };
  const scheduleAll = () => {
    for (const doc of vscode.workspace.textDocuments) if (isHost(doc)) schedule(doc, 0);
  };

  context.subscriptions.push(
    store,
    bridge,
    ...registerProviders(store, selector),
    { dispose: () => timers.forEach((t) => clearTimeout(t)) },
    vscode.workspace.onDidOpenTextDocument((doc) => {
      if (isHost(doc) && eager()) schedule(doc, 0);
    }),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (isHost(e.document) && eager()) schedule(e.document);
    }),
    vscode.workspace.onDidCloseTextDocument(async (doc) => {
      if (!isHost(doc)) return;
      clearTimeout(timers.get(doc.uri.toString()));
      bridge.clear(doc.uri);
      await store.forget(doc.uri);
    }),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (!e.affectsConfiguration("nimyaml.embedded")) return;
      if (!readConfig().enabled) {
        await store.cleanAll();
        for (const doc of vscode.workspace.textDocuments) bridge.clear(doc.uri);
        return;
      }
      // regions depend on the settings, but the document versions did not change
      store.hosts.clear();
      if (eager()) await ensureExcludes();
      scheduleAll();
    }),
    vscode.extensions.onDidChange(() => registry.refresh()),
    vscode.commands.registerCommand("nimyaml.embedded.formatRegion", () => formatRegion(store)),
    vscode.commands.registerCommand("nimyaml.embedded.revealProjection", () => revealProjection(store)),
    vscode.commands.registerCommand("nimyaml.embedded.showRegions", () => showRegions(store)),
    vscode.commands.registerCommand("nimyaml.embedded.cleanProjections", () => store.cleanAll()),
  );

  if (eager()) {
    await ensureExcludes();
    scheduleAll();
  }

  return {
    middleware: { provideDocumentSemanticTokens: semanticTokens(store, getClient) },
    /** Projections are temporary; deleting them is part of deactivating. */
    dispose: () => store.cleanAll(),
    /** yamllsp (re)started: what it was asked before may have failed. */
    restarted: () => {
      store.hosts.clear();
      if (eager()) scheduleAll();
    },
  };
}

/**
 * yamllsp reports a block scalar's content as one string, which would cover
 * the colours of the embedded grammar; on the regions' lines its tokens are
 * replaced by the embedded server's (core.js: `mergeSemanticTokens`).
 */
function semanticTokens(store, getClient) {
  return async (document, token, next) => {
    const tokens = await next(document, token);
    if (!tokens || store.isProjection(document.uri)) return tokens;
    const projections = await store.ensure(document);
    if (!projections.length) return tokens;
    const legend = getClient()?.initializeResult?.capabilities?.semanticTokensProvider?.legend;
    if (!legend) return tokens;
    const embedded = [];
    for (const p of projections) {
      const forwarded = { map: p.map.core, legend: { tokenTypes: [], tokenModifiers: [] }, data: [] };
      if (readConfig().semanticTokensEnabled) {
        const [l, t] = await Promise.all([
          vscode.commands.executeCommand("vscode.provideDocumentSemanticTokensLegend", p.uri),
          vscode.commands.executeCommand("vscode.provideDocumentSemanticTokens", p.uri),
        ]);
        if (l && t) Object.assign(forwarded, { legend: l, data: t.data });
      }
      embedded.push(forwarded);
    }
    return new vscode.SemanticTokens(mergeSemanticTokens(tokens.data, legend, embedded));
  };
}

const notInRegion = () =>
  vscode.window.showInformationMessage("The cursor is not in an embedded language region.");

/**
 * Formats the region at the cursor. A command, not a formatter: a YAML
 * formatter formats the whole document, so registering one would either
 * lose to the user's YAML formatter or replace it everywhere but in the
 * regions; the cost is no format on save.
 */
async function formatRegion(store) {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return;
  const p = await store.at(editor.document, editor.selection.active);
  if (!p) return notInRegion();
  const edits = await vscode.commands.executeCommand("vscode.executeFormatDocumentProvider",
    p.uri, { tabSize: editor.options.tabSize, insertSpaces: editor.options.insertSpaces });
  if (!edits?.length) {
    vscode.window.showInformationMessage(`No formatter changed this ${p.region.languageId} region.`);
    return;
  }
  const edit = new vscode.WorkspaceEdit();
  edit.set(editor.document.uri, edits.map((e) => p.map.toHostEdit(e)));
  await vscode.workspace.applyEdit(edit);
}

/** Opens the projection of the region at the cursor, to see what the server sees. */
async function revealProjection(store) {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return;
  const p = await store.at(editor.document, editor.selection.active);
  if (!p) return notInRegion();
  await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(p.uri),
    { viewColumn: vscode.ViewColumn.Beside, preview: true });
}

async function showRegions(store) {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return;
  const projections = await store.ensure(editor.document);
  const items = [
    ...projections.map((p) => ({
      label: `${p.region.key ?? "(no key)"}: ${p.region.languageId}`,
      description: `lines ${p.region.start + 1}-${p.region.end + 1}, indentation ` +
        `${p.region.indent}, from the ${p.region.provenance.replace("-", " ")}`,
      detail: p.uri.fsPath,
      line: p.region.headerLine,
    })),
    ...store.foldedOf(editor.document.uri).map((f) => ({
      label: `(folded, not served): ${f.languageId}`,
      description: "folding joins lines; use a literal block scalar (|)",
      line: f.headerLine,
    })),
  ];
  if (!items.length) {
    vscode.window.showInformationMessage("No embedded language regions in this document.");
    return;
  }
  const pick = await vscode.window.showQuickPick(items, { title: "Embedded language regions" });
  if (!pick) return;
  const position = new vscode.Position(pick.line, 0);
  editor.selection = new vscode.Selection(position, position);
  editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenter);
}

/** Hides the projection directory from the explorer and search. */
async function ensureExcludes() {
  const cfg = readConfig();
  if (!cfg.manageExcludes || cfg.projectionRoot !== "workspace") return;
  if (!vscode.workspace.workspaceFolders?.length) return;
  const glob = `**/${cfg.projectionDirectory}`;
  for (const [section, property] of [["files", "exclude"], ["search", "exclude"]]) {
    const config = vscode.workspace.getConfiguration(section);
    const current = config.get(property) ?? {};
    if (current[glob]) continue;
    try {
      await config.update(property, { ...current, [glob]: true },
        vscode.ConfigurationTarget.Workspace);
    } catch (_) {
      // read-only settings: the projections stay visible
    }
  }
}

module.exports = { activateEmbedded };
