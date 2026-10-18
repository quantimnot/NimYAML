# YAML Lint Engine, Lint CLI and Language Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public lint engine (`yaml/diagnostics.nim`, `yaml/lint.nim`) plus a `yamllint` CLI and a `yamllsp` language server built on it.

**Architecture:** `lint` parses the source once with `parseRecovering`, feeds events to event rules and lines to text rules, converts recovered parser errors into `Diagnostic`s and returns everything sorted by position. Rules are `ref object of LintRule` with `onEvent`/`onLine`/`onEnd` methods. The CLI and LSP are thin binaries in `tools/`.

**Tech Stack:** Nim ≥ 2.0, NimYAML (`parser`, `stream`, `loading`, `annotations`), `std/json`, `std/unittest`.

**Spec:** `docs/superpowers/specs/2026-10-18-yaml-lint-lsp-design.md`

**Conventions:**
- Run nimscript tasks as `nim <task> config.nims` (bare `nim <task>` crashes with current upstream Nim).
- On Nim 2.3.1 devel, `nim <task> config.nims` only type-checks and builds no binary. There, run each "Run:" command as a direct compile instead: `lintTests` → `nim c -r test/tlint`, `yamllintTests` → `nim c -r test/tyamllint`, `lspTests` → `nim c -r test/tlsp`, `yamllsp` → `nim c -d:release tools/yamllsp`, `test` → `nim c -r test/tests`.
- Module headers follow the `yaml/dom.nim` style (license comment, `## ====` title).
- Tests use `std/unittest`, one `suite` per component.

