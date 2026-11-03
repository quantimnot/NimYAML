// yaml-editor.js — behaviour for <yaml-editor>: YAML in a <code-editor>, checked as it is typed
// by NimYAML's language server, which runs in a worker of the page. Its template and words live in
// yaml-editor.html; the editor features are yamllsp.js's, made from the CodeMirror <code-editor>
// bundles (codemirror.js beside it), since extensions from a second copy are refused.
//
// Public API:
//   attribute `uri`          the document's URI: file:///project/config.yaml names a file, so its
//                            config and its relative %SCHEMA references are found beside it, and
//                            its URL fragments have a file name; default an untitled: one. Two
//                            editors of one page may not share a URI.
//   attribute `path-format`  how the line under the text names the node at the cursor: pointer
//                            (default), path, fragment or absolute-fragment
//   attribute `readonly`     the text can be read, searched and navigated, not changed
//   attribute `label`        the editor's accessible name; default the catalog's "YAML editor"
//   el.value                 the text, as <code-editor>'s value; until set, the element's own
//                            text content
//   el.format()              formats the text as `yaml format` would, in the style of its config
//   el.inferSchema(options)  resolves to the server's JSON Schema of the text: {schema, documents}
//   el.pathText(format)      resolves to the path of the node at the cursor in a format, or null
//   el.filesChanged(files)   tells the server files changed: {path: text, or null for none}
//   event `valuechange`      the person changed the text: { value }, read only when asked for
//   event `fileread`         the server needs a file: { path, respondWith(text | null | Promise) }
//   event `linkopen`         a link was Ctrl/Cmd+clicked: { target }; cancelable
//   event `pathchange`       the cursor is on another node: { pointer, path, document, documents }
//   event `pathformatchange` the person picked another format: { format }
//
// Why this shape:
//   • One server for the page, started by the first editor that connects, as a desktop editor
//     runs one server for a window: documents that refer to each other (a document and its
//     schema) are open in the same server, and the 4 MB program is loaded once.
//   • The page's files are the page's. The worker has no file system (js/lsp/server-worker.mjs):
//     when the server needs a file, a config beside a document or a schema it names, an editor
//     asks the page with `fileread`, which a page answers once, on the document, for all its
//     editors, the way a service worker answers fetch: respondWith, during the event. Unanswered,
//     the file does not exist. A file open in another <yaml-editor> needs no answer: its text is
//     handed to the server as it changes. Files that change elsewhere, the page announces with
//     filesChanged.
//   • A link to a document open in another editor of the page focuses that editor; one to the
//     web opens a tab; a page that knows better cancels `linkopen` and opens it itself.
//   • The status line is the one thing drawn here, in the template: the path of the node at the
//     cursor, asked a quiet moment after the cursor or the text moved, since every request
//     carries the text. Clicking it copies it.
//   • Little else is added to <code-editor>: its attributes are forwarded, its valuechange
//     re-sent from here so that it is this element's event.

import { TemplateElement } from '../runtime.js';
import * as cm from '../code-editor/codemirror.js';
import { startServer } from '../js/lsp/transport.mjs';
import { yamlLanguageServer, displayText, pathText } from './yamllsp.js';

/** path-format attribute → yamllsp.js's format, and the message naming it. */
const FORMATS = {
  pointer: 'pointer',
  path: 'path',
  fragment: 'fragment',
  'absolute-fragment': 'absoluteFragment',
};

// how long the cursor and the text rest before the path is asked, and a changed file is sent
const QUIET_MS = 250;

// ---- The page's server ----

const editors = new Set();      // the connected <yaml-editor>s, in the order they connected
const uris = new WeakMap();     // <yaml-editor> → the URI it is configured with
let shared = null;

function connection() {
  shared ??= (() => {
    const server = startServer({ readFile: async (path) => askPage(path) });
    const yaml = yamlLanguageServer({ cm, transport: server.transport, openLink });
    return { server, yaml };
  })();
  return shared;
}

/**
 * The text of the file `path`: an editor's of the page that has it open, else the page's answer
 * to `fileread`, asked of the first connected editor.
 */
function askPage(path) {
  const open = [...editors].find((editor) => pathOf(uris.get(editor) ?? '') === path);
  if (open) return open.value;
  const [asker] = editors;
  let answer = null;
  asker?.emit('fileread', { path, respondWith(value) { answer = value; } });
  return answer;
}

const pathOf = (uri) => (uri.startsWith('file:') ? decodeURIComponent(new URL(uri).pathname) : null);

/** The <yaml-editor> whose <code-editor> holds `view`. */
const ownerOf = (view) => view.dom.getRootNode().host?.getRootNode().host ?? null;

function openLink(target, view) {
  const from = ownerOf(view);
  if (from && !from.emit('linkopen', { target }, { cancelable: true })) return;
  const open = [...editors].find((editor) => uris.get(editor) === target);
  if (open) { open.scrollIntoView({ block: 'nearest' }); open.focus(); }
  else if (/^https?:/i.test(target)) globalThis.open?.(target, '_blank', 'noopener');
}

