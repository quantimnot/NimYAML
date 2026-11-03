# `<yaml-editor>`

NimYAML's language server in a browser editor, as a web component of the
[ui-web-component](../../README.md#editor-bindings) collection's kind: YAML in its
`<code-editor>`, checked as it is typed by the server, which is NimYAML
compiled to JavaScript and running in a worker of the page
([`js/lsp/`](../../js/README.md#the-language-server-lsp)). Nothing runs
on a server; the page's files are the project.

```html
<link rel="html-import" href="yaml-editor/yaml-editor.html">
<script type="module" src="html-import.js"></script>

<yaml-editor uri="file:///project/config.yaml">name: inventory</yaml-editor>
<script>
  document.addEventListener("fileread", (e) => {        // the server needs a file
    if (myFiles.has(e.detail.path)) e.detail.respondWith(myFiles.get(e.detail.path));
  });
</script>
```

What the editor gets from the server: lint and JSON Schema diagnostics
(configured by the `.yaml`/`.nimyaml-lint.yaml` beside the document),
completion of directives, hovers, formatting (Shift+Alt+F, as `yaml format`),
go to definition (F12), the server's highlighting, and schema references as
links (Ctrl/Cmd+click). `https:` schemas are fetched by the page.

The component's own UI is one line under the text: the path of the node at
the cursor as a JSON Pointer (`/servers/0/host`), a JSON Path
(`$.servers[0].host`) or a URL fragment, relative (`config.yaml#/servers/0`)
or absolute (`file:///project/config.yaml#/servers/0`), by the VS Code
extension's rules; clicking it copies it. Its words are in the component's
catalogs, in the collection's six languages.

The attributes, properties, methods and events are documented on its
developer page, generated from the component itself; in short: `uri`,
`path-format`, `readonly`, `label`; `value`; `format()`, `inferSchema()`,
`pathText()`, `filesChanged()`; `valuechange`, `fileread`, `linkopen`,
`pathchange`, `pathformatchange`. One server serves every `<yaml-editor>` of
a page, so a document and the schema open beside it are checked together.

[`yamllsp.js`](yamllsp.js) is the engine, for any CodeMirror 6 editor without
the component: `yamlLanguageServer({cm, transport})` adds to
`@codemirror/lsp-client` the server's highlighting, document links, the path
at the cursor and `https:` schemas, made from the editor's own CodeMirror
(`cm`), since extensions from a second copy are refused.

## Setting up

The component builds on the ui-web-component workspace, linked rather than
copied, and on NimYAML's JavaScript build, linked the same way:

```sh
(cd path/to/ui-web-component && bun link)   # once: registers ui-web-component-workspace
(cd js && bun link)                           # once: registers nimyaml
cd editors/codemirror && bun install          # links both into node_modules
node ../../js/build.mjs                       # js/dist/nimyaml.mjs, which the worker loads
```

The workspace's `code-editor/codemirror.js` must be built there (`make` in
its `packages/ui-components`). The framework's server mounts each package of
the linked workspace beside this one, so the component reaches
`../code-editor/` and `../runtime.js` as the collection's own do, and NimYAML at
`../js/`.

## Developing

```sh
bun run serve        # the developer page: examples, tour, API reference, tests
bun run test         # yamllsp.test.mjs in Node, then the page's tests in every locale
ninja                # the screenshots the page shows
```
