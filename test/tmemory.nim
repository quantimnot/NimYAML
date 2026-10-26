#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml/memory
import unittest, strutils, osproc

suite "memory sizes":
  test "parseSize":
    check parseSize("123") == 123
    check parseSize("64KiB") == 65536
    check parseSize("16MiB") == 16 shl 20
    check parseSize("1GiB") == 1 shl 30
    check parseSize("2TiB") == 2 shl 40
    check parseSize("10MB") == 10_000_000
    check parseSize("5kB") == 5000
    check parseSize(" 4 KiB ") == 4096
    check parseSize("unlimited") == int.high
    expect ValueError: discard parseSize("12XB")
    expect ValueError: discard parseSize("-1")
    expect ValueError: discard parseSize("")
    expect ValueError: discard parseSize("KiB")

  test "formatSize":
    check formatSize(64 shl 20) == "64 MiB"
    check formatSize(512) == "512 B"
    check formatSize(1536 shl 20) == "1.5 GiB"
    check formatSize(4096) == "4 KiB"
    check formatSize(int.high) == "unlimited"

suite "memory budget":
  test "reserve and release":
    let b = newMemoryBudget(1000)
    b.reserve(600, "a")
    check b.used == 600
    b.reserve(400, "b")
    check b.used == 1000
    b.release(700)
    check b.used == 300
    check b.peak == 1000
    check b.available == 700

  test "reserve past the limit":
    let b = newMemoryBudget(1000)
    b.reserve(900, "first")
    try:
      b.reserve(200, "reading line 3")
      check false
    except YamlMemoryLimitError as e:
      check e.needed == 1100
      check e.limit == 1000
      check e.operation == "reading line 3"
      check "reading line 3" in e.describe
      check "limit" in e.describe
    check b.used == 900

  test "nil budget":
    let b: MemoryBudget = nil
    b.reserve(int.high div 2, "x")
    b.release(10)
    check b.available == int.high

  test "error in the parent chain":
    let inner = (ref YamlMemoryLimitError)(msg: "m", operation: "op",
        needed: 2, limit: 1)
    let outer = (ref ValueError)(msg: "outer",
        parent: (ref IOError)(msg: "mid", parent: inner))
    check memoryLimitError(outer) == inner
    check memoryLimitError((ref ValueError)(msg: "no")).isNil

suite "host memory":
  test "detected":
    when defined(macosx) or defined(linux) or defined(windows):
      check hostMemory() > 0
      check autoLimit() == hostMemory() div 2
    else:
      check hostMemory() == -1

# parsing within a budget

import ../yaml/[source, parser, stream, data]
import std/[os, streams]
when defined(nimPreviewSlimSystem):
  import std/syncio

let parseTmp = getTempDir() / ("yaml-memory-test-" & $getCurrentProcessId())
createDir(parseTmp)

proc manyDocuments(path: string, bytes: int) =
  let f = open(path, fmWrite)
  var written, i = 0
  while written < bytes:
    let doc = "---\nid: " & $i & "\nname: item " & $i &
        "\ntags: [a, b, c]\nnested: {x: 1, y: [2, 3]}\n"
    f.write(doc)
    written += doc.len
    inc i
  f.close()

proc eventsOf(s: YamlStream): seq[string] =
  for e in s: result.add($e)

