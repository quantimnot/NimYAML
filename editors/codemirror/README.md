# yamllsp for CodeMirror

NimYAML's language server in a browser editor: CodeMirror 6, through the
`<code-editor>` web component. The server is not a process here. It is
NimYAML compiled to JavaScript, running in a dedicated worker
([`js/lsp/`](../../js/README.md#the-language-server-lsp)), and
`@codemirror/lsp-client` talks to it. Nothing runs on a server: the page's
files are the project, and the worker asks the page for the ones it needs.

What the editor gets:

* **diagnostics**: the lint rules and JSON Schema validation, configured by
  the `.yaml`/`.nimyaml-lint.yaml` config beside the document, as on the
  command line;
* **completion** of directives after `%`, and **hover** on directives and on
  `---`/`...` markers (what is in effect, and where it comes from);
* **formatting** (Shift+Alt+F), as `yaml format` would, in the style of the
  config's `format` section;
* **go to definition** (F12) and **links** (Ctrl/Cmd+click) on schema
  references: `%SCHEMA`, `%GLOBAL SCHEMA`, `# yaml-language-server: $schema=`
  and `$schema`;
* the server's **highlighting**: keys, scalars by the type they resolve to,
  tags, anchors, aliases and directives, as NimYAML's lexer reads them, drawn
  over the YAML grammar's colours;
* the **JSON Pointer** of the node at the cursor, in a panel (click to copy);
* `https:` **schemas**, fetched by the page (the server never touches the
  network) when the config's `validate.remote-schemas` allows them;
* **schema inference** and a **semantic diff** as functions, for the page to
  offer as it likes.

## Using it

[`yamllsp.js`](yamllsp.js) has no imports. It is handed the CodeMirror the
editor was made from (`cm`), because the editor refuses extensions made from
a second copy of `@codemirror/state`. For `<code-editor>` that copy is the
`codemirror.js` beside the component, which exports `@codemirror/lsp-client`
too, and the component takes extensions through its `extensions` property:

```js
import * as cm from "/ui/code-editor/codemirror.js";
import { startServer } from "/nimyaml/lsp/transport.mjs";
import { yamlLanguageServer } from "/codemirror/yamllsp.js";

const server = startServer({ readFile: async (path) => myFiles.get(path) ?? null });
const yaml = yamlLanguageServer({ cm, transport: server.transport });

const editor = document.querySelector("code-editor[language=yaml]");
editor.extensions = yaml.extensions("file:///project/config.yaml");
```

`yamlLanguageServer` also takes `fetchSchema(uri)` (default: `fetch`; `null`
serves no `https:` schemas), `openLink(target)` (default: web pages in a new
tab), `pathPanel` (default `true`) and `rootUri`. It returns the `client`,
`extensions(uri)`, `pathAt(view)`, `inferSchema(texts, options)` and
`diff(oldText, newText)`.

The server reads a file once and keeps it. When the page changes a file
that is not open in an editor, or one that other documents read (a schema, a
config), it posts the new text to the worker, which has the server read it
again:

```js
server.worker.postMessage({ files: { "/project/schema.yaml": text } });
```

Any CodeMirror 6 editor works the same way, given the namespace its own
extensions come from; `<code-editor>` is the one this is tested with.

## The demo

[`index.html`](index.html) and [`demo.js`](demo.js) are a project of three
files (a document, its schema and its lint config), each in its own editor.
[`serve.mjs`](serve.mjs) serves it. The component collection is not part of
this repository, so you name its folder:

```sh
node js/build.mjs     # js/dist/nimyaml.mjs, which the worker loads
(cd "$UI_COMPONENTS/code-editor" && ninja)   # the component's codemirror.js
node editors/codemirror/serve.mjs --components "$UI_COMPONENTS"
```

`$UI_COMPONENTS` is the collection's `packages/ui-components` folder, the
one with `code-editor/` in it.

## Tests

```sh
node --test editors/codemirror/test/                  # token decoding, schema answers, the server
UI_COMPONENTS=... node editors/codemirror/test/browser.mjs   # the demo in headless Chromium
```

The browser test opens the demo with `?test`, which runs
[`test/checks.js`](test/checks.js) in the page: diagnostics, highlighting,
links, the cursor's path, revalidation after a schema edit, formatting and
schema inference, end to end. Without a Chromium (`$CHROMIUM`) or a
collection it is skipped.

## Words

The panel's label and tooltip ("JSON Pointer", "Click to copy") are asked
of the editor with `EditorState.phrase`, so a host that translates
CodeMirror's phrases can translate them too. `<code-editor>` translates
lsp-client's own words, and its lint panel's, in its catalogs. These two it
does not yet.