**Deviations from the spec, decided while planning:**
- `RuleConfig.level` is `Option[RuleLevel]` (missing = the rule's default level); `RuleConfig` is `{.sparse.}`; `LintConfig.rules` has `{.defaultVal.}`. Verified with `load`.
- Blank or comment-only config files mean the defaults (`load` rejects a stream with no documents).
- A negative `max` is a config error.
- `initialize` announces `textDocumentSync` as `{openClose: true, change: 1, save: {includeText: false}}` (still full sync; the object form is needed to receive `didSave`).

---

## File structure

| File | Responsibility |
|---|---|
| `yaml/diagnostics.nim` (create) | `Severity`, `Diagnostic`, `sourceLines`, `lineAt`, `toDiagnostic`, `$` |
| `yaml/lint.nim` (create) | config types and loading, `LintRule` and hooks, built-in rules, `lint` |
| `tools/yamllint.nim` (create) | CLI: options, config lookup, output, exit code |
| `tools/yamllsp.nim` (create) | framing, UTF-16 positions, `Server.handle`, stdio loop |
| `test/tlint.nim` (create) | diagnostics, rules, config tests |
| `test/tlsp.nim` (create) | LSP framing, positions, dispatcher tests |
| `test/tyamllint.nim` (create) | CLI end-to-end tests (compiles the binary) |
| `test/tests.nim` (modify) | import new tests |
| `config.nims` (modify) | `lintTests`, `lspTests`, `yamllint`, `yamllsp` tasks |
| `.gitignore`, `README.md`, `CHANGELOG.md`, `yaml/parser.nim` (modify) | ignore binaries, docs, stale doc comment |

---

### Task 1: `yaml/diagnostics.nim`

**Files:**
- Create: `yaml/diagnostics.nim`
- Create: `test/tlint.nim`
- Modify: `config.nims` (after the `documentTests` task)

- [ ] **Step 1: Add the test task to `config.nims`** after the `documentTests` task:

```nim
task lintTests, "Run diagnostics and lint tests":
  --r
  --verbosity:0
  setCommand "c", "test/tlint"
```

- [ ] **Step 2: Write the failing test** `test/tlint.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, strutils, unittest, algorithm, options, tables]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml/[data, parser, stream, diagnostics]

proc span(d: Diagnostic): string =
  d.rule & " " & $d.startPos.line & ":" & $d.startPos.column & "-" &
      $d.endPos.line & ":" & $d.endPos.column & " " & $d.severity

proc allLines(source: string): seq[(int, string)] =
  for n, text in source.sourceLines: result.add((n, text))

suite "Diagnostics":
  test "sourceLines splits on LF and CRLF, without a trailing empty line":
    check allLines("a\r\nb\n\nc") == @[(1, "a"), (2, "b"), (3, ""), (4, "c")]
    check allLines("a\n") == @[(1, "a")]
    check allLines("").len == 0

  test "lineAt":
    check lineAt("a\nbc\n", 2) == "bc"
    check lineAt("a\nbc\n", 5) == ""

  test "toDiagnostic: range to the end of the line, byte columns":
    let source = "x: \"é\" bad\n"
    let rs = initYamlParser().parseRecovering(source)
    for e in rs: discard
    check rs.errors.len == 1
    let d = rs.errors[0].toDiagnostic(source)
    check d.span == "syntax 1:9-1:12 error"
    check d.message == rs.errors[0].error.msg
    check $d == "1:9: error: " & d.message & " [syntax]"

  test "toDiagnostic: at least one column wide":
    let source = "a: [\n"
    let rs = initYamlParser().parseRecovering(source)
    for e in rs: discard
    check rs.errors.len == 1
    let d = rs.errors[0].toDiagnostic(source)
    check d.endPos.line == d.startPos.line
    check d.endPos.column > d.startPos.column
```

- [ ] **Step 3: Run it, expect a compile failure**

Run: `nim lintTests config.nims`
Expected: FAIL, `cannot open file: ../yaml/diagnostics`

- [ ] **Step 4: Implement** `yaml/diagnostics.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =======================
## Module yaml/diagnostics
## =======================
##
## Diagnostics are errors and warnings about YAML input with a source range.
## They are produced by `lint <lint.html>`_ and can be created from the
## errors that `parseRecovering` recovered from. Positions are `Mark` values:
## 1-based lines and 1-based columns counting bytes.

import std/strutils
import data, parser

type
  Severity* = enum
    severityError = "error", severityWarning = "warning",
    severityInfo = "info"

  Diagnostic* = object
    rule*: string       ## stable id of the rule that reported it
    severity*: Severity
    startPos*, endPos*: Mark ## ``endPos`` is exclusive
    message*: string

iterator sourceLines*(source: string): (int, string) =
  ## Yields the 1-based number and the text (without line break) of each
  ## line of ``source``. Lines end with LF or CRLF; text after the last line
  ## break is a line, an empty string after it is not.
  var
    n = 1
    i = 0
  while i < source.len:
    var stop = source.find('\n', i)
    let next = if stop < 0: source.len else: stop + 1
    if stop < 0: stop = source.len
    if stop > i and source[stop - 1] == '\r': dec(stop)
    yield (n, source[i ..< stop])
    inc(n)
    i = next

proc lineAt*(source: string, line: Positive): string =
  ## The text of line ``line`` of ``source``, "" if there is no such line.
  for n, text in source.sourceLines:
    if n == line: return text

proc toDiagnostic*(e: YamlDocumentError, source: string): Diagnostic =
  ## A diagnostic with rule ``syntax`` and severity error for an error that
  ## `parseRecovering` recovered from. ``source`` is the parsed input; the
  ## range spans from the error position to the end of its line and is at
  ## least one column wide.
  let mark = e.error.mark
  let lineEnd = source.lineAt(mark.line).len + 1
  result = Diagnostic(rule: "syntax", severity: severityError,
      startPos: mark, message: e.error.msg,
      endPos: Mark(line: mark.line,
                   column: Positive(max(mark.column + 1, lineEnd))))

proc `$`*(d: Diagnostic): string =
  ## ``line:column: severity: message [rule]``
  $d.startPos.line & ":" & $d.startPos.column & ": " & $d.severity & ": " &
      d.message & " [" & d.rule & "]"
```

- [ ] **Step 5: Run the test, expect PASS**

Run: `nim lintTests config.nims`
Expected: all `Diagnostics` tests `[OK]`. If `toDiagnostic` columns differ, inspect with the `describe` helper approach from `test/tdocuments.nim` before changing expectations.

- [ ] **Step 6: Commit**

```bash
git add yaml/diagnostics.nim test/tlint.nim config.nims
git commit -m "Add Diagnostic type and conversion from recovered parser errors"
```

---

### Task 2: lint engine core with the `syntax` rule

**Files:**
- Create: `yaml/lint.nim`
- Modify: `test/tlint.nim`

- [ ] **Step 1: Write the failing tests.** In `test/tlint.nim` change the import to `import ../yaml/[data, parser, stream, diagnostics, lint]` and append:

```nim
proc spans(source: string, config = defaultConfig()): seq[string] =
  for d in lint(source, config): result.add(d.span)

proc only(id: string, rc = RuleConfig()): LintConfig =
  ## a config that enables only rule ``id``, configured with ``rc``
  for other in builtinRuleIds():
    if other != id: result.rules[other] = RuleConfig(level: some(levelOff))
  result.rules[id] = rc

proc suiteInputs(): seq[string] =
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path:
      result.add(path)
  result.sort()

proc parses(input: string): bool =
  try:
    for e in initYamlParser().parse(input): discard
    result = true
  except CatchableError: result = false

suite "Lint: syntax":
  test "valid input":
    check spans("a: 1\n", only("syntax")).len == 0

  test "invalid document":
    check spans("x: \"é\" bad\n", only("syntax")) == @["syntax 1:9-1:12 error"]

  test "one error per invalid document, valid documents are kept":
    check spans("a: 1\n---\nx: \"y\" bad\n---\nb: 2\n", only("syntax")) ==
        @["syntax 3:9-3:12 error"]

  test "configured level":
    check spans("x: \"é\" bad\n",
        only("syntax", RuleConfig(level: some(levelWarning)))) ==
        @["syntax 1:9-1:12 warning"]

  test "off":
    var config = defaultConfig()
    config.rules["syntax"] = RuleConfig(level: some(levelOff))
    check spans("x: \"é\" bad\n", config).len == 0

  test "yaml-test-suite: syntax diagnostics iff the input is invalid":
    var valid, invalid = 0
    for path in suiteInputs():
      let input = readFile(path)
      var syntax = 0
      for d in lint(input, only("syntax")):
        if d.rule == "syntax": inc(syntax)
      if parses(input):
        inc(valid)
        if syntax != 0: checkpoint(path)
        check syntax == 0
      else:
        inc(invalid)
        if syntax == 0: checkpoint(path)
        check syntax > 0
    check valid > 0
    check invalid > 0
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `nim lintTests config.nims`
Expected: FAIL, `cannot open file: ../yaml/lint`

- [ ] **Step 3: Implement** `yaml/lint.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ================
## Module yaml/lint
## ================
##
## A lint engine for YAML sources. `lint` parses a source once with
## `parseRecovering` and runs the enabled rules over its events and lines.
## It returns `Diagnostic`s sorted by position. Rules are configured with a
## `LintConfig`, usually loaded from a ``.nimyaml-lint.yaml`` file:
##
## .. code-block:: yaml
##   rules:
##     line-length: {level: warning, max: 100}
##     truthy: {level: off}
##
## Events of invalid documents are dropped by `parseRecovering`, so event
## rules only see valid documents; the ``syntax`` rule reports the errors.

import std/[algorithm, options, os, sets, strutils, tables]
from std/unicode import runeLen, runeOffset
import data, parser, stream, loading, annotations, diagnostics
export options, tables, diagnostics

type
  RuleLevel* = enum
    levelOff = "off", levelInfo = "info", levelWarning = "warning",
    levelError = "error"

  RuleConfig* {.sparse.} = object
    level*: Option[RuleLevel] ## none: the rule's default level
    max*: Option[int]         ## ``line-length`` only

  LintConfig* = object
    rules* {.defaultVal: initTable[string, RuleConfig]().}:
      Table[string, RuleConfig] ## rules not listed use their defaults

  LintConfigError* = object of ValueError

  LintContext* = object
    ## State of one `lint` call, passed to the rules.
    source*: string
    diagnostics*: seq[Diagnostic]

  LintRule* = ref object of RootObj
    ## Base of all rules. `lint` creates fresh instances for each call, so
    ## rules may keep state in their fields.
    id*: string
    level*: RuleLevel   ## default level; `lint` applies the configured one
    config*: RuleConfig

  SyntaxRule = ref object of LintRule

const configFileName* = ".nimyaml-lint.yaml"

proc mark(line, column: int): Mark =
  Mark(line: Positive(line), column: Positive(column))

proc severity(level: RuleLevel): Severity =
  case level
  of levelError: severityError
  of levelWarning: severityWarning
  of levelInfo, levelOff: severityInfo

method onEvent*(r: LintRule, ctx: var LintContext, e: Event) {.base.} =
  ## Called for each event of the valid documents of the source.
  discard

method onLine*(r: LintRule, ctx: var LintContext, line: int,
    text: string) {.base.} =
  ## Called for each line of the source (1-based, without line break),
  ## after all events.
  discard

method onEnd*(r: LintRule, ctx: var LintContext) {.base.} =
  ## Called once after all events and lines.
  discard

proc report*(ctx: var LintContext, r: LintRule, startPos, endPos: Mark,
    message: string) =
  ## Adds a diagnostic of rule ``r`` with the rule's level as severity.
  ctx.diagnostics.add(Diagnostic(rule: r.id, severity: r.level.severity,
      startPos: startPos, endPos: endPos, message: message))

# rules

# registry

proc builtinRules*(): seq[LintRule] =
  ## Fresh instances of all built-in rules, with their default levels.
  @[LintRule(SyntaxRule(id: "syntax", level: levelError))]

proc builtinRuleIds*(): seq[string] =
  for r in builtinRules(): result.add(r.id)

proc defaultConfig*(): LintConfig = LintConfig()

proc cmpDiagnostics(a, b: Diagnostic): int =
  result = cmp(a.startPos.line, b.startPos.line)
  if result == 0: result = cmp(a.startPos.column, b.startPos.column)
  if result == 0: result = cmp(a.rule, b.rule)

proc lint*(source: string, config = defaultConfig()): seq[Diagnostic] =
  ## Lints ``source`` with the rules enabled by ``config``. Returns the
  ## diagnostics sorted by start position, then rule id.
  var
    ctx = LintContext(source: source)
    rules: seq[LintRule]
    syntax: LintRule = nil
  for r in builtinRules():
    r.config = config.rules.getOrDefault(r.id)
    if r.config.level.isSome: r.level = r.config.level.get()
    if r.level == levelOff: continue
    if r of SyntaxRule: syntax = r
    else: rules.add(r)
  let events = initYamlParser().parseRecovering(source)
  for e in events:
    for r in rules: r.onEvent(ctx, e)
  if not syntax.isNil:
    for err in events.errors:
      var d = err.toDiagnostic(source)
      d.severity = syntax.level.severity
      ctx.diagnostics.add(d)
  for n, text in source.sourceLines:
    for r in rules: r.onLine(ctx, n, text)
  for r in rules: r.onEnd(ctx)
  result = move(ctx.diagnostics)
  result.sort(cmpDiagnostics)
```

(Imports not used yet — `os`, `sets`, `strutils`, `unicode`, `loading` — are used by Tasks 3–6. Unused-import hints are expected until then.)

- [ ] **Step 4: Run, expect PASS**

Run: `nim lintTests config.nims`
Expected: `Diagnostics` and `Lint: syntax` tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add yaml/lint.nim test/tlint.nim
git commit -m "Add lint engine with the syntax rule"
```

---

### Task 3: text rules

**Files:**
- Modify: `yaml/lint.nim` (rules section, registry)
- Modify: `test/tlint.nim`

- [ ] **Step 1: Write the failing tests** (append to `test/tlint.nim`):

```nim
suite "Lint: text rules":
  test "trailing-spaces":
    check spans("a: 1  \nb: 2\t\nc: 3\n", only("trailing-spaces")) ==
        @["trailing-spaces 1:5-1:7 warning", "trailing-spaces 2:5-2:6 warning"]
    check lint("a: 1 \n", only("trailing-spaces"))[0].message ==
        "trailing whitespace"

  test "line-length":
    let config = only("line-length", RuleConfig(max: some(5)))
    check spans("abcdef: 1\nab: 1\n", config) ==
        @["line-length 1:6-1:10 warning"]
    check lint("abcdef: 1\n", config)[0].message ==
        "line too long (9 > 5 characters)"

  test "line-length counts characters, columns are bytes":
    check spans("é: ééé\n", only("line-length", RuleConfig(max: some(5)))) ==
        @["line-length 1:9-1:11 warning"]

  test "line-length default is 120":
    check spans("a: " & 'x'.repeat(117) & "\n", only("line-length")).len == 0
    check spans("a: " & 'x'.repeat(118) & "\n", only("line-length")) ==
        @["line-length 1:121-1:122 warning"]

  test "tabs in indentation":
    check spans("  \tx\n", only("tabs")) == @["tabs 1:3-1:4 error"]
    check spans("a:\tb\n", only("tabs")).len == 0

  test "final-newline":
    check spans("a: 1", only("final-newline")) ==
        @["final-newline 1:5-1:6 warning"]
    check spans("a: 1\nb: 2", only("final-newline")) ==
        @["final-newline 2:5-2:6 warning"]
    check spans("a: 1\n", only("final-newline")).len == 0
    check spans("", only("final-newline")).len == 0
```

- [ ] **Step 2: Run, expect failure**

Run: `nim lintTests config.nims`
Expected: FAIL — `only` puts unknown ids into the config and the tests get no diagnostics (e.g. `trailing-spaces` check fails with `@[] == @[...]`).

- [ ] **Step 3: Implement.** In `yaml/lint.nim` replace the line `# rules` with:

```nim
# rules

const defaultMaxLineLength* = 120

type
  TrailingSpacesRule = ref object of LintRule
  LineLengthRule = ref object of LintRule
  TabsRule = ref object of LintRule
  FinalNewlineRule = ref object of LintRule

method onLine(r: TrailingSpacesRule, ctx: var LintContext, line: int,
    text: string) =
  var start = text.len
  while start > 0 and text[start - 1] in {' ', '\t'}: dec(start)
  if start < text.len:
    ctx.report(r, mark(line, start + 1), mark(line, text.len + 1),
        "trailing whitespace")

method onLine(r: LineLengthRule, ctx: var LintContext, line: int,
    text: string) =
  let limit = r.config.max.get(defaultMaxLineLength)
  let length = text.runeLen
  if length > limit:
    ctx.report(r, mark(line, text.runeOffset(limit) + 1),
        mark(line, text.len + 1),
        "line too long (" & $length & " > " & $limit & " characters)")

method onLine(r: TabsRule, ctx: var LintContext, line: int, text: string) =
  for i, c in text:
    case c
    of '\t':
      ctx.report(r, mark(line, i + 1), mark(line, i + 2),
          "tab character in indentation")
      return
    of ' ': discard
    else: return

method onEnd(r: FinalNewlineRule, ctx: var LintContext) =
  if ctx.source.len > 0 and ctx.source[^1] != '\n':
    var
      line = 1
      last = ""
    for n, text in ctx.source.sourceLines:
      line = n
      last = text
    ctx.report(r, mark(line, last.len + 1), mark(line, last.len + 2),
        "no line break at end of file")
```

and replace the body of `builtinRules` with:

```nim
  @[LintRule(SyntaxRule(id: "syntax", level: levelError)),
    TrailingSpacesRule(id: "trailing-spaces", level: levelWarning),
    LineLengthRule(id: "line-length", level: levelWarning),
    TabsRule(id: "tabs", level: levelError),
    FinalNewlineRule(id: "final-newline", level: levelWarning)]
```

- [ ] **Step 4: Run, expect PASS**

Run: `nim lintTests config.nims`
Expected: all tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add yaml/lint.nim test/tlint.nim
git commit -m "Add text lint rules: trailing-spaces, line-length, tabs, final-newline"
```

---

### Task 4: mapping key rules

**Files:**
- Modify: `yaml/lint.nim` (rules section, registry)
- Modify: `test/tlint.nim`

- [ ] **Step 1: Write the failing tests** (append):

```nim
suite "Lint: mapping keys":
  test "duplicate-key, block and flow":
    check spans("a: 1\na: 2\n", only("duplicate-key")) ==
        @["duplicate-key 2:1-2:2 error"]
    check spans("{a: 1, a: 2}\n", only("duplicate-key")) ==
        @["duplicate-key 1:8-1:9 error"]
    check lint("a: 1\na: 2\n", only("duplicate-key"))[0].message ==
        "duplicate mapping key \"a\""

  test "duplicate-key: only within one mapping and document":
    check spans("x: {a: 1}\ny: {a: 1}\n", only("duplicate-key")).len == 0
    check spans("a: 1\nb: 1\n", only("duplicate-key")).len == 0
    check spans("a: 1\n---\na: 2\n", only("duplicate-key")).len == 0
    check spans("- a\n- a\n", only("duplicate-key")).len == 0

  test "duplicate-key: same content and tag":
    check spans("a: 1\n\"a\": 2\n", only("duplicate-key")).len == 0

  test "duplicate-key after a complex key":
    check spans("? [a]\n: 1\na: 2\na: 3\n", only("duplicate-key")) ==
        @["duplicate-key 4:1-4:2 error"]

  test "complex-key":
    check spans("? [1, 2]\n: v\n", only("complex-key")) ==
        @["complex-key 1:3-1:9 warning"]
    check lint("? [1, 2]\n: v\n", only("complex-key"))[0].message ==
        "mapping key is a sequence"
    check lint("? {a: 1}\n: v\n", only("complex-key"))[0].message ==
        "mapping key is a mapping"
    check spans("a: [1, 2]\n", only("complex-key")).len == 0
```

- [ ] **Step 2: Run, expect failure**

Run: `nim lintTests config.nims`
Expected: FAIL on the new suite (`@[] == @[...]`).

- [ ] **Step 3: Implement.** Append to the rules section of `yaml/lint.nim` (before `# registry`):

```nim
type
  Frame = object
    isMap, atKey, isKey: bool
    start: Mark
    keys: HashSet[string] # tag & '\0' & content of the scalar keys

  KeyTracker = object
    ## Tracks whether nodes are mapping keys.
    frames: seq[Frame]
    ended: Frame # frame of the collection ended by the last event

proc nextIsKey(t: var KeyTracker): bool =
  if t.frames.len > 0 and t.frames[^1].isMap:
    result = t.frames[^1].atKey
    t.frames[^1].atKey = not result

proc track(t: var KeyTracker, e: Event): bool =
  ## Updates ``t`` with ``e``. Returns whether ``e`` starts a mapping key.
  case e.kind
  of yamlStartDoc: t.frames.setLen(0)
  of yamlScalar, yamlAlias: result = t.nextIsKey()
  of yamlStartMap, yamlStartSeq:
    result = t.nextIsKey()
    t.frames.add(Frame(isMap: e.kind == yamlStartMap, atKey: true,
        isKey: result, start: e.startPos))
  of yamlEndMap, yamlEndSeq: t.ended = t.frames.pop()
  else: discard

type
  DuplicateKeyRule = ref object of LintRule
    tracker: KeyTracker
  ComplexKeyRule = ref object of LintRule
    tracker: KeyTracker

method onEvent(r: DuplicateKeyRule, ctx: var LintContext, e: Event) =
  if r.tracker.track(e) and e.kind == yamlScalar:
    let key = $e.scalarProperties.tag & '\0' & e.scalarContent
    if r.tracker.frames[^1].keys.containsOrIncl(key):
      ctx.report(r, e.startPos, e.endPos,
          "duplicate mapping key " & e.scalarContent.escape)

method onEvent(r: ComplexKeyRule, ctx: var LintContext, e: Event) =
  discard r.tracker.track(e)
  if e.kind in {yamlEndMap, yamlEndSeq} and r.tracker.ended.isKey:
    ctx.report(r, r.tracker.ended.start, e.endPos, "mapping key is a " &
        (if e.kind == yamlEndMap: "mapping" else: "sequence"))
```

and add to `builtinRules` after the `syntax` entry:

```nim
    DuplicateKeyRule(id: "duplicate-key", level: levelError),
    ComplexKeyRule(id: "complex-key", level: levelWarning),
```

- [ ] **Step 4: Run, expect PASS**

Run: `nim lintTests config.nims`
Expected: all tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add yaml/lint.nim test/tlint.nim
git commit -m "Add mapping key lint rules: duplicate-key, complex-key"
```

---

### Task 5: anchor rules and `truthy`

**Files:**
- Modify: `yaml/lint.nim` (rules section, registry)
- Modify: `test/tlint.nim`

- [ ] **Step 1: Write the failing tests** (append):

```nim
suite "Lint: anchors and aliases":
  test "defined and used anchor":
    check spans("x: &a 1\ny: *a\n", only("undefined-alias")).len == 0
    check spans("x: &a 1\ny: *a\n", only("unused-anchor")).len == 0

  test "undefined-alias":
    check spans("y: *b\n", only("undefined-alias")) ==
        @["undefined-alias 1:4-1:6 error"]
    check lint("y: *b\n", only("undefined-alias"))[0].message ==
        "undefined alias *b"

  test "undefined-alias: anchor defined later or in another document":
    check spans("y: *a\nx: &a 1\n", only("undefined-alias")) ==
        @["undefined-alias 1:4-1:6 error"]
    check spans("x: &a 1\n---\ny: *a\n", only("undefined-alias")) ==
        @["undefined-alias 3:4-3:6 error"]

  test "unused-anchor":
    check spans("x: &a 1\n", only("unused-anchor")) ==
        @["unused-anchor 1:4-1:5 warning"]
    check lint("x: &a 1\n", only("unused-anchor"))[0].message ==
        "unused anchor &a"
    check spans("&m\n- a\n", only("unused-anchor")) ==
        @["unused-anchor 1:1-1:2 warning"]

  test "unused-anchor: redefined before use":
    check spans("x: &a 1\ny: &a 2\nz: *a\n", only("unused-anchor")) ==
        @["unused-anchor 1:4-1:5 warning"]

suite "Lint: truthy":
  test "plain YAML 1.1 booleans":
    check spans("k: yes\n", only("truthy")) == @["truthy 1:4-1:7 warning"]
    check spans("yes: 1\n", only("truthy")) == @["truthy 1:1-1:4 warning"]
    check lint("k: off\n", only("truthy"))[0].message ==
        "\"off\" is a boolean in YAML 1.1; quote it or use true/false"

  test "quoted, tagged and YAML 1.2 booleans are fine":
    check spans("k: \"yes\"\n", only("truthy")).len == 0
    check spans("k: !!str yes\n", only("truthy")).len == 0
    check spans("k: true\n", only("truthy")).len == 0

suite "Lint: all rules":
  test "defaults, sorted by position":
    check spans("a: yes \n") ==
        @["truthy 1:4-1:7 warning", "trailing-spaces 1:7-1:8 warning"]

  test "built-in rule ids":
    check builtinRuleIds() == @["syntax", "duplicate-key", "complex-key",
        "undefined-alias", "unused-anchor", "truthy", "trailing-spaces",
        "line-length", "tabs", "final-newline"]
```

- [ ] **Step 2: Run, expect failure**

Run: `nim lintTests config.nims`
Expected: FAIL on the new suites.

- [ ] **Step 3: Implement.** Append to the rules section (before `# registry`):

```nim
type
  UndefinedAliasRule = ref object of LintRule
    defined: HashSet[Anchor]
  UnusedAnchorRule = ref object of LintRule
    anchors: OrderedTable[Anchor, tuple[pos: Mark, used: bool]]
  TruthyRule = ref object of LintRule

proc anchorOf(e: Event): Anchor =
  case e.kind
  of yamlScalar: e.scalarProperties.anchor
  of yamlStartMap: e.mapProperties.anchor
  of yamlStartSeq: e.seqProperties.anchor
  else: yAnchorNone

method onEvent(r: UndefinedAliasRule, ctx: var LintContext, e: Event) =
  case e.kind
  of yamlStartDoc: r.defined.clear()
  of yamlAlias:
    if e.aliasTarget notin r.defined:
      ctx.report(r, e.startPos, e.endPos,
          "undefined alias *" & $e.aliasTarget)
  else:
    let anchor = e.anchorOf
    if anchor != yAnchorNone: r.defined.incl(anchor)

proc reportUnused(r: UnusedAnchorRule, ctx: var LintContext, anchor: Anchor,
    pos: Mark) =
  ctx.report(r, pos, mark(pos.line, pos.column + 1),
      "unused anchor &" & $anchor)

method onEvent(r: UnusedAnchorRule, ctx: var LintContext, e: Event) =
  case e.kind
  of yamlStartDoc: r.anchors.clear()
  of yamlEndDoc:
    for anchor, info in r.anchors:
      if not info.used: r.reportUnused(ctx, anchor, info.pos)
  of yamlAlias:
    if e.aliasTarget in r.anchors: r.anchors[e.aliasTarget].used = true
  else:
    let anchor = e.anchorOf
    if anchor != yAnchorNone:
      if anchor in r.anchors and not r.anchors[anchor].used:
        r.reportUnused(ctx, anchor, r.anchors[anchor].pos)
      r.anchors[anchor] = (pos: e.startPos, used: false)

const yaml11Booleans = ["y", "Y", "yes", "Yes", "YES", "n", "N", "no", "No",
    "NO", "on", "On", "ON", "off", "Off", "OFF"]

method onEvent(r: TruthyRule, ctx: var LintContext, e: Event) =
  if e.kind == yamlScalar and e.scalarStyle == ssPlain and
      e.scalarProperties.tag == yTagQuestionMark and
      e.scalarContent in yaml11Booleans:
    ctx.report(r, e.startPos, e.endPos, "\"" & e.scalarContent &
        "\" is a boolean in YAML 1.1; quote it or use true/false")
```

and make `builtinRules` return, in this order:

```nim
  @[LintRule(SyntaxRule(id: "syntax", level: levelError)),
    DuplicateKeyRule(id: "duplicate-key", level: levelError),
    ComplexKeyRule(id: "complex-key", level: levelWarning),
    UndefinedAliasRule(id: "undefined-alias", level: levelError),
    UnusedAnchorRule(id: "unused-anchor", level: levelWarning),
    TruthyRule(id: "truthy", level: levelWarning),
    TrailingSpacesRule(id: "trailing-spaces", level: levelWarning),
    LineLengthRule(id: "line-length", level: levelWarning),
    TabsRule(id: "tabs", level: levelError),
    FinalNewlineRule(id: "final-newline", level: levelWarning)]
```

- [ ] **Step 4: Run, expect PASS**

Run: `nim lintTests config.nims`
Expected: all tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add yaml/lint.nim test/tlint.nim
git commit -m "Add anchor lint rules and truthy rule"
```

---

### Task 6: config loading

**Files:**
- Modify: `yaml/lint.nim` (after `defaultConfig`)
- Modify: `test/tlint.nim`

- [ ] **Step 1: Write the failing tests** (append):

```nim
suite "Lint config":
  test "blank and comment-only configs are the defaults":
    check parseLintConfig("").rules.len == 0
    check parseLintConfig("# nothing\n\n").rules.len == 0

  test "levels and options":
    let config = parseLintConfig(
        "rules:\n  line-length: {level: error, max: 3}\n  truthy: {level: off}\n")
    check config.rules["line-length"].level == some(levelError)
    check config.rules["line-length"].max == some(3)
    check spans("abcd\nk: yes\n", config) ==
        @["line-length 1:4-1:5 error"]

  test "a rule without level keeps its default":
    let config = parseLintConfig("rules:\n  line-length: {max: 3}\n")
    check spans("abcd\n", config) == @["line-length 1:4-1:5 warning"]

  test "invalid configs":
    expect LintConfigError: discard parseLintConfig("rules:\n  nope: {}\n")
    expect LintConfigError:
      discard parseLintConfig("rules:\n  tabs: {level: bogus}\n")
    expect LintConfigError:
      discard parseLintConfig("rules:\n  line-length: {max: -1}\n")
    expect LintConfigError: discard parseLintConfig("rulez: 1\n")
    try:
      discard parseLintConfig("rules:\n  nope: {}\n")
    except LintConfigError as e:
      check e.msg == "unknown rule: nope"

  test "loadLintConfig and findLintConfig":
    let root = getTempDir() / ("nimyaml-lint-test-" & $getCurrentProcessId())
    createDir(root / "a" / "b")
    defer: removeDir(root)
    let path = root / "a" / configFileName
    writeFile(path, "rules:\n  truthy: {level: error}\n")
    check findLintConfig(root / "a" / "b") == path
    check findLintConfig(root / "a") == path
    check findLintConfig(root) == ""
    check loadLintConfig(path).rules["truthy"].level == some(levelError)
    writeFile(path, "rules:\n  nope: {}\n")
    try:
      discard loadLintConfig(path)
      check false
    except LintConfigError as e:
      check e.msg.startsWith(path & ": ")
    expect LintConfigError: discard loadLintConfig(root / "missing.yaml")
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `nim lintTests config.nims`
Expected: FAIL, `undeclared identifier: 'parseLintConfig'`

- [ ] **Step 3: Implement.** Insert after `proc defaultConfig*` in `yaml/lint.nim`:

```nim
proc isBlank(content: string): bool =
  for line in content.splitLines:
    let text = line.strip()
    if text.len > 0 and text[0] != '#': return false
  true

proc parseLintConfig*(content: string): LintConfig =
  ## Parses the content of a lint config file. Blank or comment-only content
  ## yields `defaultConfig`. Raises `LintConfigError` if the content is
  ## invalid, names an unknown rule or has a negative ``max``.
  if content.isBlank: return defaultConfig()
  try:
    load(content, result)
  except YamlLoadingError as e:
    raise newException(LintConfigError,
        $e.mark.line & ":" & $e.mark.column & ": " & e.msg)
  let ids = builtinRuleIds()
  for id, rule in result.rules:
    if id notin ids:
      raise newException(LintConfigError, "unknown rule: " & id)
    if rule.max.isSome and rule.max.get() < 0:
      raise newException(LintConfigError,
          id & ": max must not be negative")

proc loadLintConfig*(path: string): LintConfig =
  ## Loads the lint config file at ``path``. Raises `LintConfigError`, with
  ## a message starting with ``path``, if it cannot be read or is invalid.
  var content: string
  try:
    content = readFile(path)
  except IOError as e:
    raise newException(LintConfigError, path & ": " & e.msg)
  try:
    result = parseLintConfig(content)
  except LintConfigError as e:
    raise newException(LintConfigError, path & ": " & e.msg)

proc findLintConfig*(dir: string): string =
  ## The path of the ``.nimyaml-lint.yaml`` in ``dir`` or its nearest
  ## ancestor that has one; "" if there is none.
  var current = absolutePath(dir)
  while true:
    let path = current / configFileName
    if fileExists(path): return path
    let parent = current.parentDir()
    if parent.len == 0 or parent == current: return ""
    current = parent
```

If the compiler reports that `load` can raise exceptions not covered (e.g. `IOError`, `OSError`), add them to the `except` of the `load` call, mapping their message the same way without a position.

- [ ] **Step 4: Run, expect PASS**

Run: `nim lintTests config.nims`
Expected: all tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add yaml/lint.nim test/tlint.nim
git commit -m "Add lint config loading and lookup"
```

---

### Task 7: `yamllint` CLI

**Files:**
- Create: `tools/yamllint.nim`
- Create: `test/tyamllint.nim`
- Modify: `config.nims`, `.gitignore`

- [ ] **Step 1: Add tasks to `config.nims`** after `lintTests`:

```nim
task yamllintTests, "Run yamllint CLI tests":
  --r
  --verbosity:0
  setCommand "c", "test/tyamllint"

task yamllint, "Compile the yamllint tool":
  --d:release
  setCommand "c", "tools/yamllint"
```

and add `tools/yamllint`, `tools/yamllsp`, `test/tlint`, `test/tlsp`, `test/tyamllint` to `.gitignore`.

- [ ] **Step 2: Write the failing test** `test/tyamllint.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, osproc, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]

