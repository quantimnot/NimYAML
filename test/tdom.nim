#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"
import unittest, commonTestUtils, streams, tables, times
when defined(nimPreviewSlimSystem):
  import std/assertions

suite "DOM":
  test "Composing redefined anchor":
    let result = loadAs[YamlNode]("a: &x 1\nb: &x 2\nc: *x\n")
    assert result["a"].content == "1"
    assert result["c"].content == "2"
    assert cast[pointer](result["b"]) == cast[pointer](result["c"])
  test "Cyclic node equals itself":
    let result = loadAs[YamlNode]("&a [b, *a]")
    assert result == result
    assert result[1] == result
  test "Equality is structural":
    check loadAs[YamlNode]("{a: [1, {b: c}]}") ==
        loadAs[YamlNode]("{a: [1, {b: c}]}")
    check loadAs[YamlNode]("[x]") != loadAs[YamlNode]("[y]")
    check loadAs[YamlNode]("[x]") != loadAs[YamlNode]("[!!str x]")
    check loadAs[YamlNode]("{? [k]: v}") == loadAs[YamlNode]("{? [k]: v}")
    check loadAs[YamlNode]("[&x [1], *x]") == loadAs[YamlNode]("[[1], [1]]")
  test "Equal cyclic graphs":
    check loadAs[YamlNode]("&a [b, *a]") == loadAs[YamlNode]("&c [b, *c]")
    check loadAs[YamlNode]("&a [b, *a]") != loadAs[YamlNode]("&c [d, *c]")
  test "Collection keys are found by structure":
    let root = loadAs[YamlNode]("{? [k]: v}")
    check root[loadAs[YamlNode]("[k]")].content == "v"
  test "Equal mappings hash equally, whatever their insertion order":
    let
      a = newYamlNode([(newYamlNode("x"), newYamlNode("1")),
          (newYamlNode("y"), newYamlNode("2")),
          (newYamlNode("z"), newYamlNode("3"))])
      b = newYamlNode([(newYamlNode("z"), newYamlNode("3")),
          (newYamlNode("y"), newYamlNode("2")),
          (newYamlNode("x"), newYamlNode("1"))])
    check a == b
    check hash(a) == hash(b)
  test "Mappings are represented in document order":
    var root = loadAs[YamlNode]("z: 1\na: 2\nm: 3\n")
    root[newYamlNode("b")] = newYamlNode("4")
    var keys: seq[string]
    for (key, value) in root.orderedFields: keys.add(key.content)
    check keys == @["z", "a", "m", "b"]
    check blockOnlyDumper().dump(root) == "z: 1\na: 2\nm: 3\nb: 4\n"
  test "Composing simple Scalar":
    let
      input  = newStringStream("scalar")
      result = loadAs[YamlNode](input)
    assert result.kind == yScalar
    assert result.content == "scalar"
    assert result.tag == yTagQuestionMark
  test "Serializing simple Scalar":
    let input = newYamlNode("scalar")
    var result = represent(input)
    ensure(result, startStreamEvent(), startDocEvent(), scalarEvent("scalar"),
        endDocEvent(), endStreamEvent())
  test "Composing sequence":
    let
      input = newStringStream("- !!str a\n- !!bool no")
      result = loadAs[YamlNode](input)
    assert result.kind == ySequence
    assert result.tag == yTagQuestionMark
    assert result.len == 2
    assert result[0].kind == yScalar
    assert result[0].tag == yTagString
    assert result[0].content == "a"
    assert result[1].kind == yScalar
    assert result[1].tag == yTagBoolean
    assert result[1].content == "no"
  test "Serializing sequence":
    let input = newYamlNode([
        newYamlNode("a", yTagString),
        newYamlNode("no", yTagBoolean)])
    var result = represent(input, SerializationOptions(tagStyle: tsAll))
    ensure(result, startStreamEvent(), startDocEvent(), startSeqEvent(),
           scalarEvent("a", yTagString), scalarEvent("no", yTagBoolean),
           endSeqEvent(), endDocEvent(), endStreamEvent())
  test "Composing mapping":
    let
      input = newStringStream("--- !!map\n!foo bar: [a, b]")
      result = loadAs[YamlNode](input)
    assert result.kind == yMapping
    assert result.tag == yTagMapping
    assert result.fields.len == 1
    for key, value in result.fields.pairs:
      assert key.kind == yScalar
      assert $key.tag  == "!foo"
      assert key.content == "bar"
      assert value.kind == ySequence
      assert value.len == 2
  test "Serializing mapping":
    let input = newYamlNode([
        (key: newYamlNode("bar"), value: newYamlNode([newYamlNode("a"),
                                                      newYamlNode("b")]))])
    var result = represent(input)
    ensure(result, startStreamEvent(), startDocEvent(), startMapEvent(),
        scalarEvent("bar"), startSeqEvent(), scalarEvent("a"), scalarEvent("b"),
        endSeqEvent(), endMapEvent(), endDocEvent(), endStreamEvent())
  test "Composing with anchors":
    let
      input = newStringStream("- &a foo\n- &b bar\n- *a\n- *b")
      result = loadAs[YamlNode](input)
    assert result.kind == ySequence
    assert result.len == 4
    assert result[0].kind == yScalar
    assert result[0].content == "foo"
    assert result[1].kind == yScalar
    assert result[1].content == "bar"
    assert cast[pointer](result[0]) == cast[pointer](result[2])
    assert cast[pointer](result[1]) == cast[pointer](result[3])
  test "Serializing with anchors":
    let
      a = newYamlNode("a")
      b = newYamlNode("b")
      input = newYamlNode([a, b, newYamlNode("c"), a, b])
    var result = represent(input)
    ensure(result, startStreamEvent(), startDocEvent(), startSeqEvent(),
           scalarEvent("a", anchor="a".Anchor),
           scalarEvent("b", anchor="b".Anchor), scalarEvent("c"),
           aliasEvent("a".Anchor), aliasEvent("b".Anchor), endSeqEvent(),
           endDocEvent(), endStreamEvent())
  test "Serializing with all anchors":
    let
      a = newYamlNode("a")
      input = newYamlNode([a, newYamlNode("b"), a])
    var result = represent(input, SerializationOptions(anchorStyle: asAlways))
    ensure(result, startStreamEvent(), startDocEvent(),
           startSeqEvent(anchor="a".Anchor),
           scalarEvent("a", anchor = "b".Anchor),
           scalarEvent("b", anchor="c".Anchor), aliasEvent("b".Anchor),
           endSeqEvent(), endDocEvent(), endStreamEvent())
  test "Deserialize parts of the input into YamlNode":
    let
      input = "a: b\nc: [d, e]"
    type Root = object
      a: string
      c: YamlNode
    var result = loadAs[Root](input)
    assert result.a == "b"
    assert result.c.kind == ySequence
    assert result.c.len == 2
    assert result.c[0].kind == yScalar
    assert result.c[0].content == "d"
    assert result.c[1].kind == yScalar
    assert result.c[1].content == "e"
  test "Serialize value that contains a YamlNode":
    type Root = object
      a: string
      c: YamlNode
    let value = Root(
      a: "b",
      c: newYamlNode([newYamlNode("d"), newYamlNode("e")]))
    var result = represent(value, SerializationOptions(tagStyle: tsNone))
    ensure(result, startStreamEvent(), startDocEvent(), startMapEvent(),
      scalarEvent("a"), scalarEvent("b"), scalarEvent("c"), startSeqEvent(),
      scalarEvent("d"), scalarEvent("e"), endSeqEvent(), endMapEvent(),
      endDocEvent(), endStreamEvent())
suite "DOM: large graphs":
  test "representing takes time linear in the nodes":
    proc graph(items: int): YamlNode =
      var text = "items:\n"
      for i in 0 ..< items: text.add("  - {k: " & $i & ", name: item}\n")
      load(text, result)
    proc representing(node: YamlNode): float =
      let start = cpuTime()
      for e in represent(node, SerializationOptions(tagStyle: tsAll)): discard
      cpuTime() - start
    discard representing(graph(200)) # warm up
    let
      small = representing(graph(1000))
      large = representing(graph(4000))
    # linear: about 4 times; quadratic: about 16 times
    check large < max(small, 0.001) * 8
