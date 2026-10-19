# `%GLOBAL` and `%SCHEMA` directives — design

Date: 2026-10-18
Status: approved by the task description; decisions below made while
designing

## Goal

Two non-standard directives for NimYAML:

- `%SCHEMA <uri-reference>` names the JSON Schema of the document that
  follows it.
- `%GLOBAL <directive> <params...>` makes a `%YAML`, `%TAG` or `%SCHEMA`
  directive apply to every document of the stream.

They have to work everywhere a stream is processed (parser, error recovery,
feed parser, checkpoints, document-boundary resume), produce diagnostics in
the lint engine and the language server, select the schema that validates a
document, and be convertible into portable YAML that other parsers read the
same way.

## Facts the design relies on (verified against YAML 1.2.2 and devel c338519)

- §6.8 defines only `YAML` and `TAG`; every other name is a *reserved
  directive* (`ns-directive-name (s-separate-in-line ns-directive-parameter)*`,
  parameters are `ns-char+`) and "a YAML processor should ignore unknown
  directives with an appropriate warning". §6.8 also says "there is no way to
  define private directives. This is intentional." `%GLOBAL` and `%SCHEMA`
  are therefore an extension outside the specification; other processors
  ignore them, which is why portable output (D4) matters.
- §6.8.1: more than one `%YAML` in a document is an error. §6.8.2: `%TAG`
  handles are scoped to the document.
- §9.2, `l-yaml-stream`: a directives document (`l-directive-document`) can
  only start the stream or follow a document suffix (`...`).
- NimYAML lexes both names as `Token.UnknownDirective`, with the rest of the
  line as one `DirectiveParam`; `beforeDoc` skips them without a warning
  (a TODO notes that warnings must survive a feed parser rollback).
- `YamlFeedParser.tryNext` rolls back by restoring a full copy of the parser
  `Context`, so state kept in the `Context` rolls back with it.
- The presenter writes `%TAG` lines from the handles of each `yamlStartDoc`
  event and `%YAML` only from `PresentationOptions.outputVersion`.
- Lint rule ids are kebab-case strings (`duplicate-key`); each is a
  `LintRule` that `.nimyaml-lint.yaml` can configure.
- Nothing in the repository reads `# yaml-language-server: $schema=`
  modelines or top-level `$schema` keys, and neither `lint` nor `yamllsp`
  validates against JSON Schema: the "existing validation path" is the
  `yaml/jsonschema` API (`SchemaRegistry.compile`, `validate`).

## Decisions

### Semantics live in the parser

`%GLOBAL TAG` changes how tags of later documents resolve, so a layer above
the parser cannot implement it. The parser `Context` keeps the global
directives and the number of documents begun; `beforeDoc` applies them. This
state is

- part of the `Context` copy that feed parser rollbacks restore,
- part of `YamlCheckpoint` (format version 2),
- carried by `YamlDocumentStart` (new fields `index` and `globals`), so that
  `parse(input, start)` of a later document still knows the globals,
- kept across error recovery: a document dropped for a syntax error after
  its directive block has still declared its globals.

### Misuse is a diagnostic, not a parse error

Every line these directives can occupy is a valid reserved directive, so
rejecting the document would make NimYAML refuse spec-valid YAML. Instead the
offending directive is ignored and an issue is recorded. Issues travel with
the `yamlStartDoc` event of their document, so they roll back, checkpoint
and recover exactly like the events. Syntax errors *inside* a wrapped
directive (`%GLOBAL YAML x.y`) are the errors that directive would raise
anyway, and remain parse errors.

`YamlParser` gets `directiveExtensions` (default `true`) and `sourceUri`.
With the extensions off, `GLOBAL` and `SCHEMA` are ordinary reserved
directives. In both modes, a reserved directive now produces the warning the
specification asks for.

### What a document carries

