#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, streams, strutils, unittest, algorithm
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml/[data, parser, stream]

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

proc `$`(s: YamlDocumentStart): string = "(" & $s.offset & ", line " & $s.line & ")"

type Parsed = object
  events: seq[string]
  starts: seq[YamlDocumentStart] # per yamlStartDoc
  startIndex: seq[int]           # index of each yamlStartDoc in events
  failed: bool

proc collect(s: YamlStream): Parsed =
  try:
    while true:
      let e = s.next()
      if e.kind == yamlStartDoc:
        result.starts.add(s.documentStart())
        result.startIndex.add(result.events.len)
      result.events.add(describe(e))
      if e.kind == yamlEndStream: break
  except YamlStreamError as e:
    result.failed = true
    result.events.add(describe(if e.parent.isNil: (ref Exception)(e) else: e.parent))

proc feedFrom(input: string, start: YamlDocumentStart, chunkSize: int): seq[string] =
  let fp = newYamlFeedParser(initYamlParser(), start)
  var pos = start.offset
  try:
    while true:
      var e: Event
      if fp.tryNext(e):
        result.add(describe(e))
      elif fp.finished: break
      elif pos >= input.len: fp.finish()
      else:
        let last = min(pos + chunkSize, input.len) - 1
        fp.feed(input.toOpenArray(pos, last))
        pos = last + 1
  except YamlParserError as e:
    result.add(describe(e))

proc compare(name: string, expected, actual: seq[string]): bool =
  if expected == actual: return true
  var i = 0
  while i < min(expected.len, actual.len) and expected[i] == actual[i]: inc(i)
  checkpoint(name & ": first difference at #" & $i & ": expected " &
             (if i < expected.len: expected[i].escape else: "<end>") &
             ", got " & (if i < actual.len: actual[i].escape else: "<end>"))
  fail()
  return false

proc suiteInputs(): seq[string] =
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path:
      result.add(path)
  result.sort()

proc checkDocumentStarts(name, input: string) =
  let original = collect(initYamlParser().parse(input))
  if original.failed: return
  var last = -1
  for d, start in original.starts:
    check start.offset > last
    check start.offset <= input.len
    check start.offset == 0 or input[start.offset - 1] in {'\l', '\c'}
    last = start.offset
    # the rest of the original event stream, from this yamlStartDoc on
    let expected = original.events[original.startIndex[d] .. ^1]
    let rest = input[start.offset .. ^1]
    var fromString = collect(initYamlParser().parse(rest, start))
    var fromStream = collect(initYamlParser().parse(newStringStream(rest), start))
    for (mode, parsed) in [("string", fromString), ("stream", fromStream)]:
      # skip yamlStartStream of the new stream
      if not compare(name & " [document " & $d & ", " & mode & "]", expected,
                     parsed.events[1 .. ^1]): return
      # document starts are those of the original input
      if parsed.starts != original.starts[d .. ^1]:
        checkpoint(name & " [document " & $d & ", " & mode & "]: document starts " &
                   $parsed.starts & ", expected " & $original.starts[d .. ^1])
        fail()
        return
    for chunkSize in [1, 7]:
      if not compare(name & " [document " & $d & ", feed " & $chunkSize & "]",
                     expected, feedFrom(input, start, chunkSize)[1 .. ^1]): return

proc wellFormed(events: seq[Event]): bool =
  ## yamlStartStream first, yamlEndStream last, balanced documents and
  ## collections, an even number of children in every mapping.
  if events.len < 2 or events[0].kind != yamlStartStream or
      events[^1].kind != yamlEndStream:
    return false
  var stack: seq[(EventKind, int)]
  var inDoc = false
  for e in events[1 ..< ^1]:
    case e.kind
    of yamlStartDoc:
      if inDoc: return false
      inDoc = true
    of yamlEndDoc:
      if not inDoc or stack.len > 0: return false
      inDoc = false
    of yamlStartMap, yamlStartSeq:
      if not inDoc: return false
      if stack.len > 0: inc(stack[^1][1])
      stack.add((e.kind, 0))
    of yamlEndMap, yamlEndSeq:
      if stack.len == 0: return false
      let (kind, children) = stack.pop()
      if (e.kind == yamlEndMap) != (kind == yamlStartMap): return false
      if kind == yamlStartMap and children mod 2 != 0: return false
    of yamlScalar, yamlAlias:
      if not inDoc: return false
      if stack.len > 0: inc(stack[^1][1])
    else: return false
  return not inDoc and stack.len == 0

