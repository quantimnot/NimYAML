#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, streams, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[edit, jsonpath, presenter, source, memory]

let tmp = getTempDir() / ("tedit-" & $getCurrentProcessId())
createDir(tmp)

proc fromSources(source, path, value: string, json: bool,
    document = -1): seq[tuple[text: string, count: int, error: string]] =
  ## `assign` of ``source`` read from a `YamlSource`: in memory, and as a
  ## file read by seeking.
  writeFile(tmp / "in.yaml", source)
  for src in [sourceOf(source), openSource(tmp / "in.yaml",
      newMemoryBudget(1 shl 20), SourcePolicy(choice: tcSeek,
      pageCache: 8192))]:
    let output = newStringStream()
    try:
      let count = assign(src, parseJsonPath(path), value, output,
          json = json, document = document)
      result.add((output.data, count, ""))
    except CatchableError as e: result.add(("", 0, $e.name))
    src.close()

proc assigned(source, path, value: string, json = false): string =
  ## `assign` of ``source``, which must give the same when it reads
  ## ``source`` from a `YamlSource`
  var expected: tuple[text: string, count: int, error: string]
  try:
    let (text, count) = assign(source, parseJsonPath(path), value, json = json)
    expected = (text, count, "")
  except CatchableError as e: expected = ("", 0, $e.name)
  for r in fromSources(source, path, value, json): check r == expected
  if expected.error.len > 0:
    raise newException(YamlEditError, expected.error)
  expected.text

suite "edit: from a source":
  test "documents one at a time":
    let source = "# head\n%YAML 1.2\n--- # one\na: 1\n...\n# between\n" &
        "--- !!map\na: [2, 3]  # two\nb: x\n--- \na: {c: 4}\n# tail\n"
    for document in [-1, 0, 1, 2]:
      let expected = assign(source, parseJsonPath("$.a"), "[z]",
          document = document)
      for r in fromSources(source, "$.a", "[z]", false, document):
        check r == (expected.text, expected.count, "")

  test "nothing selected copies the source":
    let source = "a: 1\n---\nb: 2\n"
    for r in fromSources(source, "$.z", "1", false):
      check r == (source, 0, "")

