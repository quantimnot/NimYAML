
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

1. the comment on its header, `| # sql`, which may also be written like
   the directive, `| # yaml-lsp: sql`, and then applies to that block only;
2. the last `# yaml-lsp: <language>` comment above it, until a bare
   `# yaml-lsp` (`yaml+lsp.embedded.stickyDirective`;
   `# yaml-embedded-languages: <language>` is accepted too);
3. a key rule, which picks the language by key and, optionally, file:

   ```jsonc
   "yaml+lsp.embedded.keyRules": [
     { "keyPattern": "^run$", "language": "shellscript", "filePattern": "**/.github/workflows/*.yml" }
   ]
   ```

Names are VS Code language IDs or `yaml+lsp.embedded.aliases` (`py`, `sh`,
`js`, …). *YAML+: Show Embedded Language Regions* lists the blocks found,
their language and where it came from.

### How it works

No languages are built in: every language an installed extension
contributes can be embedded, under its ID and the aliases and file
extensions it declares (`python`, `Python`, `py`, `pyi`; `shellscript`,
`sh`, `bash`), and installing an extension adds its languages. Two settings
add to that:

```jsonc
// more names for languages; these win over the declared ones
"yaml+lsp.embedded.aliases": { "tpl": "handlebars", "h": "c" },
// grammars by TextMate scope: one that is no VS Code language, or another
// grammar for a language
"yaml+lsp.embedded.grammars": {
  "regex": "source.regexp.python",
  "nimble": { "scopeName": "source.nim", "language": "nim" }
}
```

Key rules name language IDs. *YAML+: Show Embedded Language Regions*
lists the blocks found, their language and where it came from.

Colour comes from two places. A grammar injected into VS Code's YAML grammar
highlights blocks whose header comment names a language with that
language's grammar. The extension generates it, with the
`embeddedLanguages` that give the blocks their language's comments and
brackets, from the installed languages and the settings
([`embedded/grammar.js`](embedded/grammar.js)); VS Code reads both when a
window starts, so when they change (an extension installed, a setting
edited) the extension rewrites its `syntaxes/yaml-embedded.tmLanguage.json` and
`package.json` and offers to reload the window. Language features need no
reload. Sticky directives and key rules cannot be expressed in a TextMate
grammar, so their blocks are coloured only by semantic tokens. In all
blocks with a language, `yamllsp`'s semantic tokens, which show
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
  (`yaml+lsp.embedded.warnOnFoldedScalars`).
- Projections are files in the workspace, so servers that analyze the whole
  project may report on them, and a rename can edit project files outside
  the YAML document, as it should. `yaml+lsp.embedded.projection.root: temp`
  keeps them out of the workspace, at the cost of imports and project
  configuration.
- Projections are numbered in document order, so adding a block renames the
  projections of the blocks below it.
- Completion items' follow-up commands (auto-imports, say) and code actions
  that are only commands are dropped: they would run on the projection.

`yaml+lsp.embedded.enabled: false` turns all of this off and deletes the
projections.
