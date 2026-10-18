#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, streams, strutils, unittest, algorithm
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import std/importutils
import ../yaml/[data, stream]
import ../yaml/parser {.all.}
import ../yaml/private/lex

type Outcome = object
  events: seq[Event]
  failed: bool
  # position, message and line content of the error, if any
  error: string

proc describe(e: ref Exception): string =
  if e of YamlParserError:
    let pe = (ref YamlParserError)(e)
    result = $pe.mark.line & ":" & $pe.mark.column & " " & pe.msg & " | " &
        pe.lineContent
  else:
    result = "(" & $e.name & ") " & e.msg

proc collect(s: YamlStream): Outcome =
  try:
    while true:
      let e = s.next()
      result.events.add(e)
      if e.kind == yamlEndStream: break
  except YamlStreamError as e:
    result.failed = true
    result.error = describe(if e.parent.isNil: (ref Exception)(e) else: e.parent)

proc feedChunked(input: string, chunkSize: int): Outcome =
  ## feeds ``input`` in chunks of ``chunkSize``, draining all available
  ## events after each chunk.
  let fp = newYamlFeedParser(initYamlParser())
  var pos = 0
  try:
    while true:
      for e in fp.events: result.events.add(e)
      if fp.finished: break
      if pos >= input.len:
        fp.finish()
      else:
        let last = min(pos + chunkSize, input.len) - 1
        fp.feed(input.toOpenArray(pos, last))
        pos = last + 1
  except YamlParserError as e:
    result.failed = true
    result.error = describe(e)

var stringReadData: proc(s: Stream, buffer: pointer, bufLen: int): int {.nimcall, gcsafe, raises: [IOError, OSError], tags: [ReadIOEffect].}

proc trickleRead(s: Stream, buffer: pointer, bufLen: int): int {.nimcall, gcsafe, raises: [IOError, OSError], tags: [ReadIOEffect].} =
  {.cast(gcsafe).}:
    result = stringReadData(s, buffer, min(bufLen, 1))

proc trickleStream(input: string): Stream =
  ## a stream that returns at most one byte per read.
  let s = newStringStream(input)
  stringReadData = s.readDataImpl
  s.readDataImpl = trickleRead
  s.readDataStrImpl = nil # force reads through readDataImpl
  result = s

var
  failAfter: int # bytes a failing stream delivers before raising
  delivered: int

proc failingRead(s: Stream, buffer: pointer, bufLen: int): int {.nimcall, gcsafe, raises: [IOError, OSError], tags: [ReadIOEffect].} =
  {.cast(gcsafe).}:
    if delivered >= failAfter: raise newException(IOError, "connection reset")
    result = stringReadData(s, buffer, min(bufLen, failAfter - delivered))
    delivered += result

proc failingStream(input: string, after: int): Stream =
  ## a stream that raises IOError after delivering ``after`` bytes.
  let s = newStringStream(input)
  stringReadData = s.readDataImpl
  s.readDataImpl = failingRead
  s.readDataStrImpl = nil # force reads through readDataImpl
  failAfter = after
  delivered = 0
  result = s

proc compare(name: string, expected, actual: Outcome) =
  if expected.failed != actual.failed or expected.error != actual.error or
      (not expected.failed and expected.events != actual.events):
    checkpoint(name & ": expected failed=" & $expected.failed & " " &
               $expected.events.len & " events " & expected.error.escape &
               ", got failed=" & $actual.failed & " " & $actual.events.len &
               " events " & actual.error.escape)
    fail()

proc compareAll(name, input: string, sizes: openArray[int]) =
  let expected = collect(initYamlParser().parse(input))
  for size in sizes:
    compare(name & " [chunk " & $size & "]", expected,
            feedChunked(input, size))
  compare(name & " [stream]", expected,
          collect(initYamlParser().parse(newStringStream(input))))

proc suiteInputs(): seq[string] =
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path:
      result.add(path)
  result.sort()

proc newFeedParser(gate: bool): YamlFeedParser =
  result = newYamlFeedParser(initYamlParser())
  privateAccess(YamlFeedParser)
  privateAccess(Context)
  result.ctx.lex.completionGate = gate

proc attempts(fp: YamlFeedParser): int =
  privateAccess(YamlFeedParser)
  fp.attempts