proc collectAll(s: YamlStream): seq[Event] =
  for e in s: result.add(e)

suite "Error recovery":
  test "valid input: same events as parse, no errors":
    for path in suiteInputs():
      let input = readFile(path)
      let original = collect(initYamlParser().parse(input))
      if original.failed: continue
      let rs = initYamlParser().parseRecovering(input)
      let recovered = collect(rs)
      discard compare(path, original.events, recovered.events)
      check rs.errors.len == 0
      check recovered.starts == original.starts

  test "invalid input: terminates with errors and a well-formed stream":
    var tested = 0
    for path in suiteInputs():
      let input = readFile(path)
      if not collect(initYamlParser().parse(input)).failed: continue
      inc(tested)
      let rs = initYamlParser().parseRecovering(input)
      var events: seq[Event]
      var starts: seq[YamlDocumentStart]
      for e in rs:
        if e.kind == yamlStartDoc: starts.add(rs.documentStart())
        events.add(e)
      if not wellFormed(events):
        checkpoint(path & ": not well-formed")
        fail()
      check rs.errors.len >= 1
      # every recovered document is what parsing from its start yields
      var docIndex = 0
      var i = 0
      while i < events.len:
        if events[i].kind == yamlStartDoc:
          var j = i
          while events[j].kind != yamlEndDoc: inc(j)
          let start = starts[docIndex]
          # the fresh parse may fail in a later document; stop at this one
          var fresh: seq[Event]
          for e in initYamlParser().parse(input[start.offset .. ^1], start):
            fresh.add(e)
            if e.kind == yamlEndDoc: break
          var doc: seq[string]
          for k in i .. j: doc.add(describe(events[k]))
          var freshDoc: seq[string]
          for k in 1 .. min(j - i + 1, fresh.len - 1):
            freshDoc.add(describe(fresh[k]))
          discard compare(path & " [recovered document " & $docIndex & "]",
                          freshDoc, doc)
          inc(docIndex)
          i = j
        inc(i)
    check tested > 50

  test "invalid document between valid ones":
    const
      valid = ["a: 1\n", "- x\n- y\n", "[f, {g: h}]\n", "|\n  block\n",
               "\"q\"\n", "!!str &a s\n"]
      invalid = ["a: [b\n", "}\n", "a: b\n c: d\n", "\"unclosed\n",
                 "- a\nb: c\n", "a: |\n  x\n y\n", "{a: b\n", "&a &b c\n",
                 "!e!x a\n", "a: \"\\q\"\n"]
    for first in valid:
      for bad in invalid:
        for last in valid:
          for sep in ["---\n", "...\n---\n", "...\n"]:
            let input = "---\n" & first & sep & bad & sep & last
            # the last document starts at its `---` line, or after `...`
            let lastSep = input.rfind(sep)
            let lastOffset =
              if sep == "...\n": lastSep + sep.len
              else: lastSep + sep.len - "---\n".len
            let lastStart = YamlDocumentStart(offset: lastOffset,
                line: input[0 ..< lastOffset].count('\l') + 1)
            # events of the first document, as parse yields them before
            # failing, then those of the last document
            var expected: seq[string]
            for e in initYamlParser().parse(input):
              expected.add(describe(e))
              if e.kind == yamlEndDoc: break
            let tail = collect(initYamlParser().parse(
                input[lastStart.offset .. ^1], lastStart)).events
            expected.add(tail[1 .. ^1])
            for viaStream in [false, true]:
              let rs =
                if viaStream: initYamlParser().parseRecovering(newStringStream(input))
                else: initYamlParser().parseRecovering(input)
              let actual = collect(rs)
              let name = (first & sep & bad & sep & last).escape &
                  (if viaStream: " [stream]" else: "")
              if not compare(name, expected, actual.events): continue
              check rs.errors.len == 1
              if rs.errors.len == 1:
                check rs.errors[0].resumedAt == lastStart

  test "error in the first token":
    let rs = initYamlParser().parseRecovering("]\n---\na\n")
    let events = collectAll(rs)
    check wellFormed(events)
    check rs.errors.len == 1
    var scalars: seq[string]
    for e in events:
      if e.kind == yamlScalar: scalars.add(e.scalarContent)
    check scalars == @["a"]

  test "no document after the error":
    let rs = initYamlParser().parseRecovering("a: b\n---\nc: [\n")
    let events = collectAll(rs)
    check wellFormed(events)
    check rs.errors.len == 1
    check rs.errors[0].resumedAt.offset == -1
    var scalars: seq[string]
    for e in events:
      if e.kind == yamlScalar: scalars.add(e.scalarContent)
    check scalars == @["a", "b"]

  test "repeated errors on marker lines":
    let rs = initYamlParser().parseRecovering("--- ]\n--- }\n--- ok\n")
    let events = collectAll(rs)
    check wellFormed(events)
    check rs.errors.len == 2
    var scalars: seq[string]
    for e in events:
      if e.kind == yamlScalar: scalars.add(e.scalarContent)
    check scalars == @["ok"]

