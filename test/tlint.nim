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
        "line-length", "tabs", "final-newline",
        # directive rules, reported from the parser's directive issues
        "unknown-directive", "invalid-schema-directive",
        "duplicate-schema-directive", "unresolvable-schema-uri",
        "misplaced-global-directive", "missing-global-directive",
        "nested-global-directive", "duplicate-global-directive",
        "unknown-global-directive", "schema-source"]

suite "Lint config":
  test "blank and comment-only configs are the defaults":
    check parseLintConfig("").rules.len == 0
    check parseLintConfig("# nothing\n\n").rules.len == 0

  test "levels and options":
    let config = parseLintConfig(
        "rules:\n  line-length: {level: error, max: 5}\n  truthy: {level: off}\n")
    check config.rules["line-length"].level == some(levelError)
    check config.rules["line-length"].max == some(5)
    check spans("- abcd\n- yes\n", config) ==
        @["line-length 1:6-1:7 error"]

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

suite "Lint: directive rules":
  # Each directive issue the parser records is a rule of its own, with the
  # issue kind's id; the fixtures cover every error and warning of the
  # %GLOBAL and %SCHEMA directives.
  proc directiveSpans(source: string, sourceUri = "",
      config = defaultConfig()): seq[string] =
    for d in lint(source, config, sourceUri):
      if d.rule notin ["final-newline", "unused-anchor"]: result.add(d.span)

  test "reserved directives are warnings":
    check directiveSpans("%FOO bar\n--- a\n") ==
        @["unknown-directive 1:1-1:9 warning"]

  test "%SCHEMA errors":
    check directiveSpans("%SCHEMA\n--- a\n") ==
        @["invalid-schema-directive 1:1-1:8 error"]
    check directiveSpans("%SCHEMA a b\n--- a\n", "file:///x.yaml").len == 0
    check directiveSpans("%SCHEMA a http://[x\n--- a\n", "file:///x.yaml") ==
        @["invalid-schema-directive 1:11-1:20 error"]
    check directiveSpans(
        "%SCHEMA https://x.example/1\n%SCHEMA https://x.example/2\n--- a\n") ==
        @["duplicate-schema-directive 2:1-2:28 error"]
    check directiveSpans("%SCHEMA s.json\n--- a\n") ==
        @["unresolvable-schema-uri 1:9-1:15 error"]
    check directiveSpans("%SCHEMA s.json\n--- a\n", "file:///w/x.yaml").len == 0

  test "%GLOBAL errors and warnings":
    check directiveSpans("--- a\n...\n%GLOBAL YAML 1.2\n--- b\n") ==
        @["misplaced-global-directive 3:1-3:17 error"]
    check directiveSpans("%GLOBAL\n--- a\n") ==
        @["missing-global-directive 1:1-1:8 error"]
    check directiveSpans("%GLOBAL GLOBAL YAML 1.2\n--- a\n") ==
        @["nested-global-directive 1:1-1:24 error"]
    check directiveSpans("%GLOBAL TAG !e! a:\n%GLOBAL TAG !e! b:\n--- a\n") ==
        @["duplicate-global-directive 2:1-2:19 error"]
    check directiveSpans("%GLOBAL FOO x\n--- a\n") ==
        @["unknown-global-directive 1:1-1:14 warning"]

  test "schema-source names the winner":
    check directiveSpans("%SCHEMA https://x.example/s\n---\n" &
        "$schema: https://x.example/k\n") ==
        @["schema-source 1:9-1:28 info"]

  test "levels are configurable like any rule":
    var config = defaultConfig()
    config.rules["unknown-directive"] = RuleConfig(level: some(levelError))
    config.rules["schema-source"] = RuleConfig(level: some(levelOff))
    check directiveSpans("%FOO\n%SCHEMA https://x.example/s\n---\n" &
        "$schema: https://x.example/k\n", config = config) ==
        @["unknown-directive 1:1-1:5 error"]
    check parseLintConfig(
        "rules:\n  nested-global-directive: {level: warning}\n")
        .rules["nested-global-directive"].level == some(levelWarning)

  test "valid uses produce nothing":
    check directiveSpans("""%GLOBAL TAG !e! tag:e:
%GLOBAL SCHEMA https://x.example/s
%GLOBAL YAML 1.2
--- !e!a 1
...
%TAG !e! tag:other:
%SCHEMA https://x.example/t
--- !e!b 2
""").len == 1 # the schema-source info of the second document
