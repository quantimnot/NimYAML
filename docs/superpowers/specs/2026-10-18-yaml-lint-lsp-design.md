# YAML lint engine, lint CLI and language server — design

Date: 2026-10-18
Status: approved design, pending spec review

## Goal

Use NimYAML for all YAML tooling: a reusable lint engine in the library, a
`yamllint`-style command line linter and a language server (LSP) that
publishes the same diagnostics in editors. v1 delivers diagnostics only (no
outline, hover, completion, formatting or schema validation).

## Decisions

- **Errors live in a side collection, not in the event stream.** `YamlStream`
  consumers rely on a well-formed stream of the existing `EventKind`s; lint
  diagnostics also come from layers above the parser (event rules, text
  rules). All producers report into one `seq[Diagnostic]`.
- **Single pass engine.** `lint` parses the source once with
  `parseRecovering`, feeds every event to every enabled event rule and every
  line to every enabled text rule.
- **Library module + thin binaries.** The engine is public
  (`yaml/diagnostics.nim`, `yaml/lint.nim`); `tools/yamllint.nim` and
  `tools/yamllsp.nim` only do I/O and protocol work.
- **Own config format**, loaded with NimYAML's `loadAs` (not yamllint
  compatible).

## Facts the design relies on (verified on devel f029646)

- `parseRecovering` drops an invalid document and records one
  `YamlDocumentError` per dropped document (`error: ref YamlParserError`,
  `resumedAt: YamlDocumentStart`).
- The parser does **not** report undefined aliases (`a: *x` parses without
  error, contrary to the `YamlParserError` doc comment) nor duplicate mapping
  keys. These are lint rules.
- `Mark` is 1-based `line` and 1-based `column`, where `column` counts
  **bytes**, not characters.
- `lineContent` of an error recorded by `parseRecovering` is not reliable (it
  can be just `"\n"`); line text is taken from the source instead.

## Components

### `yaml/diagnostics.nim` (new, public)

```nim
type
  Severity* = enum
    severityError = "error", severityWarning = "warning", severityInfo = "info"

  Diagnostic* = object
    rule*: string       ## stable rule id, e.g. "syntax", "line-length"
    severity*: Severity
    startPos*, endPos*: Mark  ## endPos is exclusive
    message*: string

proc toDiagnostic*(e: YamlDocumentError, source: string): Diagnostic
proc `$`*(d: Diagnostic): string  ## "line:col: severity: message [rule]"
```

`toDiagnostic` produces rule `syntax`, severity error, the error mark as
`startPos` and the end of that source line as `endPos` (at least one column
wide). Nothing else in the library changes; `YamlDocumentError` and `errors`
stay as they are. In-document recovery and accumulating construction errors
are later projects that will report into the same type.

### `yaml/lint.nim` (new, public)

```nim
type
  RuleLevel* = enum
    levelOff = "off", levelInfo = "info", levelWarning = "warning",
    levelError = "error"

  RuleConfig* = object
    level*: RuleLevel
    max*: Option[int]   ## line-length only

  LintConfig* = object
    rules*: Table[string, RuleConfig]  ## missing ids use the rule's default

  LintContext* = object  ## passed to rules
    source*: string
    diagnostics*: seq[Diagnostic]
    # rule config lookup and the reporting severity are internal

  LintRule* = ref object of RootObj
    id*: string
    defaultLevel*: RuleLevel

method onEvent*(r: LintRule, ctx: var LintContext, e: Event) {.base.}
method onLine*(r: LintRule, ctx: var LintContext, line: int, text: string) {.base.}
method onEnd*(r: LintRule, ctx: var LintContext) {.base.}
proc report*(ctx: var LintContext, r: LintRule, startPos, endPos: Mark, message: string)

proc defaultConfig*(): LintConfig
proc loadLintConfig*(path: string): LintConfig  ## raises on invalid config
proc findLintConfig*(dir: string): string       ## walks up; "" if none
proc lint*(source: string, config = defaultConfig()): seq[Diagnostic]
```

`lint`:
1. creates fresh instances of all built-in rules and drops those whose
   effective level is `off`;
2. iterates `parseRecovering(source)` and calls `onEvent` of each rule;
3. converts `errors` to diagnostics (unless `syntax` is off);
4. splits `source` into lines (`\n`, `\r\n`; text without the line break)
   and calls `onLine` of each rule with the 1-based line number;