suite "parsing within a budget":
  let docs = parseTmp / "docs.yaml"
  manyDocuments(docs, 5_000_000)

  test "events equal the in-memory parse, peak within the limit":
    let expected = eventsOf(initYamlParser().parse(readFile(docs)))
    for choice in [tcMmap, tcSeek, tcStream]:
      let b = newMemoryBudget(256 * 1024)
      let src = openSource(docs, b, SourcePolicy(choice: choice))
      var p = initYamlParser(budget = b)
      check eventsOf(p.parse(src)) == expected
      check b.peak < 256 * 1024
      src.close()

  test "a line longer than the limit":
    let long = parseTmp / "long.yaml"
    writeFile(long, "key: " & repeat('v', 300 * 1024) & "\n")
    let b = newMemoryBudget(128 * 1024)
    let src = openSource(long, b, SourcePolicy(choice: tcSeek))
    var p = initYamlParser(budget = b)
    try:
      discard eventsOf(p.parse(src))
      check false
    except YamlStreamError as e:
      let limit = memoryLimitError(e)
      check not limit.isNil
      check limit.limit == 128 * 1024
      check (ref YamlParserError)(e.parent).mark.line == 1
    src.close()

  test "a tiny limit fails cleanly":
    let b = newMemoryBudget(1024)
    let src = openSource(docs, b, SourcePolicy(choice: tcStream))
    var p = initYamlParser(budget = b)
    expect YamlStreamError: discard eventsOf(p.parse(src))
    src.close()

  test "the feed parser charges fed input":
    let b = newMemoryBudget(64 * 1024)
    let fp = newYamlFeedParser(initYamlParser(budget = b))
    expect YamlMemoryLimitError:
      fp.feed(repeat("a: 1\n", 20_000))

  test "string input is not charged again":
    let b = newMemoryBudget(16)
    var p = initYamlParser(budget = b)
    check eventsOf(p.parse("a: [1, 2]")).len > 0
    check b.peak == 0

suite "budget balance":
  test "parsing many inputs through one budget leaves nothing reserved":
    let b = newMemoryBudget(32 * 1024)
    let small = parseTmp / "small.yaml"
    writeFile(small, "a: [1, 2]\nb: {c: d}\n")
    for i in 0 ..< 200:
      let src = openSource(small, b, SourcePolicy(choice: tcSeek))
      var p = initYamlParser(budget = b)
      discard eventsOf(p.parse(src))
      src.close()
    check b.used == 0

  test "an abandoned parse releases its buffer":
    let b = newMemoryBudget(32 * 1024)
    for i in 0 ..< 200:
      var p = initYamlParser(budget = b)
      var s = p.parse(newStringStream("a: [1, 2]\nb: c\n"))
      discard s.next()
      discard s.next()
    GC_fullCollect()
    check b.used == 0

suite "microcontroller build":
  test "parser compiles with --os:any":
    let dir = currentSourcePath.parentDir
    let (output, code) = execCmdEx("nim c --os:any -d:useMalloc --mm:arc " &
        "--hints:off --compileOnly --nimcache:" &
        quoteShell(parseTmp / "osany-cache") & " " &
        quoteShell(dir / "osany" / "parse.nim"))
    check code == 0
    if code != 0: echo output

  test "the same program runs on the host":
    let dir = currentSourcePath.parentDir
    let (output, code) = execCmdEx("nim r --hints:off --nimcache:" &
        quoteShell(parseTmp / "host-cache") & " " &
        quoteShell(dir / "osany" / "parse.nim"))
    check code == 0
    check "+MAP" in output
    check "=VAL :2" in output

removeDir(parseTmp)

# construction within a budget

import ../yaml/[native, dom]
import std/tables

proc mappingEvents(entries: int): YamlStream =
  var text = ""
  for i in 0 ..< entries: text.add("key" & $i & ": value number " & $i & "\n")
  initYamlParser().parse(text)

suite "construction within a budget":
  test "the DOM is charged about what it takes":
    var s = mappingEvents(10_000)
    discard s.next() # yamlStartStream
    let b = newMemoryBudget()
    let before = getOccupiedMem()
    var root: YamlNode
    let charged = construct(s, root, b)
    let taken = getOccupiedMem() - before
    check charged == b.used
    check charged.float >= taken.float * 0.5
    check charged.float <= taken.float * 1.25
    check root.fields.len == 10_000

  test "a document larger than the limit fails early":
    var s = mappingEvents(100_000)
    discard s.next()
    let b = newMemoryBudget(1 shl 20)
    let before = getOccupiedMem()
    var root: YamlNode
    try:
      discard construct(s, root, b)
      check false
    except YamlStreamError as e:
      check not memoryLimitError(e).isNil
    check getOccupiedMem() - before < 4 shl 20

  test "typed values are charged too":
    type Item = object
      key, value: string
    var text = ""
    for i in 0 ..< 1000: text.add("- {key: k" & $i & ", value: v" & $i & "}\n")
    var s = initYamlParser().parse(text)
    discard s.next()
    let b = newMemoryBudget()
    var items: seq[Item]
    check construct(s, items, b) > 1000 * 64
    check items.len == 1000