proc availability(input: string, chunkSize: int, gate: bool): seq[string] =
  ## after each chunk, the number of events produced so far, or the error.
  let fp = newFeedParser(gate)
  var count = 0
  var pos = 0
  try:
    while true:
      for e in fp.events: inc(count)
      result.add($count)
      if fp.finished: break
      if pos >= input.len: fp.finish()
      else:
        let last = min(pos + chunkSize, input.len) - 1
        fp.feed(input.toOpenArray(pos, last))
        pos = last + 1
  except YamlParserError as e:
    result.add(describe(e))

proc feedCounting(input: string, chunkSize: int): (Outcome, int) =
  ## like feedChunked, also returns the number of parse attempts.
  let fp = newFeedParser(true)
  var pos = 0
  try:
    while true:
      for e in fp.events: result[0].events.add(e)
      if fp.finished: break
      if pos >= input.len: fp.finish()
      else:
        let last = min(pos + chunkSize, input.len) - 1
        fp.feed(input.toOpenArray(pos, last))
        pos = last + 1
  except YamlParserError as e:
    result[0].failed = true
    result[0].error = describe(e)
  result[1] = fp.attempts

suite "Feed Parser":
  test "completion gate never delays events or errors":
    const edgeCases = [
      "a: \"x\\\"y\\\\\" z: \"\\x41\\u00e9\\U0001F600\\n\"\nb: c\n",
      "a: \"bad \\q escape\"\n",
      "a: \"bad \\xZZ hex\"\n",
      "a: \"line\n---\n\"\n",
      "a: \"line\n...\n\"\n",
      "a: \"multi\n  line\n\n  text\"\nb: c\n",
      "a: 'it''s' ''\nb: 'x\n  y'\n",
      "a: 'x\n--- y'\n",
      "url: http://example.com:80/x?y=z#frag\nb: c # comment\n",
      "a: plain\n  continued\n  # comment\nb: c\n",
      "a: plain\n# comment\n  more\n",
      "- a\n  b\n- c\n---\nnext\n...\n",
      "a: b\r\nc: d\r\n  e\r\n",
      "a:\tb\n\tc: d\n",
      "[a b\n c, d\n  e]\n{f: g\n h}\n",
      "a: |+\n  x\n\n\nb: >-\n  y\n   z\n\n  w\nc: |2\n    deep\n",
      "--- |\nzero indent\ncontent\n--- >\n folded\n...\n",
      "a: |\n  x\n # less indented comment\n",
      "a: |\n   x\n  y\n",
      "top\n  level\n  plain\n---\n"]
    var inputs: seq[(string, string)]
    for i, input in edgeCases: inputs.add(("edge #" & $i, input))
    for path in suiteInputs(): inputs.add((path, readFile(path)))
    for (path, input) in inputs:
      for chunkSize in [1, 2, 3, 5, 7]:
        let withGate = availability(input, chunkSize, true)
        let withoutGate = availability(input, chunkSize, false)
        if withGate != withoutGate:
          var i = 0
          while i < min(withGate.len, withoutGate.len) and
              withGate[i] == withoutGate[i]: inc(i)
          checkpoint(path & " [chunk " & $chunkSize & "]: after chunk #" & $i &
                     " with gate: " &
                     (if i < withGate.len: withGate[i] else: "<end>") &
                     ", without: " &
                     (if i < withoutGate.len: withoutGate[i] else: "<end>"))
          fail()

  test "large scalars fed byte by byte take few attempts":
    let words = repeat("lorem ipsum dolor sit amet ", 4000)
    var multiline = ""
    for i in 0 ..< 3000: multiline.add("  line number " & $i & "\n")
    let cases = {
      "double-quoted": "a: \"" & words & "\\n\\t\\x41\\u00e9 \\\"q\\\" " &
          repeat("x", 50000) & "\"\nb: c\n",
      "double-quoted multiline": "a: \"first\n" & multiline & "  \"\nb: c\n",
      "single-quoted": "a: '" & words & " it''s '' " & repeat("y", 50000) &
          "'\nb: c\n",
      "plain": "a: " & words & repeat("z", 50000) & "\nb: c\n",
      "plain multiline": "a: first\n" & multiline & "b: c\n",
      "plain top-level": "first\n" & multiline & "...\n",
      "literal": "a: |\n" & multiline & "b: c\n",
      "folded keep": "a: >+\n" & multiline & "\n\nb: c\n",
      "literal indicator": "a: |2\n" & multiline & "b: c\n",
      "top-level literal": "--- |\n" & multiline & "--- end\n"}
    for (name, input) in cases:
      let expected = collect(initYamlParser().parse(input))
      if expected.failed:
        checkpoint(name & ": invalid test input: " & expected.error)
        fail()
      let (outcome, attempts) = feedCounting(input, 1)
      compare(name, expected, outcome)
      # without the gate, there is about one attempt per byte
      if attempts > expected.events.len * 4 + 20:
        checkpoint(name & ": " & $attempts & " attempts for " & $input.len &
                   " bytes and " & $expected.events.len & " events")
        fail()

  test "yields nothing before input, resumes after":
    let fp = newYamlFeedParser(initYamlParser())
    var e: Event
    # even yamlStartStream needs input: the first character is read eagerly
    check not fp.tryNext(e)
    fp.feed("a: b")
    var kinds: seq[EventKind]
    for e in fp.events: kinds.add(e.kind)
    # `b` might continue on the next line, so the scalar is not final yet
    check kinds == @[yamlStartStream, yamlStartDoc, yamlStartMap, yamlScalar]
    fp.feed("c\n")
    check not fp.tryNext(e)
    fp.finish()
    kinds.setLen(0)
    for e in fp.events:
      kinds.add(e.kind)
    check kinds == @[yamlScalar, yamlEndMap, yamlEndDoc, yamlEndStream]
    check fp.finished
    check not fp.tryNext(e)

  test "error in complete input is raised":
    let fp = newYamlFeedParser(initYamlParser())
    fp.feed("[a, b}\n")
    expect YamlParserError:
      for e in fp.events: discard

  test "long input fed line by line":
    let fp = newYamlFeedParser(initYamlParser())
    var count = 0
    for i in 0 ..< 20000:
      fp.feed("- item " & $i & "\n")
      for e in fp.events:
        if e.kind == yamlScalar: inc(count)
    fp.finish()
    for e in fp.events:
      if e.kind == yamlScalar: inc(count)
    check count == 20000

  test "error is sticky":
    let fp = newYamlFeedParser(initYamlParser())
    fp.feed("[a, b}\n")
    var first, second: string
    try:
      for e in fp.events: discard
    except YamlParserError as e: first = describe(e)
    try:
      for e in fp.events: discard
    except YamlParserError as e: second = describe(e)
    check first.len > 0
    check first == second

  test "error in nested flow collection keeps position":
    compareAll("nested flow error", "a: [b, c}  # comment\n", [1, 3, 100])

  test "feed after finish raises":
    let fp = newYamlFeedParser(initYamlParser())
    fp.finish()
    expect ValueError:
      fp.feed("a")

  test "large inputs exceeding the compaction threshold":
    var flowSeq = "[\n"
    for i in 0 ..< 20000: flowSeq.add("  item" & $i & ",\n")
    flowSeq.add("]\n")
    compareAll("flow sequence", flowSeq, [4096, 65536, flowSeq.len])
    var flowMap = "outer:\n  inner: {\n"
    for i in 0 ..< 10000: flowMap.add("    key" & $i & ": value" & $i & ",\n")
    flowMap.add("  }\nafter: x\n")
    compareAll("flow map in block map", flowMap, [4096, flowMap.len])
    var invalid = "outer:\n  inner: {\n"
    for i in 0 ..< 10000: invalid.add("    key" & $i & ": value" & $i & ",\n")
    invalid.add("}\n")
    compareAll("invalid flow map in block map", invalid, [4096, invalid.len])
    var literal = "text: |\n"
    for i in 0 ..< 20000: literal.add("  line " & $i & "\n")
    literal.add("next: y\n")
    compareAll("block scalar", literal, [4096, literal.len])
    var docs = ""
    for i in 0 ..< 5000: docs.add("--- [" & $i & ", {a: " & $i & "}]\n")
    compareAll("many documents", docs, [100, 4096])

  test "stream errors are reported as such":
    let input = "a: \"quoted\n  string\"\nb: [c, d]\nlong: " &
        repeat('x', 20000) & "\n"
    for after in [0, 1, 4, 5, 10, 15, 22, 30, 9000]:
      let outcome = collect(initYamlParser().parse(failingStream(input, after)))
      check outcome.failed
      if "stream error" notin outcome.error:
        checkpoint("failing after " & $after & ": " & outcome.error)
        fail()

  test "yaml-test-suite: feed and stream input match string input":
    let inputs = suiteInputs()
    check inputs.len > 300
    for path in inputs:
      let input = readFile(path)
      let expected = collect(initYamlParser().parse(input))
      for size in [1, 2, 7, 64, max(input.len, 1)]:
        compare(path & " [chunk " & $size & "]", expected,
              feedChunked(input, size))
      compare(path & " [trickle stream]", expected,
            collect(initYamlParser().parse(trickleStream(input))))