5. calls `onEnd` (for `unused-anchor`, `final-newline`);
6. returns diagnostics sorted by `startPos`, then rule id.

`report` uses the rule's configured level as severity. Rule state lives in
the rule instance, so a `lint` call is self-contained and reentrant.

### v1 rules

| id | default | kind | reports |
|---|---|---|---|
| `syntax` | error | parser | each error recovered from by `parseRecovering` |
| `duplicate-key` | error | event | a scalar key with the same content and the same tag as an earlier scalar key of the same mapping; range = the later key's start/end positions |
| `undefined-alias` | error | event | alias whose anchor has not been defined earlier in the same document |
| `unused-anchor` | warning | event | anchor never used by an alias in the same document; range = the anchored node's start position, one column |
| `complex-key` | warning | event | mapping key that is a sequence or mapping; range = start of the key's start event to end of its end event |
| `trailing-spaces` | warning | text | spaces/tabs before the line break; range = the whitespace |
| `line-length` | warning | text | line longer than `max` (default 120) characters (UTF-8 code points); range = from the first excess character to line end |
| `tabs` | error | text | tab characters in indentation (before the first non-whitespace character) |
| `final-newline` | warning | text | non-empty source that does not end with a line break |
| `truthy` | warning | event | plain, untagged scalar that YAML 1.1 reads as a boolean (`y`, `Y`, `yes`, `Yes`, `YES`, `n`, `N`, `no`, `No`, `NO`, `on`, `On`, `ON`, `off`, `Off`, `OFF`) |

Event rules track mapping nesting with a stack; anchors/aliases reset at each
`yamlStartDoc`. Dropped (invalid) documents produce no events, so event rules
only ever see valid documents.

### Config file `.nimyaml-lint.yaml`

```yaml
rules:
  line-length: {level: warning, max: 100}
  truthy: {level: off}
```

`findLintConfig` looks for `.nimyaml-lint.yaml` in the given directory and its
ancestors. An unknown rule id or an invalid value is a config error (reported
by the CLI as a fatal error, by the LSP as an error diagnostic at 1:1 of each
linted document, with the defaults used for linting).

### `tools/yamllint.nim` (CLI)

```
yamllint [--config:FILE] FILE...
```

- Lints each file; config is `--config` or `findLintConfig` of the file's
  directory, else defaults.
- Prints each diagnostic as `FILE:LINE:COL: SEVERITY: MESSAGE [RULE]`.
- Exit code: 0 if no diagnostic of severity error, 1 otherwise, 2 for usage,
  I/O or config errors.

### `tools/yamllsp.nim` (language server)

- JSON-RPC 2.0 over stdio with `Content-Length` framing, using `std/json`.
- Handles `initialize` (capability `textDocumentSync: 1`, full sync),
  `initialized`, `textDocument/didOpen`, `didChange`, `didSave`, `didClose`
  (publishes an empty list), `shutdown`, `exit`; unknown requests get
  `MethodNotFound`, unknown notifications are ignored.
- On open/change/save: lints the document text with the config found from
  the document's `file://` path (cached per directory, cleared on save of a
  `.nimyaml-lint.yaml`), publishes `textDocument/publishDiagnostics`.
- Position conversion: LSP line = `Mark.line - 1`; LSP character = UTF-16
  code units of the line's bytes before `Mark.column - 1`.
- Severity map: error 1, warning 2, info 3; `source: "nimyaml"`,
  `code: rule id`.

Message framing/dispatch is split from lint calls so it can be unit tested
without a process.

## Testing

- `test/tlint.nim`, added to `test/tests.nim`:
  - per rule: inputs that must and must not trigger it, asserting exact rule
    id, severity and range;
  - config: levels change severity, `off` disables, `max` is honoured,
    invalid config raises;
  - ordering of the result;
  - yaml-test-suite: every valid input yields no `syntax` diagnostic, every
    invalid input yields at least one.
- `toDiagnostic` ranges, including multi-byte content.
- LSP: unit tests for framing, UTF-16 conversion and a scripted
  `initialize`/`didOpen`/`didChange`/`shutdown`/`exit` exchange run through
  the dispatcher, checking the published diagnostics.
- CLI: compile and run on fixture files, checking output and exit codes.
- New nimble tasks `testLint`, `buildTools`.

## Out of scope for v1

Inline suppression comments, autofix, JSON/SARIF output, in-document error
recovery, accumulating construction errors, schema validation, document
symbols/outline, hover, completion, formatting, incremental sync.