suite "Root properties on a `---` line":
  # A tag or anchor of a root scalar written on the `---` line used to stay
  # in the parser and was applied to the root of the next document as well
  # (a second tag then failed with "Only one tag allowed per node").
  proc rootTags(source: string): seq[string] =
    for e in initYamlParser().parse(source):
      if e.kind == yamlScalar: result.add($e.scalarProperties.tag)

  test "belong to their document only":
    check rootTags("--- !!str a\n--- b\n") ==
        @["tag:yaml.org,2002:str", "?"]
    check rootTags("--- !!str a\n...\n--- !!int 1\n") ==
        @["tag:yaml.org,2002:str", "tag:yaml.org,2002:int"]
    check rootTags("--- !!str\n--- b\n") == @["tag:yaml.org,2002:str", "?"]

suite "Flow collections on a `---` line":
  # The parser used to reject any flow collection that starts on the `---`
  # line ("Illegal content at `---`"), although YAML 1.2 example 9.4 has one.
  proc shape(source: string): seq[string] =
    for e in initYamlParser().parse(source): result.add($e)

  test "are the root node of their document":
    check shape("--- [a, b]\n") == @["+STR", "+DOC ---", "+SEQ []", "=VAL :a",
        "=VAL :b", "-SEQ", "-DOC", "-STR"]
    check shape("--- { matches %: 20 }\n...\n--- !!seq [x]\n")[2 .. 5] ==
        @["+MAP {}", "=VAL :matches %", "=VAL :20", "-MAP"]
    check shape("--- &a {b: c}\n")[2] == "+MAP {} &a"

  test "multi-line flow collections":
    check shape("--- [a,\n  b]\n")[2 .. 5] ==
        @["+SEQ []", "=VAL :a", "=VAL :b", "-SEQ"]

  test "content after the collection is an error":
    expect YamlStreamError:
      discard shape("--- [a]\nb\n")

suite "Document starts":
  test "yaml-test-suite: parsing from each document start":
    let inputs = suiteInputs()
    check inputs.len > 300
    for path in inputs: checkDocumentStarts(path, readFile(path))

  test "edge cases":
    for i, input in [
        "a\n---\nb\n...\n%YAML 1.2\n%TAG !e! tag:e,2000:\n--- !e!x c\n",
        "# comment\n\n\xEF\xBB\xBF--- a\n...\n# between\n...\n--- b\n",
        "a: 1\r\n---\r\nb: 2\r\n...\r\nc: 3\r\n",
        "--- |\n  block\n--- >\n  folded\n...\n",
        "[a,\n b]\n--- {c: d}\n---\n...\n"]:
      checkDocumentStarts("edge #" & $i, input)

  test "not a parser":
    expect ValueError:
      discard newBufferYamlStream().documentStart()

  test "root collection position in a document starting with ---":
    # the start position used to come from the previous document
    for (input, line, column) in [
        ("b: 2\n", 1, 1),               # no `---`, for comparison
        ("a: 1\n---\nb: 2\n", 3, 1),
        ("x: [y]\n---\n  - z\n", 3, 3),
        ("a\n--- !!map\nb: c\n", 2, 5),  # node properties on the `---` line
        ("a\n---\n!!map\nb: c\n", 3, 1)]:
      # the root collection of the last document
      var last, root: Event
      for e in initYamlParser().parse(input):
        if e.kind in {yamlStartMap, yamlStartSeq} and last.kind == yamlStartDoc:
          root = e
        last = e
      check last.kind == yamlEndStream
      checkpoint(input.escape)
      check root.kind in {yamlStartMap, yamlStartSeq}
      check root.startPos.line == line
      check root.startPos.column == column
