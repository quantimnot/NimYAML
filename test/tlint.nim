#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, strutils, unittest, algorithm, options, tables]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml/[data, parser, stream, diagnostics, lint]

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
        @["syntax 3:8-3:11 error"]

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
