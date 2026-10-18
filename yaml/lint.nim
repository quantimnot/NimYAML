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
