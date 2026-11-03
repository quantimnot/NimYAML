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
// * the path of the node at the cursor (`nimyaml/pathAt`), in a panel, as a
//   JSON Pointer (`/a/0`), a JSON Path (`$.a[0]`) or a URL fragment
//   (`config.yaml#/a/0`, or absolute, `file:///…/config.yaml#/a/0`), as the
//   VS Code extension shows it in its status bar, and commands that copy each;
// * the schemas the server may not read itself. yamllsp never touches the
//   network: it asks its client for the schemas of the URI schemes the client
//   says it serves (`nimyaml/schemaContent`). lsp-client answers every request
//   of a server with "method not found", so the transport is wrapped here and
//   that request answered by `fetchSchema` before lsp-client sees it.
//
// Everything is made from the CodeMirror the editor itself was made from,
// passed in as `cm`: an extension made from a second copy of @codemirror/state
// is refused by the editor. For <code-editor> that is the codemirror.js beside
// it, which exports lsp-client too. The module imports nothing of CodeMirror's,
// only its own words (phrases.js), so it runs unbundled in a page, and its pure
// parts in Node (test/yamllsp.test.mjs).
//
//   import * as cm from "<components>/code-editor/codemirror.js";
//   import { startServer } from "<nimyaml>/js/lsp/transport.mjs";
//   import { yamlLanguageServer } from "<nimyaml>/editors/codemirror/yamllsp.js";
//
//   const server = startServer({ readFile });
//   const yaml = yamlLanguageServer({ cm, transport: server.transport });
//   editor.extensions = yaml.extensions("file:///project/config.yaml");
//
// Its words, few as they are, are asked of the editor (EditorState.phrase), and
// translated by phrases.js in the languages of <code-editor>, for the locale
// the page names; a host can add its own phrases over them as for any other.
//
// Rejected: semantic tokens instead of the grammar, which would leave the text
// uncoloured until the worker has loaded and answered; a client of our own
// rather than lsp-client, which would repeat its document syncing, completion
// and tooltips to add four features.

import { phrasesFor } from "./phrases.js";

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

