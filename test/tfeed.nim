#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, streams, strutils, unittest, algorithm
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml/[data, parser, stream]

type Outcome = object
  events: seq[Event]
  failed: bool

proc collect(s: YamlStream): Outcome =
  try:
    while true:
      let e = s.next()
      result.events.add(e)
      if e.kind == yamlEndStream: break
  except YamlStreamError:
    result.failed = true

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
  except YamlParserError:
    result.failed = true

var stringReadData: proc(s: Stream, buffer: pointer, bufLen: int): int {.nimcall, gcsafe, raises: [IOError, OSError], tags: [ReadIOEffect].}

proc trickleRead(s: Stream, buffer: pointer, bufLen: int): int {.nimcall, gcsafe, raises: [IOError, OSError], tags: [ReadIOEffect].} =
  {.cast(gcsafe).}:
    result = stringReadData(s, buffer, min(bufLen, 1))

proc trickleStream(input: string): Stream =
  ## a stream that returns at most one byte per read.
  let s = newStringStream(input)
  stringReadData = s.readDataImpl
  s.readDataImpl = trickleRead
  result = s

proc compare(name: string, expected, actual: Outcome) =
  if expected.failed != actual.failed or
      (not expected.failed and expected.events != actual.events):
    checkpoint(name & ": expected failed=" & $expected.failed & " " &
               $expected.events.len & " events, got failed=" &
               $actual.failed & " " & $actual.events.len & " events")
    fail()

proc suiteInputs(): seq[string] =
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path:
      result.add(path)
  result.sort()

suite "Feed Parser":
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
