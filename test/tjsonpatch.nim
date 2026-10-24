#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/jsonpatch. The JSON Patch test suite (a git submodule) defines
# conformance to RFC 6902 on JSON documents. Two of its records, both
# disabled, contain duplicate member names, which NimYAML rightly refuses to
# load; so the files are split into records with std/json, and each record
# is loaded with NimYAML, as the YamlNode graph the patch runs on. The
# remaining tests cover what the suite cannot: aliases, YAML-only keys, and
# that the input is never changed.

import std/[json, os, tables, unittest]
import "../yaml", "../yaml/dom", "../yaml/jsonpatch", "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

proc node(yaml: string): YamlNode = loadAs[YamlNode](yaml)

for file in ["tests.json", "spec_tests.json"]:
  suite "JSON Patch test suite: " & file:
    let records = parseFile(currentSourcePath.parentDir / "json-patch-tests" /
        file)
    for i, record in records.elems:
      if not record.hasKey("patch") or
          record.getOrDefault("disabled").getBool(false):
        continue
      let name = $i & ": " & record{"comment"}.getStr(record{"error"}.getStr)
      test name:
        let testCase = node($record)
        if testCase.hasKey("error"):
          expect YamlJsonPatchError:
            discard testCase["doc"].applyJsonPatch(testCase["patch"])
        else:
          let patched = testCase["doc"].applyJsonPatch(testCase["patch"])
          if testCase.hasKey("expected"):
            check jsonEquals(patched, testCase["expected"])

suite "JSON Patch on YAML":
  test "the document is never changed":
    let
      document = node("{a: {b: 1}, c: [1, 2]}")
      before = node("{a: {b: 1}, c: [1, 2]}")
      patched = document.applyJsonPatch(node("""
- {op: add, path: /a/x, value: 2}
- {op: remove, path: /c/0}
- {op: move, from: /a/b, path: /d}
"""))
    check jsonEquals(document, before)
    check jsonEquals(patched, node("{a: {x: 2}, c: [2], d: 1}"))

  test "a failing patch leaves the document as it was":
    let document = node("{a: 1}")
    expect YamlJsonPatchError:
      discard document.applyJsonPatch(node("""
- {op: add, path: /b, value: 2}
- {op: test, path: /a, value: 2}
"""))
    check jsonEquals(document, node("{a: 1}"))

  test "unchanged subtrees are shared with the input":
    let
      document = node("{a: {b: 1}, c: {d: 2}}")
      patched = document.applyJsonPatch(node("[{op: add, path: /a/x, value: 3}]"))
    check patched["c"] == document["c"]
    check cast[pointer](patched["c"]) == cast[pointer](document["c"])
    check cast[pointer](patched["a"]) != cast[pointer](document["a"])

  test "aliases are separate values":
    let
      document = node("{a: &x {v: 1}, b: *x}")
      patched = document.applyJsonPatch(node("[{op: replace, path: /a/v, value: 2}]"))
    check jsonEquals(patched, node("{a: {v: 2}, b: {v: 1}}"))
    check jsonEquals(document, node("{a: {v: 1}, b: {v: 1}}"))

  test "copies are separate values":
    let patched = node("{a: {v: 1}}").applyJsonPatch(node("""
- {op: add, path: /a/w, value: 2}
- {op: copy, from: /a, path: /b}
- {op: replace, path: /b/v, value: 3}
- {op: remove, path: /a/w}
"""))
    check jsonEquals(patched, node("{a: {v: 1}, b: {v: 3, w: 2}}"))

  test "copying a location into itself":
    # the source was copied by the first operation, so the patch owns it
    let patched = node("{a: {y: 0}}").applyJsonPatch(node("""
- {op: add, path: /a/x, value: 1}
- {op: copy, from: /a, path: /a/b}
"""))
    check jsonEquals(patched, node("{a: {y: 0, x: 1, b: {y: 0, x: 1}}}"))
    check cast[pointer](patched["a"]["b"]) != cast[pointer](patched["a"])
    let root = node("{a: 1}").applyJsonPatch(node("""
- {op: add, path: /b, value: 2}
- {op: copy, from: "", path: /c}
"""))
    check jsonEquals(root, node("{a: 1, b: 2, c: {a: 1, b: 2}}"))

  test "new keys stay strings":
    let patched = node("{}").applyJsonPatch(node("""
- {op: add, path: /1, value: one}
- {op: add, path: /true, value: yes}
- {op: add, path: /name, value: n}
"""))
    check jsonEquals(patched, node("""{"1": one, "true": yes, name: n}"""))
    check patched.fields.len == 3
    for key in patched.fields.keys: check key.isStringKey

  test "keys keep their style":
    let patched = node("{'a': 1}").applyJsonPatch(
        node("[{op: replace, path: /a, value: 2}]"))
    for key in patched.fields.keys:
      check key.scalarStyle == ssSingleQuoted

  test "remove drops every spelling of a name":
    let patched = node("{a: 1, \"a\": 2, b: 3}").applyJsonPatch(
        node("[{op: remove, path: /a}]"))
    check patched.fields.len == 1

  test "non-string keys are invisible but kept":
    let document = node("{0: zero, a: 1}")
    expect YamlJsonPatchError:
      discard document.applyJsonPatch(node("[{op: remove, path: /0}]"))
    let patched = document.applyJsonPatch(node("[{op: add, path: /b, value: 2}]"))
    check patched.fields.len == 3
    check patched[newYamlNode("0")].content == "zero"

  test "tags decide what test compares":
    let document = node("{n: 1, s: \"1\", f: !!float 1}")
    discard document.applyJsonPatch(node("""
- {op: test, path: /n, value: 1.0}
- {op: test, path: /f, value: 1}
- {op: test, path: /s, value: "1"}
"""))
    expect YamlJsonPatchError:
      discard document.applyJsonPatch(node("[{op: test, path: /s, value: 1}]"))

  test "error kinds":
    let document = node("{a: [1]}")
    template kindOf(patch: string): JsonPatchErrorKind =
      var kind = jpeInvalidPatch
      try: discard document.applyJsonPatch(node(patch))
      except YamlJsonPatchError as e: kind = e.kind
      kind
    check kindOf("{op: add}") == jpeInvalidPatch
    check kindOf("[{op: frobnicate, path: /a}]") == jpeInvalidPatch
    check kindOf("[{op: add, path: a, value: 1}]") == jpeInvalidPatch
    check kindOf("[{op: add, path: /a/5, value: 1}]") == jpeInvalidLocation
    check kindOf("[{op: remove, path: /b}]") == jpeInvalidLocation
    check kindOf("[{op: test, path: /a/0, value: 2}]") == jpeTestFailed
    try:
      discard document.applyJsonPatch(node("[{op: test, path: /a, value: [1]}, {op: remove, path: /x}]"))
    except YamlJsonPatchError as e:
      check e.operation == 1

  test "parsed patches apply to many documents":
    let patch = parseJsonPatch(node("[{op: add, path: /seen, value: true}]"))
    for document in [node("{}"), node("{seen: false}")]:
      check jsonEquals(document.applyJsonPatch(patch), node("{seen: true}"))
