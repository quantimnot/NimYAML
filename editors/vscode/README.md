# NimYAML yamllsp for VS Code

Starts `yaml lsp` ([`tools/yamlcli.nim`](../../tools/yamlcli.nim)), NimYAML's language server, for
YAML documents: lint diagnostics, JSON Schema validation, `%GLOBAL` and
`%SCHEMA` support and semantic highlighting. On top of the server, the
extension adds embedded languages in block scalars, a grid view, navigation
by JSON Pointer and JSON Path and a semantic diff, the last three for JSON
and JSONC too. See the main README for building and installing.

yamllsp is told about YAML documents only (saved or untitled). JSON and
JSONC files get the grid, the paths and the semantic diff, which send the
text with each request, but no diagnostics; VS Code's own JSON support keeps
serving them. The extension runs alongside other YAML extensions, such as
Red Hat's: VS Code merges the diagnostics, hovers and completions of every
server.

## Language Features

### [YAML 1.1](https://yaml.org/spec/1.1/)

Read, but by YAML 1.2's rules: `%YAML 1.1` is accepted and shown in hovers,
but `yes` stays a string and merge keys (`<<`) are not applied. The
`truthy` lint rule flags the plain scalars that YAML 1.1 would read as
booleans:

```yaml
%YAML 1.1
---
enabled: yes  # warning: "yes" is a boolean in YAML 1.1; quote it or use true/false [truthy]
```

### [YAML 1.2](https://yaml.org/spec/1.2.2/)

Default. A document without `%YAML` is YAML 1.2, read with the core schema:
`1.5` is a number, `true` a boolean and `~` null.

### YAML 1.2+

