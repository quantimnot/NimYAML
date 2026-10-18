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