let
  root = currentSourcePath.parentDir.parentDir
  tmp = getTempDir() / ("yamllint-test-" & $getCurrentProcessId())
  bin = tmp / "yamllint"
  dir = tmp / "files"

createDir(dir)
let (compileOutput, compileCode) = execCmdEx("nim c --hints:off -o:" &
    quoteShell(bin) & " " & quoteShell(root / "tools" / "yamllint.nim"))
doAssert compileCode == 0, compileOutput

writeFile(dir / "ok.yaml", "a: 1\n")
writeFile(dir / "warn.yaml", "a: 1 \n")
writeFile(dir / "bad.yaml", "a: 1\na: 2\n")

proc yamllint(args: varargs[string]): tuple[output: string, exitCode: int] =
  var cmd = quoteShell(bin)
  for arg in args: cmd.add(" " & quoteShell(arg))
  execCmdEx(cmd)

suite "yamllint":
  test "clean file":
    check yamllint(dir / "ok.yaml") == ("", 0)

  test "warnings only: exit code 0":
    check yamllint(dir / "warn.yaml") == (dir / "warn.yaml" &
        ":1:5: warning: trailing whitespace [trailing-spaces]\n", 0)

  test "errors: exit code 1, all files reported":
    check yamllint(dir / "bad.yaml", dir / "warn.yaml") == (dir / "bad.yaml" &
        ":2:1: error: duplicate mapping key \"a\" [duplicate-key]\n" &
        dir / "warn.yaml" &
        ":1:5: warning: trailing whitespace [trailing-spaces]\n", 1)

  test "usage and I/O errors: exit code 2":
    check yamllint().exitCode == 2
    check yamllint("--bogus", dir / "ok.yaml").exitCode == 2
    check yamllint(dir / "missing.yaml").exitCode == 2

  test "--config":
    writeFile(tmp / "strict.yaml", "rules:\n  trailing-spaces: {level: error}\n")
    check yamllint("--config:" & tmp / "strict.yaml", dir / "warn.yaml") ==
        (dir / "warn.yaml" &
        ":1:5: error: trailing whitespace [trailing-spaces]\n", 1)

  test "invalid config: exit code 2":
    writeFile(tmp / "invalid.yaml", "rules:\n  nope: {}\n")
    let r = yamllint("--config:" & tmp / "invalid.yaml", dir / "ok.yaml")
    check r.exitCode == 2
    check "unknown rule: nope" in r.output

  test "config found by walking up from the file":
    writeFile(tmp / ".nimyaml-lint.yaml", "rules:\n  duplicate-key: {level: off}\n")
    defer: removeFile(tmp / ".nimyaml-lint.yaml")
    check yamllint(dir / "bad.yaml") == ("", 0)

