#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# The index must never answer differently from a parse: the suite below
# checks every node of every valid input of the yaml-test-suite, read from
# its slice, against the node the parse gives, or that the slice falls back.

import std/[algorithm, options, os, strutils, tables, times, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[dom, jsonpath, loading, native, nodeindex, parser, spans, source, memory,
    stream, cbor, dumping]

proc rootsOf(source: string): seq[YamlNode] =
  var s = initYamlParser().parse(source)
  discard s.next() # yamlStartStream
  while s.peek().kind == yamlStartDoc:
    var root: YamlNode
    construct(s, root)
    result.add(root)

proc parsedNodes(source, path: string): seq[YamlNode] =
  ## The nodes ``path`` names, by parsing: what the index must agree with.
  for root in rootsOf(source):
    for found in root.queryLocated(parseJsonPath(path)):
      result.add(found.node)

proc sameNodes(a, b: seq[YamlNode]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

proc indexed(source: string, index: YamlIndex, path: string):
    Option[seq[YamlNode]] =
  ## The nodes ``path`` names, read from their slices of ``source``.
  let hits = index.lookup(path)
  if hits.isNone: return
  var nodes: seq[YamlNode]
  for hit in hits.get():
    if not index.documents[hit.document].selfContained: return
    let node = nodeOfSlice(source[hit.entry.start ..< hit.entry.stop],
        hit.entry, index.json)
    if node.isNone: return
    nodes.add(node.get())
  some(nodes)

proc agrees(source, path: string, index: YamlIndex): bool =
  ## Whether the index gives the nodes a parse gives, or falls back.
  let fromIndex = indexed(source, index, path)
  if fromIndex.isNone: return true
  let parsed = parsedNodes(source, path)
  result = sameNodes(fromIndex.get(), parsed)
  if not result:
    checkpoint(path & ": index gives " & $fromIndex.get().len &
        " nodes, the parse " & $parsed.len)

proc suiteInputs(): seq[string] =
  ## the valid inputs of the yaml-test-suite
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path and
        not fileExists(path.parentDir / "error"):
      result.add(path)
  result.sort()

suite "spans":
  test "nodes, keys and aliases":
    let doc = sourceSpans("a: &x [1, 2]\nb: *x\n").documents[0]
    let a = doc.nodes["$['a']"]
    check a.kind == skFlow
    check (a.start, a.content, a.stop) == (3, 6, 12)
    check a.anchor == "x"
    check doc.nodes["$['b']"].kind == skAlias
    check doc.nodes["$['b']"].aliasOf == "x"
    check doc.aliases["$['b']"] == "$['a']"
    check doc.keys["$['b']"].start == 13
    let (path, span) = doc.resolve("$['b'][1]")
    check path == "$['a'][1]"
    check span.start == 10

  test "missing nodes":
    let doc = sourceSpans("a: 1\n").documents[0]
    expect YamlSpanMissing: discard doc.resolve("$['z']")

  test "document starts":
    let spans = sourceSpans("a: 1\n---\nb: 2\n...\n%YAML 1.2\n---\nc: 3\n")
    check spans.documents.len == 3
    check spans.documents[1].start.offset == 5
    check spans.documents[1].selfContained
    check spans.documents[2].start.offset == 18
    check not spans.documents[2].selfContained

suite "normalizedPath":
  test "singular queries":
    check parseJsonPath("$.a['b'][0]").normalizedPath == "$['a']['b'][0]"
    check parseJsonPath("$").normalizedPath == "$"
    check parseJsonPath("$[\"it's\"]").normalizedPath == "$['it\\'s']"

  test "other queries have none":
    check parseJsonPath("$.a[-1]").normalizedPath == ""
    check parseJsonPath("$..a").normalizedPath == ""
    check parseJsonPath("$.a[*]").normalizedPath == ""
    check parseJsonPath("$.a[0:2]").normalizedPath == ""

suite "nodeindex":
  test "lookup reads a node from its slice":
    let source = "a:\n  b: [1, 2]\n  c: |\n    text\nd: 3\n"
    let index = buildIndex(source)
    let hits = index.lookup("$['a']['b']").get()
    check hits.len == 1
    check source[hits[0].entry.start ..< hits[0].entry.stop] == "[1, 2]"
    for path in ["$", "$['a']", "$['a']['b']", "$['a']['b'][1]",
        "$['a']['c']", "$['d']"]:
      check indexed(source, index, path).isSome
      check agrees(source, path, index)
    check index.lookup("$['z']").get().len == 0

  test "nodes of every document":
    let source = "a: 1\n---\na: 2\n---\nb: 3\n"
    let index = buildIndex(source)
    let hits = index.lookup("$['a']").get()
    check hits.len == 2
    check hits[1].document == 1
    check agrees(source, "$['a']", index)

  test "aliases lead to their anchored node":
    let source = "base: &b {x: 1, y: [2]}\nuse: *b\n"
    let index = buildIndex(source)
    let entry = index.lookup("$['use']['y'][0]").get()[0].entry
    check source[entry.start ..< entry.stop] == "2"
    check agrees(source, "$['use']", index)
    check agrees(source, "$['use']['y'][0]", index)
    var alias: IndexEntry
    for e in index.documents[0].entries:
      if e.path == "$['use']": alias = e
    check alias.kind == skAlias
    check alias.alias == "b"
    check alias.target == "$['base']"

  test "slices that do not mean the same fall back":
    # an alias of an anchor outside the slice
    let outside = "a: &x 1\nb: [*x, 2]\n"
    check indexed(outside, buildIndex(outside), "$['b']").isNone
    check indexed(outside, buildIndex(outside), "$['b'][1]").isSome
    # tag handles of a %TAG directive
    let tagged = "%TAG !e! tag:example.com,2000:\n---\na: !e!t 1\n"
    check indexed(tagged, buildIndex(tagged), "$['a']").isNone
    # trailing line breaks that are kept
    let kept = "a: |+\n  text\n\nb: 1\n"
    check indexed(kept, buildIndex(kept), "$['a']").isNone
    check agrees(kept, "$['b']", buildIndex(kept))

  test "empty nodes":
    let source = "a:\nb: 1\n"
    let index = buildIndex(source)
    check indexed(source, index, "$['a']").isSome
    check agrees(source, "$['a']", index)

  test "json":
    let source = "{\"a\": [1, {\"b\": true}], // note\n \"c\": \"x\"}\n"
    let index = buildIndex(source, json = true)
    for path in ["$['a']", "$['a'][1]['b']", "$['c']"]:
      check indexed(source, index, path).isSome
      check agrees(stripJsonComments(source), path, index)

  test "recent: only looked up paths, least recently used dropped":
    let source = "a: 1\nb: 2\nc: 3\n"
    let spans = sourceSpans(source)
    var index = buildIndex(source, spans, imRecent)
    check index.lookup("$['a']").isNone
    index.record(source, spans, "$['a']", 1, limit = 2)
    index.record(source, spans, "$['b']", 2, limit = 2)
    check index.lookup("$['a']").get().len == 1
    index.touch("$['a']", 3)
    index.record(source, spans, "$['c']", 4, limit = 2)
    check index.lookup("$['b']").isNone
    check index.lookup("$['a']").isSome
    check index.lookup("$['c']").isSome
    # a path no document has is recorded as having no nodes
    index.record(source, spans, "$['z']", 5, limit = 3)
    check index.lookup("$['z']").get().len == 0

  test "stored as cbor and yaml":
    let tmp = getTempDir() / "tnodeindex-" & $getCurrentProcessId()
    defer: removeDir(tmp)
    let index = buildIndex("a: &x [1, 2]\nb: *x\n")
    for format in IndexFormat:
      let path = tmp / ("index." & $format)
      check index.writeIndex(path, format)
      let read = readIndex(path, format)
      check read.isSome
      check read.get().documents[0].entries == index.documents[0].entries
      check read.get().source == index.source

suite "nodeindex: fingerprints":
  test "a file is hashed in chunks":
    let path = getTempDir() / ("fingerprint-" & $getCurrentProcessId() & ".yaml")
    var text = ""
    for i in 0 ..< 20000: text.add("k" & $i & ": v\n")
    writeFile(path, text)
    check fingerprintFile(path, 7) == fingerprint(text, 7)
    writeFile(path, "")
    check fingerprintFile(path) == fingerprint("")
    removeFile(path)

suite "nodeindex: files":
  setup:
    let tmp = getTempDir() / "tnodeindex-files-" & $getCurrentProcessId()
    createDir(tmp)
    let file = tmp / "data.yaml"
  teardown:
    removeDir(tmp)

  test "locations":
    var settings = IndexSettings(mode: imAll, format: ifCbor,
        location: ilBeside)
    check indexFile(file, settings) == tmp / ".data.yaml.index.cbor"
    settings.location = ilProject
    settings.configDir = tmp.parentDir
    check indexFile(file, settings) == tmp.parentDir / projectIndexDirName /
        tmp.extractFilename / "data.yaml.index.cbor"
    settings.location = ilUser
    check indexFile(file, settings).startsWith(getCacheDir("nimyaml") /
        "index")
    check indexFile(file, IndexSettings(mode: imOff)) == ""

  for mode in [imAll, imRecent]:
    test "lookup, update and staleness: " & $mode:
      let settings = IndexSettings(mode: mode, format: ifYaml,
          location: ilBeside, recentLimit: 8)
      let source = "a:\n  b: [1, 2]\nc: 3\n"
      writeFile(file, source)
      check indexedNodes(file, "$['a']['b']", settings).isNone
      updateIndex(file, source, ["$['a']['b']"], settings)
      check fileExists(indexFile(file, settings))
      let nodes = indexedNodes(file, "$['a']['b']", settings)
      check nodes.isSome
      check sameNodes(nodes.get(), parsedNodes(source, "$['a']['b']"))
      # an edit outside the tools makes the index stale
      writeFile(file, "a:\n  b: [9, 9]\nc: 3\n")
      check indexedNodes(file, "$['a']['b']", settings).isNone
      # a write through the tools refreshes it
      refreshIndex(file, "a:\n  b: [9, 9]\nc: 3\n", settings)
      let fresh = indexedNodes(file, "$['a']['b']", settings)
      check fresh.isSome
      check fresh.get()[0].elems[0].content == "9"

  test "a touched file with the same content keeps its index":
    let settings = IndexSettings(mode: imAll, format: ifCbor,
        location: ilBeside)
    writeFile(file, "a: 1\n")
    updateIndex(file, "a: 1\n", [], settings)
    setLastModificationTime(file, getTime() + initDuration(seconds = 5))
    check indexedNodes(file, "$['a']", settings).isSome

suite "nodeindex: yaml-test-suite":
  test "every node agrees with the parse":
    var inputs, nodes, sliced = 0
    for input in suiteInputs():
      let source = readFile(input)
      var index: YamlIndex
      try: index = buildIndex(source)
      except CatchableError: continue # the parser rejects it
      inc(inputs)
      for doc in index.documents:
        for entry in doc.entries:
          inc(nodes)
          if indexed(source, index, entry.path).isSome: inc(sliced)
          if not agrees(source, entry.path, index):
            checkpoint(input)
            fail()
    check inputs > 250
    # most nodes are read from their slices, not by falling back
    check sliced * 10 > nodes * 8
    echo "  ", inputs, " inputs, ", nodes, " nodes, ", sliced, " from slices"

suite "nodeindex: from a source":
  test "spans and indexes equal those of the text":
    var inputs = 0
    for input in suiteInputs():
      let source = readFile(input)
      var expected: SourceSpans
      try: expected = sourceSpans(source)
      except CatchableError: continue # the parser rejects it
      inc(inputs)
      let src = openSource(input, newMemoryBudget(1 shl 20),
          SourcePolicy(choice: tcSeek, pageCache: 8192))
      var docs: seq[DocumentSpans]
      for doc in documentSpans(src): docs.add(doc)
      let index = buildIndex(src, imAll)
      src.close()
      if docs != expected.documents or index != buildIndex(source, expected):
        checkpoint(input)
        fail()
    check inputs > 250

  test "recent paths are recorded from a source":
    let source = "a: {b: 1}\n---\na: {b: 2, c: [x]}\n"
    let path = getTempDir() / ("recent-" & $getCurrentProcessId() & ".yaml")
    writeFile(path, source)
    var expected = buildIndex(source, imRecent)
    let spans = sourceSpans(source)
    for p in ["$['a']['b']", "$['a']['c'][0]"]:
      expected.record(source, spans, p, 7, 8)
    let src = openSource(path)
    var index = buildIndex(src, imRecent)
    index.record(src, @[("$['a']['b']", 7'i64), ("$['a']['c'][0]", 7'i64)], 8)
    src.close()
    removeFile(path)
    check index == expected

  test "the JSON of a file":
    let source = "{\"a\": [1, // one\n 2]}\n"
    let path = getTempDir() / ("json-" & $getCurrentProcessId() & ".jsonc")
    writeFile(path, source)
    let src = openSource(path)
    check buildIndex(src, imAll, json = true) ==
        buildIndex(source, imAll, json = true)
    src.close()
    removeFile(path)

suite "nodeindex: writing":
  test "an index is written as dumping it gives it, in both formats":
    var source = ""
    for i in 0 ..< 50: source.add("--- {a: " & $i & ", b: [x, y], &c c: *c}\n")
    let index = buildIndex(source, imAll)
    let dir = getTempDir() / ("index-writing-" & $getCurrentProcessId())
    check index.writeIndex(dir / "i.cbor", ifCbor)
    check readFile(dir / "i.cbor") == dumpCbor(Dumper(), index)
    check index.writeIndex(dir / "i.yaml", ifYaml)
    check readFile(dir / "i.yaml") == blockOnlyDumper().dump(index)
    check readIndex(dir / "i.cbor", ifCbor) == some(index)
    removeDir(dir)

  test "writing a large index holds one document at a time":
    var source = ""
    for i in 0 ..< 4000: source.add("--- {a: " & $i & ", b: [x, y]}\n")
    let index = buildIndex(source, imAll)
    let dir = getTempDir() / ("index-large-" & $getCurrentProcessId())
    # the peak so far is below the occupied memory plus what writing adds
    let before = max(getMaxMem(), getOccupiedMem())
    check index.writeIndex(dir / "i.yaml", ifYaml)
    # the whole index as events would take tens of megabytes
    check getMaxMem() - before < 4 shl 20
    removeDir(dir)