/** The page's language, then the browser's, best first. */
function pageLocales() {
  return [globalThis.document?.documentElement?.lang, ...(globalThis.navigator?.languages ?? [])]
    .filter(Boolean);
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
 *   pathPanel    show the path of the node at the cursor; default true
 *   pathFormat   how the panel shows it: "pointer" (default), "path", "fragment"
 *                or "absoluteFragment"; the panel's menu changes it
 *   onPathFormatChange  called with the format picked in a panel, to keep it
 *   locale       a BCP 47 tag, or a list, best first, for the panel's words;
 *                default: the page's, then the browser's
 *   rootUri      the project's root, if it has one
 */
export function yamlLanguageServer({ cm, transport, fetchSchema = fetchHttpsSchema,
                                     openLink = openWebLink, pathPanel = true,
                                     pathFormat = "pointer", onPathFormatChange = () => {},
                                     locale = pageLocales(), rootUri = null,
                                     timeout = 10000 }) {
  const paths = { format: formatOf(pathFormat).key, panels: new Set(),
                  changed: onPathFormatChange };
  const client = new cm.LSPClient({
    rootUri,
    timeout,
    initializationOptions: { schemaContentSchemes: fetchSchema ? ["https"] : [] },
    extensions: [
      ...cm.languageServerExtensions(),
      { editorExtension: [serverHighlighting(cm), documentLinks(cm, openLink),
                          pathPanel ? cursorPath(cm, paths) : [],
                          cm.EditorState.phrases.of(phrasesFor(locale))] },
    ],
  }).connect(fetchSchema ? answeringSchemas(transport, fetchSchema) : transport);

  /** A command that copies the path at the cursor in `format`. */
  const copying = (format) => (view) => {
    const plugin = cm.LSPPlugin.get(view);
    if (!plugin) return false;
    pathAt(client, view, view.state.selection.main.head).then((node) => {
      if (node) return navigator.clipboard?.writeText(pathText(node, format, plugin.uri));
    }).catch(() => {});   // not focused, or no clipboard: nothing to copy to
    return true;
  };

  return {
    client,
    /** The extensions for an editor of the document `uri`. */
    extensions: (uri) => client.plugin(uri, "yaml"),
    /** The path of the node at `pos` in `view`: {pointer, path, document, documents} or null. */
    pathAt: (view, pos = view.state.selection.main.head) => pathAt(client, view, pos),
    /** The path of the node at `pos` in `view` as text in `format`, or null outside every node. */
    pathText: async (view, format = paths.format, pos = view.state.selection.main.head) => {
      const node = await pathAt(client, view, pos);
      return node && pathText(node, format, cm.LSPPlugin.get(view)?.uri ?? "");
    },
    /** The format the panels show; setting it redraws them. */
    get pathFormat() { return paths.format; },
    set pathFormat(format) { setPathFormat(paths, format); },
    /** Commands (view → boolean) for a keymap or a menu: each copies the path at the cursor. */
    copyPointer: copying("pointer"),
    copyPath: copying("path"),
    copyFragment: copying("fragment"),
    copyAbsoluteFragment: copying("absoluteFragment"),
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

// ---- Path formats ----
//
// The server names a node by its JSON Pointer and its JSON Path; a URL
// fragment is the pointer after the document's URL (RFC 6901, section 6, and
// RFC 9512 for YAML), relative (`config.yaml#/a/0`, from the file's own
// directory, as a `$ref` beside it would say it) or absolute
// (`file:///…/config.yaml#/a/0`). These are the rules of the VS Code
// extension's paths/format.js, so both editors copy the same text. A document
// whose URI has no location (`untitled:`) has neither URL, and its fragments
// are only `#/a/0`, which refer into the same document.

/** The formats, in the order the panel's menu lists them, each with its name as a phrase. */
export const PATH_FORMATS = {
  pointer: { key: "pointer", name: "JSON Pointer" },
  path: { key: "path", name: "JSON Path" },
  fragment: { key: "fragment", name: "URL Fragment" },
  absoluteFragment: { key: "absoluteFragment", name: "Absolute URL Fragment" },
};

const formatOf = (name) => PATH_FORMATS[name] ?? PATH_FORMATS.pointer;

// what encodeURIComponent escapes but a URI fragment may hold (RFC 3986:
// fragment = *( pchar / "/" / "?" ))
const FRAGMENT_CHARS = /%(24|26|2B|2C|3B|3D|3A|40|2F|3F)/g;

/** The fragment identifier of the JSON Pointer `pointer`: `#/a%20b/0`. */
export function fragmentOf(pointer) {
  return "#" + encodeURIComponent(pointer).replace(FRAGMENT_CHARS, decodeURIComponent);
}

// what encodeURIComponent escapes but the first segment of a relative
// reference may hold: pchar without ":" (RFC 3986, section 4.2)
const SEGMENT_CHARS = /%(24|26|2B|2C|3B|3D|40)/g;

/**
 * What a fragment of the document `uri` follows: its URI without query or
 * fragment when `absolute`, else its file's name as a relative URL
 * (`my%20config.yaml`); empty for a URI without a location.
 */
export function fragmentFile(uri, absolute) {
  if (!uri || !uri.includes("://")) return "";
  const url = new URL(uri);
  url.search = "";
  url.hash = "";
  if (absolute) return url.href;
  const name = decodeURIComponent(url.pathname.slice(url.pathname.lastIndexOf("/") + 1));
  return encodeURIComponent(name).replace(SEGMENT_CHARS, decodeURIComponent);
}

/** The text of `node` (an answer of `nimyaml/pathAt`) in `format`, for the document `uri`. */
export function pathText(node, format, uri) {
  const { key } = formatOf(format);
  if (key === "fragment" || key === "absoluteFragment") {
    return fragmentFile(uri, key === "absoluteFragment") + fragmentOf(node.pointer);
  }
  return node[key];
}

/**
 * How the panel shows `node`: the root's empty pointer as "(root)", in the
 * editor's words (`phrase`), and the number of its document when there are several.
 */
export function displayText(node, format, uri, phrase = (text) => text) {
  const text = pathText(node, format, uri) || phrase("(root)");
  return node.documents > 1 ? `#${node.document + 1} ${text}` : text;
}

function setPathFormat(paths, format) {
  paths.format = formatOf(format).key;
  for (const redraw of paths.panels) redraw();
}

// A panel under the text naming the node at the cursor, as a status bar
// would: the path in the format picked from the menu beside it, which every
// panel of the server shares, copied when clicked. Asked a quiet moment after
// the cursor or the text last moved, since every request sends the text.
function cursorPath(cm, paths) {
  const look = cm.EditorView.baseTheme({
    ".cm-yamllsp-path": { display: "flex", alignItems: "center", gap: "8px",
                          padding: "2px 8px", minHeight: "1.5em" },
    ".cm-yamllsp-path output": { flex: "1", minWidth: "0", cursor: "copy", whiteSpace: "pre",
                                 overflow: "hidden", textOverflow: "ellipsis" },
    ".cm-yamllsp-path select": { font: "inherit", fontSize: "90%", color: "inherit",
                                 background: "transparent", border: "0" },
  });
  return [look, cm.showPanel.of((view) => {
    const phrase = (text) => view.state.phrase(text);
    const dom = document.createElement("div");
    dom.className = "cm-yamllsp-path";
    const output = document.createElement("output");
    output.setAttribute("role", "status");
    output.title = phrase("Click to copy");
    output.translate = false;   // a path is data, like the text
    // and written left to right, as code is, even in a right-to-left page,
    // where `#2 /a` or `$.a` would otherwise be reordered around its neutral
    // characters: isolated in a bdi, so that the output keeps the panel's
    // direction and the path its place at the panel's start
    const text = document.createElement("bdi");
    text.dir = "ltr";
    output.append(text);
    const menu = document.createElement("select");
    menu.setAttribute("aria-label", phrase("Path format"));
    for (const { key, name } of Object.values(PATH_FORMATS)) {
      menu.append(new Option(phrase(name), key));
    }
    dom.append(output, menu);

    let node = null, timer = 0, asked = 0, destroyed = false;
    const draw = () => {
      const uri = cm.LSPPlugin.get(view)?.uri ?? "";
      menu.value = paths.format;
      output.setAttribute("aria-label", phrase(formatOf(paths.format).name));
      text.textContent = node ? displayText(node, paths.format, uri, phrase) : "";
      output.dataset.path = node ? pathText(node, paths.format, uri) : "";
    };
    const refresh = async () => {
      const plugin = cm.LSPPlugin.get(view);
      if (!plugin || destroyed) return;
      const asking = ++asked;
      let found;
      try { found = await pathAt(plugin.client, view, view.state.selection.main.head); }
      catch { return; }
      if (destroyed || asking !== asked) return;
      node = found;
      draw();
    };
    output.addEventListener("click", () => {
      if (output.dataset.path) navigator.clipboard?.writeText(output.dataset.path).catch(() => {});
    });
    menu.addEventListener("change", () => {
      setPathFormat(paths, menu.value);
      paths.changed(paths.format);
    });
    paths.panels.add(draw);
    draw();
    timer = setTimeout(refresh, QUIET_MS);
    return {
      dom,
      update(update) {
        if (!update.docChanged && !update.selectionSet) return;
        clearTimeout(timer);
        timer = setTimeout(refresh, QUIET_MS);
      },
      destroy() { destroyed = true; clearTimeout(timer); paths.panels.delete(draw); },
    };
  })];
}