removeDir(tmp)
```

- [ ] **Step 3: Run, expect failure**

Run: `nim yamllintTests config.nims`
Expected: FAIL at the `doAssert compileCode == 0` — `cannot open file: .../tools/yamllint.nim`.

- [ ] **Step 4: Implement** `tools/yamllint.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamllint: lints YAML files with NimYAML's lint engine.
##
## Usage: ``yamllint [--config:FILE] FILE...``
##
## Without ``--config``, each file is linted with the ``.nimyaml-lint.yaml``
## found by walking up from its directory, or the defaults. Prints one line
## per diagnostic. Exit code: 0 without error diagnostics, 1 with, 2 for
## usage, I/O or config errors.

import std/[os, parseopt]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/lint

const usage = "usage: yamllint [--config:FILE] FILE..."

proc configFor(file: string): LintConfig =
  let path = findLintConfig(parentDir(absolutePath(file)))
  if path.len == 0: defaultConfig() else: loadLintConfig(path)

proc run*(args: seq[string]): int =
  var
    configPath = ""
    files: seq[string]
    p = initOptParser(args)
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      if key == "config" and val.len > 0: configPath = val
      else:
        stderr.writeLine(usage)
        return 2
    of cmdEnd: discard
  if files.len == 0:
    stderr.writeLine(usage)
    return 2
  try:
    let explicit =
      if configPath.len > 0: some(loadLintConfig(configPath))
      else: none(LintConfig)
    for file in files:
      let config = if explicit.isSome: explicit.get() else: configFor(file)
      for d in lint(readFile(file), config):
        stdout.writeLine(file & ":" & $d)
        if d.severity == severityError: result = 1
  except LintConfigError as e:
    stderr.writeLine("config error: " & e.msg)
    return 2
  except IOError as e:
    stderr.writeLine(e.msg)
    return 2