`yamlStartDoc` keeps `version` and `handles`, now the *effective* values
(globals overlaid by the document's own directives). A new field
`directives: DocumentDirectives` is a `ref` (nil for a document without
directives and without globals, so `Event` does not grow for every event):

- `schema`: the effective resolved `%SCHEMA` URI ("" for none),
- `declarations`: the directives in effect — globals first, marked
  `overridden` where the document replaces them — and the document's own,
  each with origin (`doGlobal`, `doDocument`), the range of its line and of
  its value,
- `issues`: the directive issues of the document's directive block.

### Diagnostic ids

| id | default | when |
|---|---|---|
| `unknown-directive` | warning | a reserved directive (§6.8) |
| `invalid-schema-directive` | error | `%SCHEMA` without exactly one URI reference |
| `duplicate-schema-directive` | error | a second `%SCHEMA` in a document |
| `unresolvable-schema-uri` | error | a relative schema reference and no source URI |
| `misplaced-global-directive` | error | `%GLOBAL` outside the first directive block |
| `missing-global-directive` | error | `%GLOBAL` without a directive |
| `nested-global-directive` | error | `%GLOBAL GLOBAL` |
| `duplicate-global-directive` | error | a second global `YAML`/`SCHEMA` or the same `TAG` handle |
| `unknown-global-directive` | warning | `%GLOBAL FOO` (ignored) |
| `schema-source` | info | several schema sources; names the winner |
| `schema-validation` | error | the document violates its schema |
| `schema-unavailable` | warning | the schema cannot be loaded or compiled |

The first ten are lint rules (configurable like the others); the last two
come from validation, which needs a schema loader and the DOM, so they are
produced by `yaml/schemavalidation` and published by the tools.

Invalid directives are ignored entirely. A relative `%SCHEMA` without a
source URI does not override a global schema.

### Schema selection (`yaml/documentschema`)

Per document, candidates in precedence order: per-document `%SCHEMA`,
`%GLOBAL SCHEMA`, a `# yaml-language-server: $schema=URI` modeline, a
top-level `$schema` key with a string value. Relative references of all four
resolve against the source URI. A modeline belongs to the document whose
source span (from its `YamlDocumentStart` to the next one) contains it, so a
modeline above the first document applies to the first document. The highest
candidate wins; if there is more than one, a `schema-source` info names the
winner and the others. Schemas are never merged.

The selection works on events and lines (no DOM) through a collector, so the
single-pass `lint` engine can run it as the `schema-source` rule.

### Portable output (`yaml/portable`, `tools/yamlexpand`)

`expandDirectives(source)` rewrites the *text*: it removes `%GLOBAL` lines,
writes the effective global directives into every document's directive block
(skipping those the document overrides), inserts `---` after directives of a
document that had none, and `...` before a directives document whose
predecessor was not closed (§9.2). Optionally `%SCHEMA` becomes a modeline.
Rewriting text rather than re-presenting events keeps comments, styles and
layout. The presenter additionally gets `outputVersion = ovDocument` (write
each document's version) and `schemaDirective` (`sdNone`, `sdDirective`,
`sdModeline`), so event-based output can carry the directives too.

### Language server

`yamllsp` publishes lint diagnostics plus schema validation (schemas from
`file://` URIs only; no network access) and adds completion (directive names
after `%`, inner names after `%GLOBAL`), hover (effective value and origin on
a directive; the effective directives on a `---`/`...` marker),
go-to-definition and document links on `%SCHEMA` URIs.

## Testing

- `test/tdirectives.nim`: parser semantics (single and multi-document,
  inheritance, every override, every issue with position, relative URIs with
  and without source URI, extensions off), feed parser, checkpoints,
  `parse(start)`, recovery.
- `test/tdocumentschema.nim`: precedence of the four sources, modeline
  association, `schema-source`, validation diagnostics.
- `test/tportable.nim`: expansion fixtures that round-trip to the same events
  (tags included) when read by a parser with the extensions off; presenter
  options.
- `test/tlint.nim`, `test/tlsp.nim`, `test/tyamllint.nim`: new rules, LSP
  features, CLI.
- The yaml-test-suite tests (`tparser`, the lint suite) must not regress.
