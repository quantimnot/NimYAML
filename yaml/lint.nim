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
##
## Directive rules
## ---------------
##
## The parser records problems with directives that do not make the YAML
## invalid (see `DirectiveIssueKind`): reserved directives, and misuse of
## NimYAML's ``%SCHEMA`` and ``%GLOBAL``. Each kind is a rule of its own,
## under the same id, so that it can be configured like any other. The
## ``schema-source`` rule reports documents that name their schema in more
## than one way (see `documentschema <documentschema.html>`_). Like
## ``syntax``, these rules have no hooks of their own: `lint` hands them
## what the parser and the schema collector found.

import std/[algorithm, options, os, sets, strutils, tables]
from std/unicode import runeLen, runeOffset
when defined(nimPreviewSlimSystem):
  import std/syncio
import data, parser, stream, loading, annotations, diagnostics, documentschema,
    source
import std/streams
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
      ## the linted input; empty when it was read from a `YamlSource`
    finalLineBreak*: bool
      ## whether the input is empty or ends with a line break; known when
      ## ``onEnd`` is called
    lastLine*: tuple[number, length: int]
      ## the number and length of the last line of the input; known when
      ## ``onEnd`` is called
    sourceUri*: string ## where ``source`` was retrieved from; may be empty
    diagnostics*: seq[Diagnostic]
    documentStart*: YamlDocumentStart
      ## the start of the document of the most recent ``yamlStartDoc``

  LintRule* = ref object of RootObj
    ## Base of all rules. `lint` creates fresh instances for each call, so
    ## rules may keep state in their fields.
    id*: string
    level*: RuleLevel   ## default level; `lint` applies the configured one
    config*: RuleConfig

  SyntaxRule = ref object of LintRule
  ReportedRule = ref object of LintRule
    ## A rule whose diagnostics come from the parser (directive issues) or
    ## the schema collector, not from hooks.

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
  if not ctx.finalLineBreak:
    let (line, length) = ctx.lastLine
    ctx.report(r, mark(line, length + 1), mark(line, length + 2),
        "no line break at end of file")

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

# registry

proc builtinRules*(): seq[LintRule] =
  ## Fresh instances of all built-in rules, with their default levels.
  result = @[LintRule(SyntaxRule(id: "syntax", level: levelError)),
    DuplicateKeyRule(id: "duplicate-key", level: levelError),
    ComplexKeyRule(id: "complex-key", level: levelWarning),
    UndefinedAliasRule(id: "undefined-alias", level: levelError),
    UnusedAnchorRule(id: "unused-anchor", level: levelWarning),
    TruthyRule(id: "truthy", level: levelWarning),
    TrailingSpacesRule(id: "trailing-spaces", level: levelWarning),
    LineLengthRule(id: "line-length", level: levelWarning),
    TabsRule(id: "tabs", level: levelError),
    FinalNewlineRule(id: "final-newline", level: levelWarning)]
  for kind in DirectiveIssueKind:
    let level = if kind in {diUnknownDirective, diUnknownGlobal}: levelWarning
                else: levelError
    result.add(ReportedRule(id: $kind, level: level))
  result.add(ReportedRule(id: "schema-source", level: levelInfo))

proc builtinRuleIds*(): seq[string] =
  for r in builtinRules(): result.add(r.id)

proc defaultConfig*(): LintConfig = LintConfig()

proc resolved*(config: LintConfig): LintConfig =
  ## ``config`` with every builtin rule listed and its level, and the ``max``
  ## of ``line-length``, set to the configured or default value.
  for r in builtinRules():
    var rule = config.rules.getOrDefault(r.id)
    if rule.level.isNone: rule.level = some(r.level)
    if r.id == "line-length" and rule.max.isNone:
      rule.max = some(defaultMaxLineLength)
    result.rules[r.id] = rule

proc isBlank(content: string): bool =
  for line in content.splitLines:
    let text = line.strip()
    if text.len > 0 and text[0] != '#': return false
  true