when isMainModule:
  quit(run(commandLineParams()))
```

- [ ] **Step 5: Run, expect PASS**

Run: `nim yamllintTests config.nims`
Expected: all `yamllint` tests `[OK]`.

- [ ] **Step 6: Commit**

```bash
git add tools/yamllint.nim test/tyamllint.nim config.nims .gitignore
git commit -m "Add yamllint command line tool"
```

---

### Task 8: `yamllsp` language server

**Files:**
- Create: `tools/yamllsp.nim`
- Create: `test/tlsp.nim`
- Modify: `config.nims`

- [ ] **Step 1: Add tasks to `config.nims`** after `yamllint`:

```nim
task lspTests, "Run language server tests":
  --r
  --verbosity:0
  setCommand "c", "test/tlsp"

task yamllsp, "Compile the yamllsp language server":
  --d:release
  setCommand "c", "tools/yamllsp"
```

- [ ] **Step 2: Write the failing test** `test/tlsp.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[json, os, streams, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../tools/yamllsp

proc request(id: int, meth: string, params = newJObject()): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params}

proc notification(meth: string, params = newJObject()): JsonNode =
  %*{"jsonrpc": "2.0", "method": meth, "params": params}

proc didOpen(uri, text: string): JsonNode =
  notification("textDocument/didOpen", %*{"textDocument": {"uri": uri,
      "languageId": "yaml", "version": 1, "text": text}})

