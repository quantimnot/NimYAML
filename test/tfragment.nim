#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml", "../yaml/fragment"
import unittest, streams

when defined(nimPreviewSlimSystem):
  import std/assertions

const
  # RFC 9512, Figure 1
  twoDocs = """
%YAML 1.2
---
one: &foo scalar
two: &bar
  - some
  - sequence
  - items
...
%YAML 1.2
---
&document_2
one: &foo [a, sequence]
"""
  # RFC 9512, Figure 6
  unreferenceable = """
%YAML 1.2
---
a-map-cannot:
  ? {be: expressed}
  : with a JSON Pointer

0: no numeric mapping keys in JSON
"""
  # RFC 9512, Figure 8
  cyclic = """
%YAML 1.2
---
anchor: &anchor
  baz: you
foo: &foo
  bar: *anchor
  bat: *foo
"""
  # RFC 9512, Figure 9
  merge = """
%YAML 1.1
---
the-viceroys: &the-viceroys
  title: The Viceroys
  author:
    given_name: Federico
    family_name: De Roberto
book:
  <<: *the-viceroys
  title: The Illusion
"""
  pointers = """
a/b: slash
m~n: tilde
a b: space
"0": quoted zero
s: [x, y, z]
'': empty key
"""

suite "Fragment identifiers (RFC 9512)":
  test "Empty fragment references the root node":
    let root = resolveFragment("a: 1", "")
    check root.kind == yMapping
    check resolveFragment("a: 1", "#").kind == yMapping

  test "JSON Pointer into mappings and sequences":
    check resolveFragment(pointers, "/s/1").content == "y"
    check resolveFragment(pointers, "#/s/0").content == "x"
    check resolveFragment(pointers, "/s").len == 3

  test "JSON Pointer escapes and percent-encoding":
    check resolveFragment(pointers, "/a~1b").content == "slash"
    check resolveFragment(pointers, "/m~0n").content == "tilde"
    check resolveFragment(pointers, "/a%20b").content == "space"
    check resolveFragment(pointers, "/").content == "empty key"
    expect YamlFragmentError: discard resolveFragment(pointers, "/m~2n")
    expect YamlFragmentError: discard resolveFragment(pointers, "/a%2")
    expect YamlFragmentError: discard resolveFragment(pointers, "/a%zzb")

  test "Quoted string keys are referenceable":
    check resolveFragment(pointers, "/0").content == "quoted zero"
    check resolveFragment("!!str 0: tagged", "/0").content == "tagged"

  test "Invalid sequence indexes":
    for index in ["01", "-", "3", "x", "", "99999999999999999999999"]:
      expect YamlFragmentError: discard resolveFragment(pointers, "/s/" & index)

  test "Cannot descend into scalars":
    expect YamlFragmentError: discard resolveFragment(pointers, "/s/0/x")

  test "Nodes not interoperable with JSON are unreferenceable (Figure 6)":
    check resolveFragment(unreferenceable, "/a-map-cannot").kind == yMapping
    expect YamlFragmentError:
      discard resolveFragment(unreferenceable, "/a-map-cannot/be")
    expect YamlFragmentError: discard resolveFragment(unreferenceable, "/0")

  test "Numeric plain key is not a string key (Figure 7)":
    expect YamlFragmentError:
      discard resolveFragment("0: \"JSON Pointer `#/0` references a string mapping key.\"", "/0")
    for key in ["null", "true", "1.5", "~"]:
      expect YamlFragmentError: discard resolveFragment(key & ": v", "/" & key)
    check resolveFragment("2001-12-14: v", "/2001-12-14").content == "v"

  test "JSON Pointer traverses alias nodes and cycles (Figure 8)":
    check resolveFragment(cyclic, "/foo/bar/baz").content == "you"
    check resolveFragment(cyclic, "/foo/bat/bat/bat/bar/baz").content == "you"
    let root = loadAs[YamlNode](cyclic)
    check resolvePointer(root, "/foo/bat") == resolvePointer(root, "/foo")
    check cast[pointer](resolvePointer(root, "/foo/bar")) ==
        cast[pointer](resolvePointer(root, "/anchor"))

  test "Merge keys are not applied (Figure 9)":
    check resolveFragment(merge, "/book/title").content == "The Illusion"
    check resolveFragment(merge, "/book/<</author/given_name").content == "Federico"
    expect YamlFragmentError: discard resolveFragment(merge, "/book/author")

  test "JSON Pointer requires a single-document stream":
    expect YamlFragmentError: discard resolveFragment(twoDocs, "")
    expect YamlFragmentError: discard resolveFragment(twoDocs, "/one")
    expect YamlFragmentError: discard resolveFragment("", "")

  test "Alias node fragments (Figure 1)":
    check resolveFragment(twoDocs, "*foo").content == "scalar"
    check resolveFragment(twoDocs, "#*bar").len == 3
    let doc2 = resolveFragment(twoDocs, "*document_2")
    check doc2.kind == yMapping
    check doc2["one"].len == 2
    expect YamlFragmentError: discard resolveFragment(twoDocs, "*missing")

  test "Alias node fragment selects the first of redefined anchors":
    const input = "a: &x 1\nb: &x 2\nc: *x\nd: [&y 3, *y]\n"
    check resolveFragment(input, "*x").content == "1"
    check resolveFragment(input, "*y").content == "3"
    check loadAs[YamlNode](input)["c"].content == "2"

  test "Alias node fragment on a cyclic node":
    let node = resolveFragment("a: &r [1, *r]", "*r")
    check node.kind == ySequence
    check cast[pointer](node[1]) == cast[pointer](node)

  test "Alias node fragment with percent-encoded name":
    check resolveFragment("a: &%C3%A4 umlaut", "*%25C3%25A4").content == "umlaut"
    check resolveFragment("a: &ä umlaut", "*%C3%A4").content == "umlaut"

  test "Resolving from a Stream":
    check resolveFragment(newStringStream(twoDocs), "*document_2").len == 1
    check resolveFragment(newStringStream(cyclic), "/anchor/baz").content == "you"

  test "Unsupported fragment syntax":
    for fragment in ["foo", "$.a", "#foo"]:
      expect YamlFragmentError: discard resolveFragment(pointers, fragment)
    expect YamlFragmentError: discard resolvePointer(loadAs[YamlNode]("a"), "a")

  test "Parser errors propagate":
    expect YamlParserError: discard resolveFragment("a: [", "/a")
    expect YamlParserError: discard resolveFragment("a: [", "*a")