suite "edit":
  test "only the selected node changes":
    let source = "# head\n\na:   1  # why\nb: [x, 'y']\n"
    check assigned(source, "$.a", "2") ==
        "# head\n\na:   2  # why\nb: [x, 'y']\n"
    check assigned(source, "$.b[1]", "{c: [1, 2]}") ==
        "# head\n\na:   1  # why\nb: [x, {c: [1, 2]}]\n"
    check assign(source, parseJsonPath("$.z"), "1") == (source, 0)

  test "each selected node":
    check assigned("- c: 1\n- c: 2  # two\n", "$..c", "[1]") ==
        "- c: [1]\n- c: [1]  # two\n"
    check assigned("a: [{k: a=b, v: 1}, {k: c, v: 2}]\n",
        "$.a[?@.k == 'a=b'].v", "0") == "a: [{k: a=b, v: 0}, {k: c, v: 2}]\n"

  test "quoted strings that would read as other types stay quoted":
    check assigned("a: x\n", "$.a", "\"1\"") == "a: \"1\"\n"
    check assigned("a: x\n", "$.a", "'true'") == "a: \"true\"\n"
    check assigned("a: [x]\n", "$.a[0]", "\"~\"") == "a: [\"~\"]\n"
    check assigned("a: x\n", "$.a", "\"2001-01-01\"") == "a: \"2001-01-01\"\n"

  test "values in flow context are flow-safe":
    check assigned("a: [x]\n", "$.a[0]", "'p, q'") == "a: [\"p, q\"]\n"
    check assigned("a: [x]\n", "$.a[0]", "|\n  l1\n  l2\n") ==
        "a: [\"l1\\nl2\\n\"]\n"
    check assigned("a: x\n", "$.a", "!!str 3") == "a: !!str 3\n"

  test "block collections":
    let source = "a:\n  b: 1  # one\n  c:\n    - x\n    - y\n# end\nd: 2\n"
    check assigned(source, "$.a.c", "[p, {q: 1, r: 2}]") ==
        "a:\n  b: 1  # one\n  c:\n    - p\n    - q: 1\n      r: 2\n" &
        "# end\nd: 2\n"
    check assigned(source, "$.a.c", "5") ==
        "a:\n  b: 1  # one\n  c: 5\n# end\nd: 2\n"
    check assigned(source, "$.a.c", "[]") ==
        "a:\n  b: 1  # one\n  c: []\n# end\nd: 2\n"
    # an indentless sequence replaced by a mapping is indented
    check assigned("a:\n- x\n- y\nb: 1\n", "$.a", "{p: 1, q: [1, 2]}") ==
        "a:\n  p: 1\n  q: [1, 2]\nb: 1\n"
    check assigned("- - x\n  - y\n- z\n", "$[0]", "{p: 1, q: 2}") ==
        "- p: 1\n  q: 2\n- z\n"

  test "the README example":
    check assign("a: 1  # why\nb:\n  - x\n", parseJsonPath("$.b"),
        "[p, {q: 1}]") == ("a: 1  # why\nb:\n  - p\n  - q: 1\n", 1)

  test "multi-line strings in block scalars stay blocks":
    let source = "a: |  # c\n    x\n\n    y\nb: 1\n"
    check assigned(source, "$.a", "\"p\\nq\\n\"") ==
        "a: |  # c\n    p\n    q\nb: 1\n"
    check assigned(source, "$.a", "\"p\\n\\n  q\"") ==
        "a: |-  # c\n    p\n\n      q\nb: 1\n"
    check assigned("- >-\n  x\n- 1\n", "$[0]", "\"p\\nq\\n\"") ==
        "- |\n  p\n  q\n- 1\n"
    # one line, kept line breaks and leading spaces are written in a line
    check assigned(source, "$.a", "\"p\"") == "a: p\nb: 1\n"
    check assigned("a: |+\n  x\n\nb: 1\n", "$.a", "\"p\\nq\\n\"") ==
        "a: \"p\\nq\\n\"\n\nb: 1\n"
    check assigned(source, "$.a", "\"p\\nq\\n\\n\"") ==
        "a: \"p\\nq\\n\\n\"\nb: 1\n"
    check assigned(source, "$.a", "\" p\\nq\"") == "a: \" p\\nq\"\nb: 1\n"

  test "block scalars":
    check assigned("a: |\n  x\n\nb: 2\n", "$.a", "y") == "a: y\n\nb: 2\n"

  test "empty nodes":
    check assigned("a:\nb: 1\n", "$.a", "2") == "a: 2\nb: 1\n"
    check assigned("a:  # c\nb: 1\n", "$.a", "2") == "a: 2  # c\nb: 1\n"
    check assigned("- \n- x\n", "$[0]", "2") == "- 2\n- x\n"
    check assigned("- x\n-\n", "$[1]", "2") == "- x\n- 2\n"

  test "properties: the anchor stays, the tag goes":
    check assigned("a: &x !!str 1\nb: *x\n", "$.a", "2") == "a: &x 2\nb: *x\n"
    check assigned("a: &x !!map\n  k: 1\nb: *x\n", "$.a", "5") ==
        "a: &x\n  5\nb: *x\n"

  test "aliases":
    let source = "a: &x {k: 1}\nb: *x\n"
    # the alias itself is replaced
    check assigned(source, "$.b", "2") == "a: &x {k: 1}\nb: 2\n"
    # through an alias, the anchored node is edited
    check assigned(source, "$.b.k", "2") == "a: &x {k: 2}\nb: *x\n"
    # anchors of the value do not take those of the document
    check assigned("a: &a 1\nb: [x]\nc: *a\n", "$.b[0]", "[&a v, *a]") ==
        "a: &a 1\nb: [[&a1 v, *a1]]\nc: *a\n"

  test "documents":
    check assigned("a: 1\n---\na: 2\n", "$.a", "3") == "a: 3\n---\na: 3\n"
    check assigned("--- # c\n", "$", "[1]") == "--- [1] # c\n"

  test "json and jsonc":
    check assigned("{\"a\": 1, \"b\": [true]}\n", "$.b[0]", "{c: x, d: ~}",
        json = true) == "{\"a\": 1, \"b\": [{\"c\": \"x\", \"d\": null}]}\n"
    check assigned("{\n  // c\n  \"a\": 1, /* d */ \"b\": 2,\n}\n", "$.b",
        "[1]", json = true) ==
        "{\n  // c\n  \"a\": 1, /* d */ \"b\": [1],\n}\n"

  test "line breaks of the source":
    check assigned("a:\r\n  - x\r\nb: 1\r\n", "$.a", "{p: 1, q: 2}") ==
        "a:\r\n  p: 1\r\n  q: 2\r\nb: 1\r\n"

  test "errors":
    expect YamlEditError: discard assigned("a: 1\n", "$.a", "[")
    # the anchor of a replaced node is gone, but an alias needs it
    expect YamlEditError:
      discard assigned("a: {k: &x 1}\nb: *x\n", "$.a", "2")

  test "one document":
    let source = "a: 1\n---\na: 2\n"
    check assign(source, parseJsonPath("$.a"), "3", document = 1) ==
        ("a: 1\n---\na: 3\n", 1)
    check assign(source, parseJsonPath("$.a"), "3", document = 2) ==
        (source, 0)