let untitled = 0;

export default class YamlEditor extends TemplateElement {
  static observedAttributes = ['uri', 'path-format', 'readonly', 'label'];

  #ownUri = `untitled:yaml-editor-${++untitled}`;
  #valueSet = false;   // the page set value before the element's content could be read
  #node = null;        // the server's answer for the node at the cursor
  #pathTimer = 0;
  #asked = 0;
  #sendTimer = 0;

  // The <code-editor> inside, upgraded first: an element made off the page (innerHTML into a
  // detached holder) has its shadow tree before the shadow tree's elements are upgraded, and a
  // value set on one not upgraded yet would be a plain property hiding the editor's own.
  get #editor() {
    const { editor } = this.refs;
    customElements.upgrade(editor);
    return editor;
  }

  get value() {
    return this.#editor.value;
  }

  set value(text) {
    this.#valueSet = true;
    this.#editor.value = text;
  }

  /** Formats the text in the style of its config; false if the editor is not ready. */
  format() {
    const view = this.#view();
    return view ? cm.formatDocument(view) : false;
  }

  inferSchema(options = {}) {
    return connection().yaml.inferSchema([this.value], options);
  }

  async pathText(format = this.#format()) {
    const view = this.#view();
    if (!view) return null;
    const node = await connection().yaml.pathAt(view);
    return node && pathText(node, FORMATS[format] ?? 'pointer', uris.get(this));
  }

  filesChanged(files) {
    connection().server.worker.postMessage({ files });
  }

  connected() {
    connection();
    editors.add(this);
    if (!this.#valueSet) {
      this.#valueSet = true;
      this.#editor.value = this.textContent.replace(/^\n/, '').replace(/\n[ \t]*$/, '');
    }
    this.listen(this.#editor, 'valuechange', (event) => this.#heard(event));
  }

  disconnected() {
    editors.delete(this);
  }

  update() {
    const uri = this.getAttribute('uri') || this.#ownUri;
    if (uri !== uris.get(this)) {
      uris.set(this, uri);
      this.#node = null;
      this.#editor.extensions = [
        connection().yaml.extensions(uri),
        cm.EditorView.updateListener.of((update) => {
          if (update.docChanged || update.selectionSet) this.#askPathSoon();
        }),
      ];
      this.#askPathSoon();
    }
    const editor = this.#editor;
    editor.toggleAttribute('readonly', this.hasAttribute('readonly'));
    editor.setAttribute('label', this.getAttribute('label') || this.msg('editor_label'));
    this.refs.format.value = this.#format();
    this.#drawPath();
  }

  // ---- The status line ----

  copyShown() {
    if (!this.#node) return;
    navigator.clipboard?.writeText(pathText(this.#node, FORMATS[this.#format()], uris.get(this)))
      .catch(() => {});   // no clipboard here: nothing to copy to
  }

  pickFormat() {
    const format = this.refs.format.value;
    this.setAttribute('path-format', format);
    this.emit('pathformatchange', { format });
  }

  #format() {
    const format = this.getAttribute('path-format');
    return format in FORMATS ? format : 'pointer';
  }

  #view() {
    const dom = this.#editor.shadowRoot?.querySelector('.cm-editor');
    return dom ? cm.EditorView.findFromDOM(dom) : null;
  }

  #askPathSoon() {
    clearTimeout(this.#pathTimer);
    this.#pathTimer = setTimeout(() => this.#askPath(), QUIET_MS);
  }

  async #askPath() {
    const view = this.#view();
    if (!view || !this.isConnected) return;
    const asking = ++this.#asked;
    let node;
    try { node = await connection().yaml.pathAt(view); }
    catch { return; }   // the text changed meanwhile, and the next change asks again
    if (asking !== this.#asked) return;
    const moved = node?.pointer !== this.#node?.pointer || node?.document !== this.#node?.document;
    this.#node = node;
    this.#drawPath();
    if (moved && node) {
      const { pointer, path, document, documents } = node;
      this.emit('pathchange', { pointer, path, document, documents });
    }
  }

  #drawPath() {
    this.refs.pathText.textContent = this.#node
      ? displayText(this.#node, FORMATS[this.#format()], uris.get(this), this.msg('path_root'))
      : '';
  }

  // ---- The text ----

  // <code-editor>'s own event stops here and leaves as this element's; the text of a file goes
  // to the server a moment later, for the documents that read it.
  #heard(event) {
    event.stopPropagation();
    const editor = this.#editor;
    this.emit('valuechange', { get value() { return editor.value; } });
    const path = pathOf(uris.get(this));
    if (!path) return;
    clearTimeout(this.#sendTimer);
    this.#sendTimer = setTimeout(() => this.filesChanged({ [path]: editor.value }), 400);
  }
}
