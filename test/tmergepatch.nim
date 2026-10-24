#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/mergepatch. RFC 7396 has no test suite, but its Appendix A lists
# example patches with their results; those are the first suite, written in
# JSON as in the RFC. createMergePatch is checked by round-tripping the same
# examples. The rest covers YAML-specific keys and that inputs stay unchanged.

import std/[tables, unittest]
import "../yaml", "../yaml/dom", "../yaml/mergepatch", "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/assertions

proc node(yaml: string): YamlNode = loadAs[YamlNode](yaml)

const appendixA = [
  # (original, patch, result)
  ("""{"a":"b"}""", """{"a":"c"}""", """{"a":"c"}"""),
  ("""{"a":"b"}""", """{"b":"c"}""", """{"a":"b","b":"c"}"""),
  ("""{"a":"b"}""", """{"a":null}""", """{}"""),
  ("""{"a":"b","b":"c"}""", """{"a":null}""", """{"b":"c"}"""),
  ("""{"a":["b"]}""", """{"a":"c"}""", """{"a":"c"}"""),
  ("""{"a":"c"}""", """{"a":["b"]}""", """{"a":["b"]}"""),
  ("""{"a":{"b":"c"}}""", """{"a":{"b":"d","c":null}}""", """{"a":{"b":"d"}}"""),
  ("""{"a":[{"b":"c"}]}""", """{"a":[1]}""", """{"a":[1]}"""),
  ("""["a","b"]""", """["c","d"]""", """["c","d"]"""),
  ("""{"a":"b"}""", """["c"]""", """["c"]"""),
  ("""{"a":"foo"}""", """null""", """null"""),
  ("""{"a":"foo"}""", """"bar"""", """"bar""""),
  ("""{"e":null}""", """{"a":1}""", """{"e":null,"a":1}"""),
  ("""[1,2]""", """{"a":"b","c":null}""", """{"a":"b"}"""),
  ("""{}""", """{"a":{"bb":{"ccc":null}}}""", """{"a":{"bb":{}}}"""),
]

suite "RFC 7396 Appendix A":
  for (original, patch, expected) in appendixA:
    test original & " + " & patch:
      check jsonEquals(node(original).applyMergePatch(node(patch)),
          node(expected))

  # The RFC's example document from Section 3.
  test "Section 3 example":
    let
      original = node("""
title: Goodbye!
author: {givenName: John, familyName: Doe}
tags: [example, sample]
content: This will be unchanged
""")
      patch = node("""
title: Hello!
phoneNumber: +01-123-456-7890
author: {familyName: null}
tags: [example]
""")
    check jsonEquals(original.applyMergePatch(patch), node("""
title: Hello!
author: {givenName: John}
tags: [example]
content: This will be unchanged
phoneNumber: +01-123-456-7890
"""))

suite "createMergePatch":
  for (original, patch, expected) in appendixA:
    let (source, target) = (node(original), node(expected))
    # a null member of the target cannot be produced by a merge patch
    if target.kind == yMapping and not isNil(target.member("e")): continue
    test original & " -> " & expected:
      check jsonEquals(source.applyMergePatch(createMergePatch(source, target)),
          target)

  test "unchanged members are left out":
    check jsonEquals(createMergePatch(node("{a: 1, b: {c: 2, d: 3}}"),
        node("{a: 1, b: {c: 2, d: 4}, e: 5}")), node("{b: {d: 4}, e: 5}"))

  test "removed members become null":
    check jsonEquals(createMergePatch(node("{a: 1, b: 2}"), node("{a: 1}")),
        node("{b: null}"))

suite "Merge patches on YAML":
  test "inputs are never changed":
    let
      target = node("{a: {b: 1}, c: 2}")
      patch = node("{a: {b: null, x: 1}, c: null}")
    check jsonEquals(target.applyMergePatch(patch), node("{a: {x: 1}}"))
    check jsonEquals(target, node("{a: {b: 1}, c: 2}"))
    check jsonEquals(patch, node("{a: {b: null, x: 1}, c: null}"))

  test "unchanged members are shared":
    let
      target = node("{a: {b: 1}, c: 2}")
      patched = target.applyMergePatch(node("{c: 3}"))
    check cast[pointer](patched["a"]) == cast[pointer](target["a"])

  test "non-string keys are kept":
    let patched = node("{1: one, a: 1}").applyMergePatch(node("{a: null}"))
    check patched.fields.len == 1
    check patched[newYamlNode("1")].content == "one"

  test "tags decide what is null":
    let patched = node("{a: 1, b: 2}").applyMergePatch(
        node("{a: ~, b: \"null\"}"))
    check jsonEquals(patched, node("{b: \"null\"}"))

  test "new keys stay strings":
    let patched = node("{}").applyMergePatch(node("{\"1\": one}"))
    for key in patched.fields.keys: check key.isStringKey
