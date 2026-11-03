// yamllsp for CodeMirror 6: NimYAML's language server, connected to an editor.
//
// The server is NimYAML's own, compiled to JavaScript and run in a worker by
// js/lsp/transport.mjs; @codemirror/lsp-client speaks LSP to it. Most of what
// the server offers that client already turns into editor features —
// diagnostics, completion, hover, go to definition, formatting — so this module
// adds only what it does not, and what yamllsp has beyond LSP's common ground:
//
// * the server's highlighting (`textDocument/semanticTokens/full`), which is
//   how NimYAML's lexer reads the text: keys, scalars by the type they resolve
//   to, tags, anchors, `%GLOBAL` and `%SCHEMA`. It is drawn over the YAML
//   grammar's colours, not instead of them, since the grammar colours at once
//   and the server a moment later;
// * document links (`textDocument/documentLink`), the schema references of
//   `%SCHEMA` and its kin, opened with Ctrl/Cmd+click;
// * the JSON Pointer of the node at the cursor (`nimyaml/pathAt`), in a panel;
// * the schemas the server may not read itself. yamllsp never touches the
//   network: it asks its client for the schemas of the URI schemes the client
//   says it serves (`nimyaml/schemaContent`). lsp-client answers every request
//   of a server with "method not found", so the transport is wrapped here and
//   that request answered by `fetchSchema` before lsp-client sees it.
//
// Everything is made from the CodeMirror the editor itself was made from,
// passed in as `cm`: an extension made from a second copy of @codemirror/state
// is refused by the editor. For <code-editor> that is the codemirror.js beside
// it, which exports lsp-client too. The module imports nothing, so it runs
// unbundled in a page, and its pure parts in Node (test/yamllsp.test.mjs).
//
//   import * as cm from "<components>/code-editor/codemirror.js";
//   import { startServer } from "<nimyaml>/js/lsp/transport.mjs";
//   import { yamlLanguageServer } from "<nimyaml>/editors/codemirror/yamllsp.js";
//
//   const server = startServer({ readFile });
//   const yaml = yamlLanguageServer({ cm, transport: server.transport });
//   editor.extensions = yaml.extensions("file:///project/config.yaml");
//
// Its words, few as they are, are asked of the editor (EditorState.phrase), so
// a host that translates CodeMirror's phrases translates these with them.
//
// Rejected: semantic tokens instead of the grammar, which would leave the text
// uncoloured until the worker has loaded and answered; a client of our own
// rather than lsp-client, which would repeat its document syncing, completion
// and tooltips to add four features.

/**
 * The server's token types → the classes they are drawn with: classHighlighter's
 * tok-* class of the nearest Lezer highlighting tag, which a host such as
 * <code-editor> already colours, and a yamllsp-* class of the type itself for a
 * host that wants to tell them apart. The types are the server's legend
 * (HighlightKind in tools/yamllsp.nim); one it adds later gets only its own.
 */
export const TOKEN_CLASSES = {
  comment: "tok-comment",
  keyword: "tok-keyword",       // directives, ---, ..., null and booleans
  string: "tok-string",
  number: "tok-number",
  property: "tok-propertyName", // mapping keys
  type: "tok-typeName",         // tags
  variable: "tok-labelName",    // anchors and aliases
  operator: "tok-operator",     // indicators, block scalar headers
  namespace: "tok-namespace",   // the handle a %TAG declares
  parameter: "tok-meta",        // parameters of unknown directives
};

/**
 * Decodes LSP's semantic token encoding — five integers per token: its line and
 * start relative to the previous token, its length, its type and its modifiers —
 * into [{line, character, length, type, modifiers}], with types and modifiers
 * named by `legend`. Lines are 0-based; characters count UTF-16 code units, as
 * JavaScript strings and CodeMirror do.
 */
export function decodeSemanticTokens(data, legend) {
  const tokens = [];
  let line = 0, character = 0;
  for (let i = 0; i + 4 < data.length; i += 5) {
    if (data[i] > 0) { line += data[i]; character = 0; }
    character += data[i + 1];
    const modifiers = legend.tokenModifiers.filter((_, bit) => data[i + 4] & (1 << bit));
    tokens.push({ line, character, length: data[i + 2],
                  type: legend.tokenTypes[data[i + 3]], modifiers });
  }
  return tokens;
}

/** The class attribute of a decoded token. */
export function tokenClass({ type, modifiers }) {
  return [TOKEN_CLASSES[type], `yamllsp-${type}`,
          ...modifiers.map((m) => `yamllsp-${m}`)].filter(Boolean).join(" ");
}

/**
 * `transport` with the server's `nimyaml/schemaContent` requests answered by
 * `fetchSchema(uri)` — the schema's text, or a rejection whose message the
 * server reports — and not passed on. Everything else goes through unchanged.
 */
