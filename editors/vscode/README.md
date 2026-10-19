# NimYAML yamllsp for VS Code

Starts [`yamllsp`](../../tools/yamllsp.nim), NimYAML's language server, for
YAML documents: lint diagnostics, JSON Schema validation, `%GLOBAL` and
`%SCHEMA` support and semantic highlighting. See the main README for
building and installing.

## Embedded languages

Code in a literal block scalar gets the highlighting and the language
features of its language when the language is named:

```yaml
query: | # sql
  select id, name from users

# yaml-lsp: python
setup: |
  import os
  print(os.environ["HOME"])
teardown: |
  print("bye")
# yaml-lsp
```

The language of a block is, in this order:

1. the comment on its header, `| # sql`;
2. the last `# yaml-lsp: <language>` comment above it, until a bare
   `# yaml-lsp` (`nimyaml.embedded.stickyDirective`;
   `# yaml-embedded-languages: <language>` is accepted too);
3. a key rule, which picks the language by key and, optionally, file:

   ```jsonc
   "nimyaml.embedded.keyRules": [
     { "keyPattern": "^run$", "language": "shellscript", "filePattern": "**/.github/workflows/*.yml" }
   ]
   ```

Names are VS Code language IDs or `nimyaml.embedded.aliases` (`py`, `sh`,
`js`, …). *NimYAML: Show Embedded Language Regions* lists the blocks found,
their language and where it came from.

### How it works

`yamllsp` reports where the block scalars are (`nimyaml/blockScalars`), as
NimYAML's lexer reads them. Each literal block with a language is written to
a file of that language, a *projection*, in `.yaml-embedded/` in the
workspace (hidden from the explorer and search), which is opened but never
shown; the language's extension then serves it like any other file.
Requests in the block (completion, hover, definition, references, rename,
code actions, symbols, inlay hints, folding, links, colours, signature help)
are forwarded to the projection and the answers mapped back. A literal
block's value is its text minus the indentation, so positions map by an
offset, exactly, and edits such as renames apply unchanged. Diagnostics
that servers publish for projections are shown on the YAML document.

Colour comes from two places. A grammar injected into VS Code's YAML grammar
highlights blocks whose header comment names one of the languages in
[`syntaxes/generate.js`](syntaxes/generate.js) with that language's grammar.
And in all blocks with a language, `yamllsp`'s semantic tokens, which show
the block as a string, are replaced by the embedded language's semantic
tokens, if its server provides any (only token types `yamllsp`'s legend has
are kept; the others keep the grammar's colour).

*Format Embedded Language Region* formats the block at the cursor; it is a
command because a formatter would format the whole YAML document. *Open
Projection of Embedded Language Region* shows what the server sees.

### What to expect

How much works depends on the language's extension:

- **Diagnostics need a server that diagnoses documents that are not shown.**
  Servers that push diagnostics for all open documents (Pyright/Pylance,
  bash-language-server, `yamllsp` itself and most servers using
  `publishDiagnostics`) work. VS Code's built-in TypeScript/JavaScript only
  diagnoses files open in a tab unless
  `typescript.tsserver.experimental.enableProjectDiagnostics` is on; the
  built-in JSON, CSS and HTML servers pull diagnostics for tabs only and
  show none. All other features work for them.
- Servers that need project membership (gopls, rust-analyzer, clangd)
  answer requests, but a file outside any package or crate has little sound
  to say.
- A language without a file extension cannot be projected.
- Folded block scalars (`>`) are not served: folding joins lines, so the
  value is not the text shown. One that names a language gets a warning
  (`nimyaml.embedded.warnOnFoldedScalars`).
- Projections are files in the workspace, so servers that analyze the whole
  project may report on them, and a rename can edit project files outside
  the YAML document, as it should. `nimyaml.embedded.projection.root: temp`
  keeps them out of the workspace, at the cost of imports and project
  configuration.
- Projections are numbered in document order, so adding a block renames the
  projections of the blocks below it.
- Completion items' follow-up commands (auto-imports, say) and code actions
  that are only commands are dropped: they would run on the projection.

`nimyaml.embedded.enabled: false` turns all of this off and deletes the
projections.

## Development

```bash
npm install
npm test              # unit tests (node --test)
npm run grammar       # regenerate syntaxes/ after editing generate.js
```

`yamllsp`'s side is tested in `test/tlsp.nim`.
