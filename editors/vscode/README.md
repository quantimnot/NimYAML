# NimYAML yamllsp for VS Code

Starts `yaml lsp` ([`tools/yamlcli.nim`](../../tools/yamlcli.nim)), NimYAML's language server, for
YAML documents: lint diagnostics, JSON Schema validation, `%GLOBAL` and
`%SCHEMA` support and semantic highlighting. See the main README for
building and installing.

## Language Features

### [YAML 1.1](https://yaml.org/spec/1.1/)

### [YAML 1.2](https://yaml.org/spec/1.2.2/)

Default.

### YAML 1.2+

NimYAML YAML extensions.

#### [%GLOBAL Directive](docs/lang-yaml-global-directive.md)

Set cascading directives for all documents in a stream.

```yaml
%GLOBAL YAML 1.2
---
yaml 1.2 doc
...
%YAML 1.1 # overrides global
---
yaml 1.1 doc
---
yaml 1.2 doc
```

#### [%SCHEMA Directive](docs/lang-yaml-schema-directive.md)

Set a schema location.

```yaml
%SCHEMA schema.json
---
...
%SCHEMA schema.jsonc
---
...
%SCHEMA schema.yaml
---
...
%SCHEMA ./schema.yaml
---
...
%SCHEMA /schema.yaml
---
...
%SCHEMA file://schema.yaml
---
...
%SCHEMA file:///path/schema.yaml
---
...
%SCHEMA http://localhost/schema.yaml # TODO: support http
---
...
%SCHEMA https://localhost/schema.yaml # TODO
---
```

### [JSON](docs/lang-json.md)

### [JSON Pointer](docs/lang-json-pointers.md)

### [JSON Path](docs/lang-json-paths.md)

### [JSON Patch](docs/lang-json-patch.md)

### [JSON Merge Patch](docs/lang-json-merge-patch.md)

### [JSON Schema](docs/lang-json-schemas.md)

### [JSON Hyper Schema](docs/lang-json-hyper-schemas.md)

### [JSONC](docs/lang-jsonc.md)

TODO

### [JSONL](docs/lang-jsonl.md)

TODO

### [CBOR](docs/lang-cbor.md)

TODO

## Editor Features

### Paths

Where the cursor is, as a [JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901)
(`/a/0/b`) or a [JSON Path](https://www.rfc-editor.org/rfc/rfc9535)
(`$.a[0].b`), in YAML, JSON and JSONC files, and navigation by it, after
[vscode-yamlnav](https://github.com/skorth/vscode-yamlnav):

- The status bar shows the path of the node at the cursor; on a key, that
  of its member. In a stream of several documents it is prefixed with the
  document's number (`#2 /a`). Clicking it copies the path.
- *YAML+: Copy JSON Pointer* and *YAML+: Copy JSON Path*, also in the
  editor's context menu, copy either.
- *YAML+: Go to Path…*, also in the context menu, lists every node by its
  path, with the value of each scalar, and moves the cursor to the one
  picked. The list filters on paths and values as you type, and the editor
  follows the selected entry; Escape goes back to where the cursor was.

`yaml+lsp.paths.format` chooses which of the two is shown and what clicking
the status bar copies; `yaml+lsp.paths.statusBar` turns the status bar item
off. yamllsp names the nodes (`nimyaml/pathAt` and `nimyaml/paths`), from
the text as far as it parses, so a document being typed keeps the paths
before its first error.

### [Definition](docs/.md)

TODO

### [All Symbols](docs/.md)

TODO

### [Inlined Merge](docs/editor-inlined-merge.md)

TODO

View and edit documents with merged (`<<`) content.
Visual distinction given for provenance.

### Grid

A port of [yaml-grid-viewer](https://github.com/greenflute/yaml-grid-viewer)
in plain TypeScript, HTML and CSS. Right-click a YAML, JSON or JSONC file
and choose *Open With… › YAML+ Grid*, or run *YAML+: Open in Grid* (also in
the editor title bar), to see its documents as nested tables:

- Objects and arrays are collapsed into badges (`Object[3]`, `Array[5]`)
  that expand into tables; each document of a stream gets its own.
- An array of objects is a table with a column per member and a row per
  item; it can be switched to a plain list.
- Columns are resized by dragging their borders; a double-click resets
  them. What is expanded and how wide columns are is remembered per file.
- Hovering a value or key shows a pencil that edits it in place: Enter
  saves, Escape cancels, and multi-line strings get a text area
  (Ctrl/Cmd+Enter saves) that marks each line break with ↵. A string stays
  a string; other values are read as YAML, so `[1, 2]` makes a list.
- Colours follow the theme.

yamllsp reads the file for the grid (`nimyaml/grid`) and applies its edits
(`nimyaml/gridEdit`) with NimYAML's `yaml/edit`, which rewrites only the
node that changes: comments, quoting and layout stay. The grid and text
editors of a file share its undo history and update each other live. While
the text does not parse, the grid keeps the last version that did, under a
banner saying where the text breaks.

### [Autocomplete](docs/.md)

TODO

### [Convert](docs/editor-convert.md)

TODO

Convert between any of the formats.

### [Validate Schema](docs/editor-schema-validation.md)

TODO

### [Document Preview](docs/editor-preview.md)

TODO

### [Hover Preview](docs/editor-preview.md)

TODO

like: https://github.com/redhat-developer/vscode-yaml/pull/1304

### Format Document

TODO

### Format Selection

TODO

### [Syntax Highlight](docs/editor-syntax-highlight.md)

Static syntax highlight rulesets.
Can be used in untrusted contexts.

### [Semantic Highlight](docs/editor-semantic-highlight.md)

### [Embedded Languages](docs/editor-embedded-langs.md)

### [Lint Diagnostics](docs/editor-diags.md)

### [Extension Point: SchemaAttributer](editor-ext-schema-attributer.md)

TODO

API for other VSCode extensions to attribute schemas to documents.

## Development

```bash
bun install     # install deps
bun test        # unit tests (bun --test)
bun run build   # bundle dist/extension.js, the `main` VS Code loads, and dist/grid
bun run typecheck  # check the grid webview's TypeScript (needs `tsc` on PATH)
```

## Semantic Diff

"YAML+: Compare Semantically with File…", "…with Saved" and "…with HEAD"
compare the active YAML, JSON or JSONC editor with another file, its saved
version or its version in git's HEAD; "Compare Selected Semantically" in
the explorer's context menu compares two selected files. Key order,
styles, quotes, comments, anchors and aliases make no difference, numbers
are compared by value, and YAML can be compared with JSON.

The changes are listed like "Go to Path…", by JSON Pointer or JSON Path
(`yaml+lsp.paths.format`): selecting one shows it, the new version where
the editor is and the old one beside it. The buttons of the list open the
JSON Patch that makes the changes, or VS Code's text diff. yamllsp
computes the diff (`nimyaml/diff`); `yaml diff` does the same on the
command line.