export function answeringSchemas(transport, fetchSchema) {
  const handlers = new Set();
  const reply = (message) => transport.send(JSON.stringify(message));
  transport.subscribe((text) => {
    const message = JSON.parse(text);
    if (message.method !== "nimyaml/schemaContent" || message.id === undefined) {
      for (const handler of handlers) handler(text);
      return;
    }
    Promise.resolve().then(() => fetchSchema(message.params.uri)).then(
      (schema) => reply({ jsonrpc: "2.0", id: message.id, result: schema ?? "" }),
      (e) => reply({ jsonrpc: "2.0", id: message.id,
                     error: { code: -32803, message: String(e?.message ?? e) } }));
  });
  return {
    send: (message) => transport.send(message),
    subscribe: (handler) => handlers.add(handler),
    unsubscribe: (handler) => handlers.delete(handler),
  };
}

/** Fetches an https: schema as the browser would, CORS and all. */
export async function fetchHttpsSchema(uri) {
  const response = await fetch(uri);
  if (!response.ok) throw new Error(`${uri}: HTTP ${response.status}`);
  return response.text();
}

/** Opens a link target in a new tab when it is a web page; others are the host's to open. */
function openWebLink(target) {
  if (/^https?:/i.test(target)) globalThis.open?.(target, "_blank", "noopener");
}

/**
 * Connects an LSPClient to yamllsp over `transport` and returns it, with
 * `extensions(uri)`, everything an editor showing the document `uri` needs.
 *
 *   cm           the CodeMirror namespace the editor was made from
 *   transport    {send, subscribe, unsubscribe}, as js/lsp/transport.mjs gives it
 *   fetchSchema  answers the server's requests for https: schemas; null: none
 *                are served, and the server reports them unavailable
 *   openLink     opens a document link's target; default: web pages in a tab
 *   pathPanel    show the JSON Pointer of the node at the cursor; default true
 *   rootUri      the project's root, if it has one
 */
export function yamlLanguageServer({ cm, transport, fetchSchema = fetchHttpsSchema,
                                     openLink = openWebLink, pathPanel = true,
                                     rootUri = null, timeout = 10000 }) {
  const client = new cm.LSPClient({
    rootUri,
    timeout,
    initializationOptions: { schemaContentSchemes: fetchSchema ? ["https"] : [] },
    extensions: [
      ...cm.languageServerExtensions(),
      { editorExtension: [serverHighlighting(cm), documentLinks(cm, openLink),
                          pathPanel ? cursorPath(cm) : []] },
    ],
  }).connect(fetchSchema ? answeringSchemas(transport, fetchSchema) : transport);

  return {
    client,
    /** The extensions for an editor of the document `uri`. */
    extensions: (uri) => client.plugin(uri, "yaml"),
    /** The path of the node at `pos` in `view`: {pointer, path, document, documents} or null. */
    pathAt: (view, pos = view.state.selection.main.head) => pathAt(client, view, pos),
    /** The JSON Schema of `texts`' documents, as YAML (or JSON with {json: true}). */
    inferSchema: (texts, { json = false, ...options } = {}) =>
      client.request("nimyaml/inferSchema",
        { inputs: texts.map((text) => ({ text })), json, options }),
    /** The changes from `oldText` to `newText`, by meaning rather than by line. */
    diff: (oldText, newText) =>
      client.request("nimyaml/diff", { old: { text: oldText }, new: { text: newText } }),
  };
}

// ---- Decorations the server keeps current ----
//
// Highlighting and links are both a request about the whole document, answered
// with ranges, and asked again after the text changes. One shape serves both:
// a view plugin that, a quiet moment after the last change, syncs the document,
// asks, and draws the answer if the text is still the one it asked about; a
// change made meanwhile has scheduled the next request already, and the old
// decorations are mapped through it until then, so nothing flickers.

const QUIET_MS = 250;

function refreshedDecorations(cm, ask) {
  return cm.ViewPlugin.fromClass(class {
    constructor(view) {
      this.view = view;
      this.decorations = cm.Decoration.none;
      this.asked = 0;
      this.schedule();
    }

    update(update) {
      if (!update.docChanged) return;
      this.decorations = this.decorations.map(update.changes);
      this.schedule();
    }

    schedule() {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => this.refresh(), QUIET_MS);
    }

    async refresh() {
      const plugin = cm.LSPPlugin.get(this.view);
      if (!plugin || this.destroyed) return;
      await plugin.client.initializing;
      plugin.client.sync();
      const doc = this.view.state.doc, asking = ++this.asked;
      let decorations;
      try { decorations = await ask(plugin, doc); }
      catch { return; }   // a ContentModified, or the server is gone: the next change asks again
      if (this.destroyed || asking !== this.asked || this.view.state.doc !== doc || !decorations) return;
      this.decorations = decorations;
      this.view.dispatch({});   // draw it
    }

    destroy() {
      this.destroyed = true;
      clearTimeout(this.timer);
    }
  }, { decorations: (plugin) => plugin.decorations });
}

