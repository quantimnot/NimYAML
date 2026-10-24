#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/diff. Every record of the JSON Patch test suite that has an
# expected result is also a pair of documents to diff: the patch made from
# their changes must turn one into the other.

import std/[json, os, strutils, unittest]
import "../yaml", "../yaml/dom", "../yaml/diff", "../yaml/jsonpatch",
    "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

proc node(yaml: string): YamlNode = loadAs[YamlNode](yaml)

proc summary(old, new: string): seq[string] =
  ## Each change as ``kind oldPointer newPointer``.
  for change in diff(node(old), node(new)):
    result.add($change.kind & " " & change.oldPath.toJsonPointer & " " &
        change.newPath.toJsonPointer)

proc roundTrips(old, new: YamlNode): bool =
  let patched = old.applyJsonPatch(toJsonPatch(diff(old, new)))
  result = jsonEquals(patched, new)
  if not result:
    checkpoint("patch: " & $toJsonPatch(diff(old, new)))

suite "diff":
  test "equal documents, however written":
    check summary("{a: 1, b: [x, y]}", "b:\n  - x\n  - 'y'\na: 1\n").len == 0
    check summary("a: &x {b: 1}\nc: *x\n", "a: {b: 1}\nc: {b: 1}\n").len == 0
    check summary("a: 1.0", "a: 1").len == 0
    check summary("a: ~", "a: null").len == 0
    check summary("200: OK", "\"200\": OK").len == 0
    check semanticEquals(node("[1, {a: b}]"), node("- 1\n- a: b\n"))

  test "mapping members":
    check summary("{a: 1, b: 2, c: 3}", "{a: 1, b: 20, d: 4}") == @[
      "changed /b /b", "removed /c /c", "added /d /d"]

  test "types and tags":
    check summary("a: 1", "a: '1'") == @["changed /a /a"]
    check summary("a: !Ref x", "a: x") == @["changed /a /a"]
    check summary("a: !Ref x", "a: !Sub x") == @["changed /a /a"]
    check summary("a: [1]", "a: {b: 1}") == @["changed /a /a"]
    check summary("a: !!str x", "a: x").len == 0

  test "nested changes":
    check summary("a: {b: {c: 1, d: 2}}", "a: {b: {c: 1, d: 3}}") == @[
      "changed /a/b/d /a/b/d"]

  test "the root":
    check summary("1", "2") == @["changed  "]
    check summary("[1]", "{a: 1}") == @["changed  "]

  test "sequence insertions and removals keep the other items":
    check summary("[a, b, c]", "[a, x, b, c]") == @["added /1 /1"]
    check summary("[a, b, c]", "[a, c]") == @["removed /1 /1"]
    check summary("[a, b, c, d]", "[b, c, d, e]") == @[
      "removed /0 /0", "added /4 /3"]

  test "replaced sequence items are changes within them":
    check summary("- {name: a, port: 1}\n- {name: b, port: 2}\n",
        "- {name: a, port: 1}\n- {name: b, port: 3}\n") == @[
      "changed /1/port /1/port"]
    check summary("[a, b, c]", "[a, x, y, c]") == @[
      "changed /1 /1", "added /2 /2"]

  test "paths on both sides":
    let changes = diff(node("[x, a, {k: 1}]"), node("[a, {k: 2}]"))
    check changes.len == 2
    check changes[0].kind == dkRemoved
    check changes[0].oldPath.toJsonPointer == "/0"
    check changes[1].oldPath.toJsonPointer == "/2/k"
    check changes[1].newPath.toJsonPointer == "/1/k"
    check changes[1].oldNode.content == "1"
    check changes[1].newNode.content == "2"

  test "JSON Paths":
    let path = @[nameSegment("a"), indexSegment(0), nameSegment("b c"),
        nameSegment("~/")]
    check path.toJsonPath == "$.a[0]['b c']['~/']"
    check path.toJsonPointer == "/a/0/b c/~0~1"

  test "collection keys":
    check summary("? [a, b]\n: 1\n", "? [a, b]\n: 2\n") == @[
      "changed /[a, b] /[a, b]"]
    check summary("? [a, b]\n: 1\n", "? [a, c]\n: 1\n") == @[
      "removed /[a, b] /[a, b]", "added /[a, c] /[a, c]"]
    # not the same as a string key with the same text
    check summary("? [a]\n: 1\n", "\"[a]\": 1\n") == @[
      "removed /[a] /[a]", "added /[a] /[a]"]

  test "cyclic graphs":
    check summary("&a [*a, 1]", "&b [*b, 1]").len == 0
    check summary("&a [*a, 1]", "&b [*b, 2]") == @["changed /1 /1"]

  test "flow text":
    check flowText(node("{a: [1, 2], b: 'x y'}")) in
        ["{a: [1, 2], b: x y}", "{a: [1, 2], b: 'x y'}", "{a: [1,2], b: x y}"]
    check flowText(node("'80'")) != "80"

  test "JSON Patches":
    let patch = toJsonPatch(diff(node("{a: [x, y], b: 1}"),
        node("{a: [x, z, y], c: 2}")))
    var ops: seq[string]
    for op in patch.elems: ops.add(op["op"].content & " " & op["path"].content)
    check ops == @["add /c", "remove /b", "add /a/1"]
    check patch.elems[0]["value"].content == "2"

  test "JSON Patches round-trip":
    for (old, new) in [
        ("[a, b, c, d, e]", "[e, d, c, b, a]"),
        ("[1, 2, 3]", "[]"),
        ("[]", "[1, 2, 3]"),
        ("[a, b, a, b]", "[b, a, b, a, c]"),
        ("{a: [1, {b: [2, 3]}], c: d}", "{a: [{b: [3, 2]}, 1], e: f}"),
        ("[[1, 2], [3]]", "[[1], [3, 4], 5]"),
        ("x", "{a: 1}")]:
      checkpoint(old & " -> " & new)
      check roundTrips(node(old), node(new))

for file in ["tests.json", "spec_tests.json"]:
  suite "diffs of the JSON Patch test suite: " & file:
    let records = parseFile(currentSourcePath.parentDir / "json-patch-tests" /
        file)
    for i, record in records.elems:
      if not record.hasKey("expected") or
          record.getOrDefault("disabled").getBool(false):
        continue
      test $i & ": " & record{"comment"}.getStr():
        let testCase = node($record)
        check roundTrips(testCase["doc"], testCase["expected"])