NimYAML YAML extensions: two directives that YAML 1.2 reserves. Other YAML
processors ignore them, as the specification asks them to; `yaml expand`
rewrites a file so that they read it the same way (see the main
[README](../../README.md#portable-yaml)).

#### [%GLOBAL Directive](../../README.md#schema-and-global-directives)

Set cascading directives for all documents in a stream. `%GLOBAL` wraps a
`YAML`, `TAG` or `SCHEMA` directive and is only allowed before the first
document; a document's own directive overrides it for that document only.

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

Typing `%GLOBAL ` completes the directives it can wrap. Hovering a
directive says where it applies; on the `%GLOBAL YAML 1.2` above:

> **`%YAML 1.2`**
>
> YAML version 1.2.
>
> Global (`%GLOBAL`): applies to all 3 documents of the stream, except
> document 2, which overrides it.

Hovering a `---` or `...` marker lists what is in effect for its document:

> **Document 3**
>
> - `%YAML 1.2` (global, line 1)

#### [%SCHEMA Directive](../../README.md#schema-and-global-directives)

Set a schema location: the JSON Schema, in JSON or YAML, that the document
is validated against. Relative references resolve against the YAML file.

```yaml
%SCHEMA schema.json
---
...
%SCHEMA schema.yaml
---
...
%SCHEMA ./schemas/service.yaml
---
...
%SCHEMA /etc/schemas/service.yaml  # an absolute path
---
...
%SCHEMA file:///etc/schemas/service.yaml
---
```

Schemas are read from `file:` URIs, and VS Code's own from `vscode:` URIs
(below); yamllsp never accesses the network, so
`%SCHEMA https://example.com/schema.json` gives a `schema-unavailable`
warning instead of a validation. A schema file must load as YAML, so a
`.jsonc` schema with comments cannot be used either.

A document can also name its schema the way other editors do; the highest
of these wins, and a document that uses several gets a `schema-source` note
saying which:

1. its `%SCHEMA`,
2. a `%GLOBAL SCHEMA`,
3. a `# yaml-language-server: $schema=schema.json` comment,
4. a top-level `$schema` key.

### [JSON](../../README.md#jsonc)

`.json`, `.geojson`, `.har`, `.jsonld` and `.webmanifest` files, with a
grammar and a file icon. JSON is YAML, so the grid, paths and semantic diff
read it with the YAML parser.

### [JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901)

`/servers/0/host`: how [Paths](#paths) name the node at the cursor (the
default of `yaml+lsp.paths.format`), and how the
[Semantic Diff](#semantic-diff) names its changes.

### [JSON Path](../../README.md#jsonpath)

`$.servers[0].host`: the other format of [Paths](#paths) and the
[Semantic Diff](#semantic-diff), with `yaml+lsp.paths.format: "path"`.
`yaml query '$..host' config.yaml` runs a full RFC 9535 query.

### [JSON Patch](../../README.md#patches-merge-keys-and-canonical-json)

The [Semantic Diff](#semantic-diff)'s *Open as JSON Patch* button opens the
patch that turns the old version into the new one, as YAML (JSON if the new
file is JSON):

```yaml
- {op: replace, path: /server/port, value: 8080}
- {op: add, path: /tags/1, value: z}
```

`yaml patch patch.yaml config.yaml` applies it.

### [JSON Merge Patch](../../README.md#patches-merge-keys-and-canonical-json)

Command line only: `yaml patch` applies a patch that is a mapping as a merge
patch, where `null` removes a member, and `yaml diff --merge-patch` creates
one.

```yaml
debug: null      # remove
server: {port: 8080}
```

### [JSON Schema](../../README.md#json-schema)

Drafts 2020-12 (the default), 2019-09, 07, 06 and 04. Documents are
validated against the schema they name (see [%SCHEMA](#schema-directive)),
and each violation is a `schema-validation` error on the offending node:

```yaml
# yaml-language-server: $schema=person.schema.yaml
name: Ada
age: -1   # error: -1 is less than the minimum of 0 [schema-validation]
```

VS Code's own schemas, which it builds at runtime from the installed
extensions and localizes into the display language, can be named by their
`vscode://schemas/` URI, so that a YAML source of an extension manifest, of
settings or of keybindings is validated like its JSON:

```yaml
# yaml-language-server: $schema=vscode://schemas/vscode-extensions
name: my-extension
engines: {vscode: 1}   # error: not a string [schema-validation]
```

The extension gives them to yamllsp when it asks, and again when VS Code
changes one (an extension that contributes settings is installed, say).
Others are `vscode://schemas/settings/user`, `vscode://schemas/keybindings`,
`vscode://schemas/tasks` and `vscode://schemas/launch`.

### [JSON Hyper Schema](../../README.md#json-hyper-schema)

Schemas whose `$schema` is the Hyper-Schema meta-schema validate like any
other; its links are resolved by the library (`yaml/hyperschema`), not by
the editor.

### [JSONC](../../README.md#jsonc)

JSON with `//` and `/* */` comments and trailing commas, as in
`settings.json` (`.jsonc`, `.code-workspace`, `.code-profile`). It has a
grammar, a file icon and comment toggling, and the grid, paths and semantic
diff read it with its comments blanked out:

```jsonc
{
  "name": "web", // the service
  "ports": [80, 443, /* https */],
}
```

### [JSONL](../../README.md#json-lines)

JSON Lines (`.jsonl`, `.ndjson`): one JSON value per line, each coloured by
the JSON grammar. `yaml convert jsonl config.yaml` writes one.

```jsonl
{"name": "a", "count": 1}
{"name": "b", "count": 2}
```

### [CBOR](../../README.md#cbor)

A grammar for CBOR diagnostic notation (RFC 8949 §8; `.cbordiag`): numbers,
text and byte strings (`h'…'`, `b64'…'`), tags (`1(…)`), simple values and
`<<…>>` embedded items. Binary `.cbor` files are not text; `yaml convert
cbor` and `yaml convert --from:cbor yaml` translate them.

```cbordiag
{"name": "a", "count": 1, "id": h'0102', "at": 1(1700000000)}
```

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

### Definition

*Go to Definition* (F12, Ctrl/Cmd+click) on a schema reference opens the
schema: the URI of a `%SCHEMA` or `%GLOBAL SCHEMA`, of a
`yaml-language-server` modeline or of a top-level `$schema` key. The same
references are also document links.

```yaml
%SCHEMA schemas/service.yaml   # F12 on the reference opens schemas/service.yaml
---
name: api
```

Aliases do not yet go to their anchors.

### All Symbols

Not yet implemented: yamllsp has no document symbols, so the outline and
*Go to Symbol* (Ctrl/Cmd+Shift+O) come from other extensions. *YAML+: Go to
Path…* (see [Paths](#paths)) lists every node by its path instead.

### Inlined Merge

Not yet implemented. View and edit documents with merged (`<<`) content,
with a visual distinction for where each entry came from:

```yaml
defaults: &defaults {adapter: postgres, host: localhost}
production:
  <<: *defaults
  host: db.example   # shown with "adapter: postgres" from defaults
```

Until then, `yaml merge config.yaml` prints the documents with their merge
keys applied.

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

### Autocomplete

Directive names after `%` (`YAML`, `TAG`, `SCHEMA`, `GLOBAL`, each with a
description), and after `%GLOBAL ` the directives it can wrap:

```yaml
%GL     # completes to %GLOBAL
%GLOBAL S   # completes to %GLOBAL SCHEMA
```

Completion of keys and values from the document's JSON Schema is not yet
implemented.

### Convert

Not yet implemented in the editor. Convert between any of the formats: YAML,
JSON, JSONC, JSON Lines and CBOR. On the command line, `yaml convert`
does it now:

```bash
yaml convert json config.yaml          # YAML to JSON
yaml convert yaml settings.jsonc       # JSONC to YAML, comments dropped
yaml convert cbor items.jsonl > items.cbor
```

### Validate Schema

Every change of a YAML document validates it against its JSON Schema (see
[%SCHEMA](#schema-directive) and [JSON Schema](#json-schema)); violations
are `schema-validation` errors on the offending nodes, and a schema that
cannot be read is a `schema-unavailable` warning on its reference. Schema
files are read again on every change, so editing a schema takes effect in
the documents that use it. Set `validate: {schema: false}` in the `.yaml`
config to turn validation off; `yaml validate` does the same check on the
command line.

### Document Preview

Not yet implemented. Show a document as another format beside the editor,
for example a YAML file as the JSON it is read as, with `%GLOBAL`
directives expanded and merge keys applied, updated as you type.

### Hover Preview

Not yet implemented. An API through which other extensions transform
yamllsp's hovers before they are shown, for example to render the LaTeX in
a schema description, like vscode-yaml's
[`registerHoverTransformer`](https://github.com/redhat-developer/vscode-yaml/pull/1304).

The hovers that exist are those on directives and document markers (see
[%GLOBAL](#global-directive)).

### Format Document

Not yet implemented: yamllsp does not format. `yaml format` does, in the
style of the `format` section of the `.yaml` config, keeping comments:

```bash
yaml format -i config.yaml                  # rewrite in place
yaml format --check --indent:2 *.yaml       # list files that are not formatted
```

*YAML+: Format Embedded Language Region* formats the code of one block
scalar with its language's formatter (see
[Embedded Languages](#embedded-languages)).

### Format Selection

Not yet implemented. Format only the selected nodes, as `yaml format`
formats a whole file.

### Comments

Enter in a comment continues it: the new line starts with the comment's
indentation, its `#` and as many spaces as it has. A `#!` line is not
continued.

```yaml
  #   a long comment|   ← Enter
  #   |
```

`# region` and `# endregion` comments mark folding regions:

```yaml
# region servers
servers:
  - a
  - b
# endregion
```

### Syntax Highlight

Static syntax highlight rulesets: TextMate grammars for JSON, JSONC, JSON
Lines and CBOR diagnostic notation; YAML keeps VS Code's own grammar, into
which the extension injects the grammars of
[Embedded Languages](#embedded-languages). They need no server, so they also
work in untrusted contexts (Restricted Mode).

### Semantic Highlight

YAML coloured as NimYAML's lexer reads it, with standard token types that
every theme colours: keys (`property`), scalars by the type they resolve to
(`number` for `1` and `1.5`, `keyword` for `true` and `null`, `string`
otherwise), tags (`type`), anchors and aliases (`variable`, anchors as
declarations), directives and `---`/`...` (`keyword`), and comments.
Unlike the grammar, it knows that `%GLOBAL` and `%SCHEMA` are directives,
where a multi-line plain scalar ends and which scalar is a key:

```yaml
%SCHEMA schema.yaml            # keyword, string
--- !service                   # keyword, type
port: 8080                     # property, number
? [complex, key]
: &shared ~                    # variable (declaration), keyword
plain: this scalar
  goes on here                 # string, on both lines
```

Text after a syntax error is uncoloured up to the next document.

### [Embedded Languages](docs/embedded-langs.md)

Code in a literal block scalar gets the highlighting and language features
(diagnostics, completion, hover, go to definition, …) of its language when
the language is named, by a comment, a sticky `# yaml-lsp: <language>`
directive or a key rule:

```yaml
query: | # sql
  select id, name from users

# yaml-lsp: python
setup: |
  import os
```

Each block is written to a file of its language that the language's own
extension serves. *YAML+: Show Embedded Language Regions* lists the blocks
and their languages. See [docs/embedded-langs.md](docs/embedded-langs.md)
for the settings.

### [Lint Diagnostics](../../README.md#linting)

Problems are shown as you type, from the lint rules of the `.yaml` (or
`.yaml.yaml`, `.nimyaml-lint.yaml`) config found by walking up from the
file, or the defaults:

```yaml
name: app
name: other         # error: duplicate mapping key "name" [duplicate-key]
enabled: yes        # warning: "yes" is a boolean in YAML 1.1; … [truthy]
base: &base {a: 1}  # warning: unused anchor &base [unused-anchor]
ref: *missing       # error: undefined alias *missing [undefined-alias]
```

The rules are `syntax`, `duplicate-key`, `complex-key`, `undefined-alias`,
`unused-anchor`, `truthy`, `trailing-spaces`, `line-length`, `tabs`,
`final-newline` and the directive rules; each can be set to `error`,
`warning`, `info` or `off`:

```yaml
# .yaml
lint:
  rules:
    line-length: {level: warning, max: 100}
    truthy: {level: off}
```

Saving a config file applies it to all open documents; an invalid one is an
error on the first line. `yaml config` writes the config in effect with
every key.

### Extension Point: SchemaAttributer

Not yet implemented. API for other VS Code extensions to attribute schemas
to documents, for files that cannot name their own schema. A sketch of the
intended use:

```js
const yamlPlus = vscode.extensions.getExtension("nimyaml.yaml-plus-lsp").exports;
yamlPlus.registerSchemaAttributer((uri) =>
  uri.path.endsWith("/service.yaml") ? "file:///etc/schemas/service.json" : undefined);
```

### Semantic Diff

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
command line:

```bash
$ yaml diff config.yaml config.json
~ /server/port: 80 -> 8080
+ /tags/1: z
- /debug: true
```

## Commands and Settings

| Command | Does |
|---|---|
| *YAML+: Restart yamllsp* | restarts the server, e.g. after rebuilding it |
| *YAML+: Open in Grid* | opens the file in the [Grid](#grid) |
| *YAML+: Copy JSON Pointer* / *Copy JSON Path* / *Go to Path…* | see [Paths](#paths) |
| *YAML+: Compare Semantically …* | see [Semantic Diff](#semantic-diff) |
| *YAML+: Show / Format / Open Projection of / Delete Projections of Embedded Language Region(s)* | see [Embedded Languages](docs/embedded-langs.md) |

`yaml+lsp.path` and `yaml+lsp.args` set the command that starts the server
(default `yaml lsp`, with `yaml` from `PATH`); changing them restarts it.
`yaml+lsp.trace.server` (`off`, `messages`, `verbose`) logs the messages
between VS Code and yamllsp in the "yaml+lsp Trace" output channel. The
`yaml+lsp.paths.*` settings are described under [Paths](#paths) and the
`yaml+lsp.embedded.*` ones in [docs/embedded-langs.md](docs/embedded-langs.md).

## Development

```bash
bun install     # install deps
bun test        # unit tests (bun --test)
bun run build   # bundle dist/extension.js, the `main` VS Code loads, and dist/grid
bun run typecheck  # check the grid webview's TypeScript (needs `tsc` on PATH)
```