/** The offset of an LSP position in `doc`, or null past its end. */
function offsetOf(doc, { line, character }) {
  if (line >= doc.lines) return null;
  const text = doc.line(line + 1);
  return Math.min(text.from + character, text.to);
}

// Drawn inside the grammar's own spans (a higher precedence is drawn innermost),
// so that the server's class is the one whose colour shows.
function serverHighlighting(cm) {
  const marks = new Map();   // class → Decoration, shared by every token of a class
  const markFor = (className) => {
    if (!marks.has(className)) marks.set(className, cm.Decoration.mark({ class: className }));
    return marks.get(className);
  };
  return cm.Prec.high(refreshedDecorations(cm, async (plugin, doc) => {
    const legend = plugin.client.serverCapabilities?.semanticTokensProvider?.legend;
    if (!legend) return null;
    const answer = await plugin.client.request("textDocument/semanticTokens/full",
      { textDocument: { uri: plugin.uri } });
    const builder = new cm.RangeSetBuilder();
    for (const token of decodeSemanticTokens(answer?.data ?? [], legend)) {
      const from = offsetOf(doc, token);
      if (from === null) break;
      const to = Math.min(from + token.length, doc.line(token.line + 1).to);
      if (to > from) builder.add(from, to, markFor(tokenClass(token)));
    }
    return builder.finish();
  }));
}

// ---- Document links ----
//
// Underlined, titled with their target, and opened by Ctrl/Cmd+click, as
// editors do: a plain click must still place the caret inside a reference.

function documentLinks(cm, openLink) {
  const links = refreshedDecorations(cm, async (plugin, doc) => {
    if (!plugin.client.serverCapabilities?.documentLinkProvider) return null;
    const answer = await plugin.client.request("textDocument/documentLink",
      { textDocument: { uri: plugin.uri } });
    const ranges = [];
    for (const { range, target } of answer ?? []) {
      const from = offsetOf(doc, range.start), to = offsetOf(doc, range.end);
      if (from === null || to === null || to <= from || !target) continue;
      ranges.push(cm.Decoration.mark({ class: "cm-yamllsp-link",
        attributes: { title: target, "data-target": target } }).range(from, to));
    }
    return cm.Decoration.set(ranges, true);
  });
  const opening = cm.EditorView.domEventHandlers({
    mousedown(event) {
      if (!(event.ctrlKey || event.metaKey) || event.button !== 0) return false;
      const link = event.target.closest?.(".cm-yamllsp-link[data-target]");
      if (!link) return false;
      event.preventDefault();
      openLink(link.getAttribute("data-target"));
      return true;
    },
  });
  const look = cm.EditorView.baseTheme({
    ".cm-yamllsp-link": { textDecoration: "underline dotted", textUnderlineOffset: "2px" },
  });
  return [links, opening, look];
}

// ---- The path at the cursor ----

async function pathAt(client, view, pos) {
  await client.initializing;
  const line = view.state.doc.lineAt(pos);
  return client.request("nimyaml/pathAt", {
    text: view.state.doc.toString(),
    position: { line: line.number - 1, character: pos - line.from },
  });
}

// A panel under the text naming the node at the cursor by its JSON Pointer,
// as a status bar would; clicking it copies the pointer. Asked a quiet moment
// after the cursor or the text last moved, since every request sends the text.
function cursorPath(cm) {
  const look = cm.EditorView.baseTheme({
    ".cm-yamllsp-path": { padding: "2px 8px", minHeight: "1.5em", cursor: "copy",
                          fontFamily: "inherit", whiteSpace: "pre", overflow: "hidden",
                          textOverflow: "ellipsis" },
  });
  return [look, cm.showPanel.of((view) => {
    const dom = document.createElement("div");
    dom.className = "cm-yamllsp-path";
    dom.setAttribute("role", "status");
    dom.setAttribute("aria-label", view.state.phrase("JSON Pointer"));
    dom.title = view.state.phrase("Click to copy");
    dom.translate = false;
    let timer = 0, asked = 0, destroyed = false;
    const refresh = async () => {
      const plugin = cm.LSPPlugin.get(view);
      if (!plugin || destroyed) return;
      const asking = ++asked;
      let found = null;
      try { found = await pathAt(plugin.client, view, view.state.selection.main.head); }
      catch { return; }
      if (destroyed || asking !== asked) return;
      dom.textContent = found
        ? (found.documents > 1 ? `#${found.document + 1} ${found.pointer || "/"}` : found.pointer || "/")
        : "";
      dom.dataset.pointer = found?.pointer ?? "";
    };
    dom.addEventListener("click", () => {
      if (dom.dataset.pointer) navigator.clipboard?.writeText(dom.dataset.pointer).catch(() => {});
    });
    timer = setTimeout(refresh, QUIET_MS);
    return {
      dom,
      update(update) {
        if (!update.docChanged && !update.selectionSet) return;
        clearTimeout(timer);
        timer = setTimeout(refresh, QUIET_MS);
      },
      destroy() { destroyed = true; clearTimeout(timer); },
    };
  })];
}