proc diagnosticsOf(replies: seq[JsonNode], uri: string): JsonNode =
  for r in replies:
    if r{"method"}.getStr() == "textDocument/publishDiagnostics" and
        r["params"]["uri"].getStr() == uri:
      return r["params"]["diagnostics"]
  nil

suite "LSP framing":
  test "frame and read back":
    let a = %*{"jsonrpc": "2.0", "id": 1, "method": "x"}
    let b = %*{"text": "é"}
    let s = newStringStream(frame(a) & frame(b))
    check readMessage(s) == a
    check readMessage(s) == b
    check readMessage(s).isNil

  test "header names are case-insensitive, other headers ignored":
    let s = newStringStream(
        "content-length: 2\r\nContent-Type: application/json\r\n\r\n{}")
    check readMessage(s) == newJObject()

  test "missing Content-Length":
    expect ValueError:
      discard readMessage(newStringStream("X: 1\r\n\r\n{}"))

suite "LSP positions":
  test "UTF-16 columns":
    check utf16Column("abc", 1) == 0
    check utf16Column("abc", 4) == 3
    check utf16Column("é", 3) == 1
    check utf16Column("😀x", 5) == 2
    check utf16Column("😀x", 6) == 3
    check utf16Column("ab", 5) == 4

suite "LSP server":
  test "initialize":
    var s: Server
    let replies = s.handle(request(1, "initialize"))
    check replies.len == 1
    check replies[0]["id"].getInt() == 1
    check replies[0]["result"]["capabilities"]["textDocumentSync"]["change"].getInt() == 1

  test "didOpen publishes diagnostics":
    var s: Server
    let diags = s.handle(didOpen("untitled:a", "a: 1\na: 2\n")).diagnosticsOf("untitled:a")
    check diags.len == 1
    check diags[0]["range"] == %*{"start": {"line": 1, "character": 0},
        "end": {"line": 1, "character": 1}}
    check diags[0]["severity"].getInt() == 1
    check diags[0]["code"].getStr() == "duplicate-key"
    check diags[0]["source"].getStr() == "nimyaml"

  test "positions are UTF-16":
    var s: Server
    let diags = s.handle(didOpen("untitled:a", "é: yes\n")).diagnosticsOf("untitled:a")
    check diags.len == 1
    check diags[0]["range"] == %*{"start": {"line": 0, "character": 3},
        "end": {"line": 0, "character": 6}}
    check diags[0]["severity"].getInt() == 2

  test "didChange replaces the text, didClose clears":
    var s: Server
    discard s.handle(didOpen("untitled:a", "a: 1\na: 2\n"))
    let changed = s.handle(notification("textDocument/didChange", %*{
        "textDocument": {"uri": "untitled:a", "version": 2},
        "contentChanges": [{"text": "a: 1\n"}]}))
    check changed.diagnosticsOf("untitled:a").len == 0
    discard s.handle(didOpen("untitled:b", "a: 1\na: 2\n"))
    let closed = s.handle(notification("textDocument/didClose",
        %*{"textDocument": {"uri": "untitled:b"}}))
    check closed.diagnosticsOf("untitled:b").len == 0

  test "config from the file system, reloaded on save":
    let dir = getTempDir() / ("yamllsp-test-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let config = dir / ".nimyaml-lint.yaml"
    writeFile(config, "rules:\n  truthy: {level: error}\n")
    let uri = "file://" & dir / "x.yaml"
    var s: Server
    let opened = s.handle(didOpen(uri, "k: yes\n")).diagnosticsOf(uri)
    check opened.len == 1
    check opened[0]["severity"].getInt() == 1
    writeFile(config, "rules:\n  truthy: {level: off}\n")
    let saved = s.handle(notification("textDocument/didSave",
        %*{"textDocument": {"uri": "file://" & config}}))
    check saved.diagnosticsOf(uri).len == 0
    writeFile(config, "rules:\n  nope: {}\n")
    let invalid = s.handle(notification("textDocument/didSave",
        %*{"textDocument": {"uri": "file://" & config}})).diagnosticsOf(uri)
    check invalid.len == 2
    check invalid[0]["code"].getStr() == "config"
    check "unknown rule: nope" in invalid[0]["message"].getStr()

  test "unknown requests and notifications":
    var s: Server
    let replies = s.handle(request(7, "textDocument/hover"))
    check replies.len == 1
    check replies[0]["error"]["code"].getInt() == -32601
    check s.handle(notification("$/whatever")).len == 0

  test "shutdown, then exit":
    var s: Server
    let replies = s.handle(request(2, "shutdown"))
    check replies[0]["result"].kind == JNull
    discard s.handle(notification("exit"))
    check s.exited
    check s.exitCode == 0

  test "exit without shutdown":
    var s: Server
    discard s.handle(notification("exit"))
    check s.exited
    check s.exitCode == 1
```

Note the expected `invalid.len == 2` in the config test: the config error diagnostic plus `truthy` at its default level (warning), since the defaults apply when the config is invalid.

- [ ] **Step 3: Run, expect a compile failure**

Run: `nim lspTests config.nims`
Expected: FAIL, `cannot open file: ../tools/yamllsp`

- [ ] **Step 4: Implement** `tools/yamllsp.nim`:

```nim
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamllsp: a language server that publishes NimYAML lint diagnostics.
##
## Speaks JSON-RPC 2.0 over stdin/stdout with full document sync. When a
## document is opened, changed or saved, it is linted with the
## ``.nimyaml-lint.yaml`` found by walking up from the document's directory
## (defaults for documents without a ``file://`` URI) and the diagnostics
## are published. Saving a ``.nimyaml-lint.yaml`` reloads the configs and
## republishes the diagnostics of all open documents.

import std/[json, os, streams, strutils, tables, uri]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/lint

type
  ConfigEntry = tuple[config: LintConfig, error: string]

  Server* = object
    docs: Table[string, string]        # uri -> text
    configs: Table[string, ConfigEntry] # directory -> config
    shutdownRequested: bool
    exited*: bool
    exitCode*: int

const
  methodNotFound = -32601
  internalError = -32603

proc readMessage*(s: Stream): JsonNode =
  ## Reads one ``Content-Length`` framed message. Returns nil at the end of
  ## the input. Raises ``ValueError`` if the header has no
  ## ``Content-Length`` and ``JsonParsingError`` for an invalid body.
  var
    length = -1
    line: string
  while true:
    if not s.readLine(line): return nil
    line.stripLineEnd()
    if line.len == 0: break
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip().toLowerAscii() == "content-length":
      length = parseInt(line[colon + 1 .. ^1].strip())
  if length < 0: raise newException(ValueError, "missing Content-Length")
  let body = s.readStr(length)
  if body.len < length: return nil
  parseJson(body)

proc frame*(msg: JsonNode): string =
  ## ``msg`` with a ``Content-Length`` header.
  let body = $msg
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc utf16Column*(line: string, byteColumn: Positive): int =
  ## The 0-based UTF-16 offset of the 1-based byte column ``byteColumn`` of
  ## ``line``. Columns beyond the end of the line count one unit per byte.
  let stop = byteColumn - 1
  var i = 0
  while i < stop and i < line.len:
    let c = ord(line[i])
    if c >= 0xF0:
      result += 2
      i += 4
    elif c >= 0xE0:
      inc(result)
      i += 3
    elif c >= 0xC0:
      inc(result)
      i += 2
    else:
      inc(result)
      inc(i)
  if stop > i: result += stop - i

proc lspPosition(lines: seq[string], m: Mark): JsonNode =
  let text = if m.line <= lines.len: lines[m.line - 1] else: ""
  %*{"line": m.line - 1, "character": utf16Column(text, m.column)}

proc toLsp*(d: Diagnostic, lines: seq[string]): JsonNode =
  ## ``d`` as an LSP diagnostic; ``lines`` are the lines of the document.
  let severity =
    case d.severity
    of severityError: 1
    of severityWarning: 2
    of severityInfo: 3
  %*{"range": {"start": lspPosition(lines, d.startPos),
               "end": lspPosition(lines, d.endPos)},
     "severity": severity, "source": "nimyaml", "code": d.rule,
     "message": d.message}

proc documentPath(uri: string): string =
  const scheme = "file://"
  if uri.startsWith(scheme): decodeUrl(uri[scheme.len .. ^1], decodePlus = false)
  else: ""

proc configFor(s: var Server, uri: string): ConfigEntry =
  let path = documentPath(uri)
  if path.len == 0: return (defaultConfig(), "")
  let dir = path.parentDir()
  if dir notin s.configs:
    var entry: ConfigEntry = (defaultConfig(), "")
    let configPath = findLintConfig(dir)
    if configPath.len > 0:
      try:
        entry.config = loadLintConfig(configPath)
      except LintConfigError as e:
        entry.error = e.msg
    s.configs[dir] = entry
  s.configs[dir]

proc publish(s: var Server, uri: string): JsonNode =
  var diagnostics = newJArray()
  if uri in s.docs:
    let text = s.docs[uri]
    let (config, error) = s.configFor(uri)
    if error.len > 0:
      diagnostics.add(%*{"range": {"start": {"line": 0, "character": 0},
                                   "end": {"line": 0, "character": 1}},
                         "severity": 1, "source": "nimyaml", "code": "config",
                         "message": "invalid lint config: " & error})
    var lines: seq[string]
    for _, line in text.sourceLines: lines.add(line)
    for d in lint(text, config): diagnostics.add(d.toLsp(lines))
  %*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
     "params": {"uri": uri, "diagnostics": diagnostics}}