proc renamed(source, path, name: string, json = false): string =
  rename(source, parseJsonPath(path), name, json = json).text

suite "rename":
  test "only the key changes":
    let source = "# head\na:   1  # why\nb:\n  c: [x]\n"
    check renamed(source, "$.a", "z") == "# head\nz:   1  # why\nb:\n  c: [x]\n"
    check renamed(source, "$.b.c", "d e") ==
        "# head\na:   1  # why\nb:\n  d e: [x]\n"
    # the presenter chooses the style of the new name
    check renamed("{a: 1, 'b': 2}\n", "$.b", "c") == "{a: 1, c: 2}\n"
    check rename(source, parseJsonPath("$.z"), "y") == (source, 0)
    check renamed(source, "$.a", "a") == source

  test "names that would not read as strings are quoted":
    check renamed("a: 1\n", "$.a", "1") == "\"1\": 1\n"
    check renamed("a: 1\n", "$.a", "x: y") == "\"x: y\": 1\n"
    check renamed("a: 1\n", "$.a", "true") == "\"true\": 1\n"
    check renamed("a: 1\n", "$.a", "") == "\"\": 1\n"

  test "properties of the key stay":
    check renamed("!!str a: 1\n", "$.a", "b") == "!!str b: 1\n"

  test "through an alias, the anchored mapping is edited":
    check renamed("a: &x {k: 1}\nb: *x\n", "$.b.k", "j") ==
        "a: &x {j: 1}\nb: *x\n"

  test "documents":
    let source = "a: 1\n---\na: 2\n"
    check renamed(source, "$.a", "b") == "b: 1\n---\nb: 2\n"
    check rename(source, parseJsonPath("$.a"), "b", document = 0) ==
        ("b: 1\n---\na: 2\n", 1)

  test "json":
    check renamed("{\"a\": 1}\n", "$.a", "b\"c", json = true) ==
        "{\"b\\\"c\": 1}\n"

  test "errors":
    # not a member
    expect YamlEditError: discard renamed("[1]\n", "$[0]", "b")
    expect YamlEditError: discard renamed("a: 1\n", "$", "b")
    # the mapping has a member of that name
    expect YamlEditError: discard renamed("a: 1\nb: 2\n", "$.a", "b")
