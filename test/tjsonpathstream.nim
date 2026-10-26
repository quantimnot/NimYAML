#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# The streaming JSONPath evaluator must select what the evaluator of graphs
# selects, for every query it takes: the queries of the JSONPath Compliance
# Test Suite, and YAML that the suite has no JSON for (aliases, several
# documents). Mapping members come in document order from it, in no
# particular order from the other, so results are compared by path.

import std/[algorithm, os, unittest]
import "../yaml", "../yaml/dom", "../yaml/jsonpath", "../yaml/memory",
    "../yaml/parser", "../yaml/stream",
    "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

proc streamed(text: string, path: JsonPath, budget: MemoryBudget = nil):
    seq[seq[LocatedNode]] =
  ## The nodes ``path`` selects in each document of ``text``, by streaming.
  var s = initYamlParser().parse(text)
  discard s.next() # yamlStartStream
  while s.peek().kind == yamlStartDoc:
    discard s.next()
    var found: seq[LocatedNode]
    for f in queryStream(s, path, budget): found.add(f)
    discard s.next() # yamlEndDoc
    result.add(found)

proc fromGraphs(text: string, path: JsonPath): seq[seq[LocatedNode]] =
  var roots: seq[YamlNode]
  loadMultiDoc(text, roots)
  for root in roots: result.add(root.queryLocated(path))

proc byPath(found: seq[LocatedNode]): seq[LocatedNode] =
  result = found
  result.sort(proc(a, b: LocatedNode): int = cmp(a.path, b.path))

proc same(a, b: seq[seq[LocatedNode]]): bool =
  if a.len != b.len: return false
  for d in 0 ..< a.len:
    let (x, y) = (a[d].byPath, b[d].byPath)
    if x.len != y.len: return false
    for i in 0 ..< x.len:
      if x[i].path != y[i].path or not jsonEquals(x[i].node, y[i].node):
        return false
  true

suite "streaming JSONPath":
  test "the compliance test suite":
    let
      ctsPath = currentSourcePath.parentDir /
          "jsonpath-compliance-test-suite" / "cts.json"
      cts = loadAs[YamlNode](readFile(ctsPath))
    var streamedCases = 0
    for testCase in cts["tests"].elems:
      if testCase.hasKey("invalid_selector"): continue
      let path = parseJsonPath(testCase["selector"].content)
      if not path.streamable: continue
      inc(streamedCases)
      let text = blockOnlyDumper().dump(testCase["document"])
      if not same(streamed(text, path), fromGraphs(text, path)):
        checkpoint(testCase["name"].content & ": " & $path)
        fail()
    check streamedCases > 150

  test "what streams":
    for q in ["$", "$.a", "$.a.b[0]", "$[*].id", "$['k']", "$[1:3]",
        "$[2:]", "$[0:10:2]", "$[?@.k > 1].name", "$.a[?length(@) > 2]"]:
      check parseJsonPath(q).streamable
    for q in ["$..a", "$['a','b']", "$[-1]", "$[-2:]", "$[::-1]",
        "$[?@.k == $.max]", "$.a[0, 1]"]:
      check not parseJsonPath(q).streamable

  test "aliases":
    let text = "base: &b {k: 1, l: [x, y]}\nitem: *b\nitems: [*b, {k: 2}]\n" &
        "deep: {d: *b}\n"
    for q in ["$.item", "$.item.k", "$.items[*].k", "$.deep.d.l[1]",
        "$.items[?@.k == 1]", "$.base"]:
      let path = parseJsonPath(q)
      check same(streamed(text, path), fromGraphs(text, path))

  test "several documents, sequences in order":
    let text = "--- [a, b, c]\n--- {x: [1, 2, 3]}\n--- 3\n"
    let path = parseJsonPath("$[*]")
    check same(streamed(text, path), fromGraphs(text, path))
    let found = streamed(text, path)[0]
    check found.len == 3
    check found[0].path == "$[0]" and found[2].path == "$[2]"

  test "only selected nodes are held":
    var text = "items:\n"
    for i in 0 ..< 20_000: text.add("  - {id: " & $i & ", name: item}\n")
    let budget = newMemoryBudget(512 * 1024)
    let found = streamed(text, parseJsonPath("$.items[*].id"), budget)
    check found[0].len == 20_000
    check budget.used == 0