proc respond(id, value: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "result": value}

proc respondError(id: JsonNode, code: int, message: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id,
     "error": {"code": code, "message": message}}

proc handle*(s: var Server, msg: JsonNode): seq[JsonNode] =
  ## Handles one message and returns the messages to send. Raises on
  ## malformed messages.
  let
    meth = msg{"method"}.getStr()
    id = msg{"id"}
    params = msg{"params"}
  case meth
  of "initialize":
    result.add(respond(id, %*{
      "capabilities": {"textDocumentSync": {"openClose": true, "change": 1,
                                            "save": {"includeText": false}}},
      "serverInfo": {"name": "yamllsp"}}))
  of "textDocument/didOpen":
    let doc = params["textDocument"]
    let uri = doc["uri"].getStr()
    s.docs[uri] = doc["text"].getStr()
    result.add(s.publish(uri))
  of "textDocument/didChange":
    let uri = params["textDocument"]["uri"].getStr()
    let changes = params["contentChanges"]
    if changes.len > 0: s.docs[uri] = changes[changes.len - 1]["text"].getStr()
    result.add(s.publish(uri))
  of "textDocument/didSave":
    let uri = params["textDocument"]["uri"].getStr()
    if documentPath(uri).extractFilename() == configFileName:
      s.configs.clear()
      var uris: seq[string]
      for open in s.docs.keys: uris.add(open)
      for open in uris: result.add(s.publish(open))
    elif uri in s.docs:
      result.add(s.publish(uri))
  of "textDocument/didClose":
    let uri = params["textDocument"]["uri"].getStr()
    s.docs.del(uri)
    result.add(s.publish(uri))
  of "shutdown":
    s.shutdownRequested = true
    result.add(respond(id, newJNull()))
  of "exit":
    s.exited = true
    s.exitCode = if s.shutdownRequested: 0 else: 1
  else:
    if not id.isNil:
      result.add(respondError(id, methodNotFound, "method not found: " & meth))

