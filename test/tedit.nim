#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/unittest
import ../yaml/[edit, jsonpath, presenter]

proc assigned(source, path, value: string, json = false): string =
  assign(source, parseJsonPath(path), value, json = json).text

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
