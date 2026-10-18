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