proc serve*(input: Stream, output: File): int =
  ## Serves messages from ``input`` until ``exit`` or the end of the input.
  ## Returns the exit code.
  var server: Server
  while not server.exited:
    var msg: JsonNode
    try:
      msg = readMessage(input)
    except CatchableError as e:
      stderr.writeLine("yamllsp: " & e.msg)
      continue
    if msg.isNil: return 1
    var replies: seq[JsonNode]
    try:
      replies = server.handle(msg)
    except CatchableError as e:
      if msg{"id"}.isNil: stderr.writeLine("yamllsp: " & e.msg)
      else: replies = @[respondError(msg{"id"}, internalError, e.msg)]
    for reply in replies: output.write(frame(reply))
    output.flushFile()
  server.exitCode

when isMainModule:
  quit(serve(newFileStream(stdin), stdout))
```

- [ ] **Step 5: Run, expect PASS**

Run: `nim lspTests config.nims`
Expected: all tests `[OK]`.

- [ ] **Step 6: Smoke test the binary**

```bash
nim yamllsp config.nims
body1='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
body2='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"untitled:a","languageId":"yaml","version":1,"text":"a: 1\na: 2\n"}}}'
body3='{"jsonrpc":"2.0","id":2,"method":"shutdown"}'
body4='{"jsonrpc":"2.0","method":"exit"}'
for b in "$body1" "$body2" "$body3" "$body4"; do printf 'Content-Length: %d\r\n\r\n%s' "${#b}" "$b"; done | tools/yamllsp; echo " exit=$?"
```

Expected: three framed replies (initialize result, publishDiagnostics with one `duplicate-key` diagnostic, shutdown result) and `exit=0`. (`${#b}` counts bytes here because the bodies are ASCII.)

- [ ] **Step 7: Commit**

```bash
git add tools/yamllsp.nim test/tlsp.nim config.nims
git commit -m "Add yamllsp language server"
```

---

### Task 9: wire up, docs

**Files:**
- Modify: `test/tests.nim:8`
- Modify: `README.md`, `CHANGELOG.md`, `yaml/parser.nim:53-54`

- [ ] **Step 1: Add the tests to the full run.** In `test/tests.nim` change the import line to:

```nim
import tlex, tjson, tnative, tparser, tfeed, tcheckpoint, tdocuments, tinternal, tquickstart, tannotations, thints, tpresenter, tlint, tlsp, tyamllint
```

- [ ] **Step 2: Fix the stale parser doc comment.** In `yaml/parser.nim`, remove the two lines

```nim
    ## - An alias is used which does not map to any anchor that has
    ##   previously been declared in the same document.
```

from the `YamlParserError` doc comment (the parser does not check this; the `undefined-alias` lint rule does, and construction reports it when loading).

- [ ] **Step 3: Document.** Add a `## Linting` section to `README.md` after the `parseRecovering` section:

````markdown
### Linting

`yaml/lint` lints YAML sources: `lint(source, config)` returns diagnostics
(rule id, severity, range, message) sorted by position. It parses once with
`parseRecovering` and runs these rules:

| rule | default | reports |
|---|---|---|
| `syntax` | error | invalid documents |
| `duplicate-key` | error | a scalar key repeated in one mapping |
| `complex-key` | warning | a sequence or mapping used as a key |
| `undefined-alias` | error | an alias without an earlier anchor in its document |
| `unused-anchor` | warning | an anchor no alias refers to |
| `truthy` | warning | plain `yes`/`no`/`on`/`off`/`y`/`n` (booleans in YAML 1.1) |
| `trailing-spaces` | warning | whitespace at the end of a line |
| `line-length` | warning | lines longer than `max` (120) characters |
| `tabs` | error | tabs in indentation |
| `final-newline` | warning | no line break at the end of the file |

Rules are configured in `.nimyaml-lint.yaml`, found by walking up from the
linted file's directory:

```yaml
rules:
  line-length: {level: warning, max: 100}
  truthy: {level: off}
```

Two tools use it: `nim yamllint config.nims` builds `tools/yamllint`
(`yamllint [--config:FILE] FILE...`, exit code 1 if there are errors) and
`nim yamllsp config.nims` builds `tools/yamllsp`, a language server (stdio,
full sync) that publishes the diagnostics of open documents.
````

and to `CHANGELOG.md` under `Unreleased` / `Features:`:

```markdown
 * added `yaml/diagnostics` and `yaml/lint`: a lint engine with syntax,
   mapping key, anchor and text rules, configured by `.nimyaml-lint.yaml`,
   plus the `tools/yamllint` command line tool and the `tools/yamllsp`
   language server.
```

- [ ] **Step 4: Run everything**

Run: `nim test config.nims`
Expected: exit 0, no `[FAILED]`.

- [ ] **Step 5: Commit**

```bash
git add test/tests.nim yaml/parser.nim README.md CHANGELOG.md
git commit -m "Run lint tests with the full suite; document linting"
```