proc checkLintConfig*(config: LintConfig) =
  ## Raises `LintConfigError` if ``config`` names an unknown rule or has a
  ## negative ``max``.
  let ids = builtinRuleIds()
  for id, rule in config.rules:
    if id notin ids:
      raise newException(LintConfigError, "unknown rule: " & id)
    if rule.max.isSome and rule.max.get() < 0:
      raise newException(LintConfigError,
          id & ": max must not be negative")

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
  checkLintConfig(result)

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

proc cmpDiagnostics(a, b: Diagnostic): int =
  result = cmp(a.startPos.line, b.startPos.line)
  if result == 0: result = cmp(a.startPos.column, b.startPos.column)
  if result == 0: result = cmp(a.rule, b.rule)

proc lintWith(context: LintContext, config: LintConfig,
    events: YamlRecoveringStream, lines: Stream): seq[Diagnostic] =
  ## Lints the input whose events are ``events`` and whose text ``lines``
  ## reads, both at once (see `readSchemas`).
  var
    ctx = context
    rules: seq[LintRule]
    syntax: LintRule = nil
    reported = initTable[string, LintRule]()
  for r in builtinRules():
    r.config = config.rules.getOrDefault(r.id)
    if r.config.level.isSome: r.level = r.config.level.get()
    if r.level == levelOff: continue
    if r of SyntaxRule: syntax = r
    elif r of ReportedRule: reported[r.id] = r
    else: rules.add(r)
  template report(d: Diagnostic) =
    if d.rule in reported:
      var found = d
      found.severity = reported[d.rule].level.severity
      ctx.diagnostics.add(found)
  # the range of a syntax error ends with its line, which is read after the
  # error is found
  var
    lineLengths = initTable[int, int]()
    errorsSeen = 0
  proc onEvent(e: Event) =
    if e.kind == yamlStartDoc:
      ctx.documentStart = events.documentStart
      if not e.directives.isNil:
        for i in e.directives.issues:
          report(Diagnostic(rule: $i.kind, startPos: i.startPos,
              endPos: i.endPos, message: i.message))
    for r in rules: r.onEvent(ctx, e)
  proc onLine(n: int, text: string) =
    for i in errorsSeen ..< events.errors.len:
      lineLengths[events.errors[i].error.mark.line] = 0
    errorsSeen = events.errors.len
    if n in lineLengths: lineLengths[n] = text.len
    for r in rules: r.onLine(ctx, n, text)
  proc onDocument(doc: DocumentSchema) =
    for d in diagnostics(@[doc]): report(d)
  let ending = readSchemas(events, lines, ctx.sourceUri, onEvent, onLine,
      onDocument)
  ctx.finalLineBreak = ending.finalLineBreak
  ctx.lastLine = ending.lastLine
  if not syntax.isNil:
    for err in events.errors:
      var d = err.syntaxDiagnostic(lineLengths.getOrDefault(err.error.mark.line))
      d.severity = syntax.level.severity
      ctx.diagnostics.add(d)
  for r in rules: r.onEnd(ctx)
  result = move(ctx.diagnostics)
  result.sort(cmpDiagnostics)

proc lint*(source: string, config = defaultConfig(), sourceUri = ""):
    seq[Diagnostic] =
  ## Lints ``source`` with the rules enabled by ``config``. ``sourceUri`` is
  ## the URI ``source`` was retrieved from; relative schema references
  ## resolve against it. Returns the diagnostics sorted by start position,
  ## then rule id.
  let events = initYamlParser(sourceUri = sourceUri).parseRecovering(source)
  lintWith(LintContext(source: source, sourceUri: sourceUri), config, events,
      newStringStream(source))

proc lint*(src: YamlSource, config = defaultConfig(), sourceUri = ""):
    seq[Diagnostic] =
  ## Like the `string` variant, for input of any size: ``src`` is read as a
  ## stream, twice (for its events and for its lines), so it must have
  ## random access; a stream is read into memory. Its budget is charged for
  ## the parser's buffer.
  if not src.randomAccess:
    return lint(src.readAll("linting " & src.name), config, sourceUri)
  let events = initYamlParser(sourceUri = sourceUri, budget = src.budget).
      parseRecovering(newSourceStream(src))
  lintWith(LintContext(sourceUri: sourceUri), config, events,
      newSourceStream(src))