type Item = object
  name: string
  count: int

suite "Multi-document dumping":
  test "Dumping values as separate documents":
    check Dumper().dumpMultiDoc(@[Item(name: "a", count: 1),
        Item(name: "b", count: 2)]) ==
        "name: a\ncount: 1\n...\nname: b\ncount: 2\n"

  test "Dumping no documents":
    check Dumper().dumpMultiDoc(newSeq[int]()) == ""

  test "Round-trip with loadMultiDoc":
    let items = @[Item(name: "x", count: 3), Item(name: "y", count: 4),
        Item(name: "z", count: 5)]
    var loaded: seq[Item]
    loadMultiDoc(blockOnlyDumper().dumpMultiDoc(items), loaded)
    check loaded == items

  test "Round-trip of DOM documents with anchors":
    const input = "a: &x [1]\nb: *x\n---\nc: &x [2]\nd: *x\n"
    var docs: seq[YamlNode]
    loadMultiDoc(input, docs)
    var reloaded: seq[YamlNode]
    loadMultiDoc(Dumper().dumpMultiDoc(docs), reloaded)
    check reloaded.len == 2
    check cast[pointer](reloaded[0]["a"]) == cast[pointer](reloaded[0]["b"])
    check cast[pointer](reloaded[1]["c"]) == cast[pointer](reloaded[1]["d"])
    check reloaded[1]["d"][0].content == "2"

  test "Dumping into a Stream":
    let s = newStringStream()
    Dumper().dumpMultiDoc([1, 2], s)
    var loaded: seq[int]
    loadMultiDoc(s.data, loaded)
    check loaded == @[1, 2]
