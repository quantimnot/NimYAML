#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, streams, strutils, unittest, algorithm
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml, ../yaml/[data, parser, stream]

proc describe(e: Event): string =
  ## unlike `==`, this includes positions and styles.
  result = $e & " @" & $e.startPos.line & ":" & $e.startPos.column & "-" &
      $e.endPos.line & ":" & $e.endPos.column
  case e.kind
  of yamlScalar: result.add(" " & $e.scalarStyle)
  of yamlStartMap: result.add(" " & $e.mapStyle)
  of yamlStartSeq: result.add(" " & $e.seqStyle)
  else: discard

proc describe(e: ref Exception): string =
  if e of YamlParserError:
    let pe = (ref YamlParserError)(e)
    result = "error " & $pe.mark.line & ":" & $pe.mark.column & " " & pe.msg &
        " | " & pe.lineContent
  else:
    result = "error (" & $e.name & ") " & e.msg

proc drain(s: YamlStream, into: var seq[string]) =
  ## appends the descriptions of all remaining events, and of the error
  ## that ends the stream, if any.
  try:
    while true:
      let e = s.next()
      into.add(describe(e))
      if e.kind == yamlEndStream: break
  except YamlStreamError as e:
    into.add(describe(if e.parent.isNil: (ref Exception)(e) else: e.parent))

proc drain(fp: YamlFeedParser, input: string, pos: var int, chunkSize: int,
           into: var seq[string], maxEvents = int.high) =
  ## feeds ``input[pos..]`` in chunks, collecting at most ``maxEvents``
  ## events (and the error ending the stream, if any).
  var count = 0
  try:
    while count < maxEvents:
      var e: Event
      if fp.tryNext(e):
        into.add(describe(e))
        inc(count)
      elif fp.finished: break
      elif pos >= input.len: fp.finish()
      else:
        let last = min(pos + chunkSize, input.len) - 1
        fp.feed(input.toOpenArray(pos, last))
        pos = last + 1
  except YamlParserError as e:
    into.add(describe(e))

proc roundTrip(cp: YamlCheckpoint): YamlCheckpoint =
  ## checkpoints must survive serialization with NimYAML itself.
  load(Dumper().dump(cp), result)

proc suiteInputs(): seq[string] =
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path:
      result.add(path)
  result.sort()

proc expectedOf(input: string): seq[string] =
  initYamlParser().parse(input).drain(result)

proc compare(name: string, expected, actual: seq[string]): bool =
  if expected == actual: return true
  var i = 0
  while i < min(expected.len, actual.len) and expected[i] == actual[i]: inc(i)
  checkpoint(name & ": first difference at #" & $i & ": expected " &
             (if i < expected.len: expected[i].escape else: "<end>") &
             ", got " & (if i < actual.len: actual[i].escape else: "<end>"))
  fail()
  return false

suite "Checkpoints":
  test "yaml-test-suite: resume after every event":
    let inputs = suiteInputs()
    check inputs.len > 300
    for path in inputs:
      let input = readFile(path)
      let expected = expectedOf(input)
      # the last entry is yamlEndStream or an error; no checkpoint after it.
      for k in 0 ..< expected.len:
        let s = initYamlParser().parse(input)
        var actual: seq[string]
        for i in 0 ..< k: actual.add(describe(s.next()))
        let cp = roundTrip(s.checkpoint())
        check cp.offset >= 0 and cp.offset <= input.len
        initYamlParser().resume(cp, input[cp.offset .. ^1]).drain(actual)
        if not compare(path & " [after " & $k & "]", expected, actual): break

  test "yaml-test-suite: feed parser checkpoints":
    let inputs = suiteInputs()
    check inputs.len > 300
    for path in inputs:
      let input = readFile(path)
      let expected = expectedOf(input)
      for k in 0 ..< expected.len:
        var actual: seq[string]
        var pos = 0
        let fp = newYamlFeedParser(initYamlParser())
        fp.drain(input, pos, 7, actual, k)
        if actual.len < k: break # error before k events
        let cp = roundTrip(fp.checkpoint())
        # input fed beyond the checkpoint is not part of it
        check cp.offset <= pos
        var resumePos = cp.offset
        newYamlFeedParser(initYamlParser(), cp).drain(input, resumePos, 5, actual)
        if not compare(path & " [feed, after " & $k & "]", expected, actual):
          break

  test "large stream input, seek and resume repeatedly":
    var input = "%TAG !e! tag:example.com,2000:\n--- !e!root\nitems:\n"
    for i in 0 ..< 20000:
      input.add("  - &a" & $i & " {id: " & $i & ", name: \"item " & $i & "\"}\n")
    input.add("text: |\n")
    for i in 0 ..< 5000: input.add("  line " & $i & "\n")
    input.add("alias: *a7\n...\n--- [last]\n")
    let path = getTempDir() / "nimyaml_tcheckpoint.yaml"
    writeFile(path, input)
    defer: removeFile(path)
    let expected = expectedOf(input)
    var actual: seq[string]
    var s = initYamlParser().parse(newFileStream(path))
    var offsets: seq[int]
    var produced = 0
    for stop in [3, 15000, 60000, 80000, expected.len - 1]:
      while produced < stop:
        actual.add(describe(s.next()))
        inc(produced)
      let cp = roundTrip(s.checkpoint())
      offsets.add(cp.offset)
      let fs = newFileStream(path)
      fs.setPosition(cp.offset)
      s = initYamlParser().resume(cp, fs)
    s.drain(actual)
    discard compare("stream", expected, actual)
    # offsets refer to the original input, also from resumed parsers, and
    # consumed input is not part of the checkpoint
    check offsets == offsets.sorted()
    check offsets[^1] > input.len div 2

  test "peeked event is part of the checkpoint":
    let input = "a: [b, c]\n"
    let expected = expectedOf(input)
    let s = initYamlParser().parse(input)
    var actual: seq[string]
    for i in 0 ..< 3: actual.add(describe(s.next()))
    discard s.peek()
    let cp = roundTrip(s.checkpoint())
    check cp.peeked.len == 1
    initYamlParser().resume(cp, input[cp.offset .. ^1]).drain(actual)
    discard compare("peeked", expected, actual)
    # resuming a YamlStream checkpoint as feed parser keeps the event too
    var feedActual = actual[0 ..< 3]
    var pos = cp.offset
    newYamlFeedParser(initYamlParser(), cp).drain(input, pos, 4, feedActual)
    discard compare("peeked, feed", expected, feedActual)

  test "unstarted feed parser":
    let cp = roundTrip(newYamlFeedParser(initYamlParser()).checkpoint())
    check not cp.started
    check cp.offset == 0
    expect ValueError:
      discard initYamlParser().resume(cp, "a")
    var actual: seq[string]
    var pos = 0
    newYamlFeedParser(initYamlParser(), cp).drain("a: b\n", pos, 2, actual)
    discard compare("unstarted", expectedOf("a: b\n"), actual)

  test "invalid checkpoints are rejected":
    let s = initYamlParser().parse("a: b\n")
    discard s.next()
    var cp = s.checkpoint()
    var other = cp
    other.version = checkpointVersion + 1
    expect ValueError:
      discard initYamlParser().resume(other, "")
    other = cp
    other.levels[0].state = -1
    expect ValueError:
      discard initYamlParser().resume(other, "")
    other = cp
    other.lexer.state = 1000
    expect ValueError:
      discard initYamlParser().resume(other, "")

  test "not a parser":
    expect ValueError:
      discard newBufferYamlStream().checkpoint()
