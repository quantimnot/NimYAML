#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml/[ parser, stream, tojson, loading, dumping]

when defined(nimPreviewSlimSystem):
  import std/assertions

import unittest, json, streams, options

type
  JsoncConfig = object
    name: string
    ports: seq[int]
    debug: bool

  Record = object
    kind: string
    count: int

proc ensureEqual(yamlIn, jsonIn: string) =
  try:
    var
      yamlParser = initYamlParser(true)
      s = yamlParser.parse(yamlIn)
      yamlResult = constructJson(s)
      jsonResult = parseJson(jsonIn)
    assert yamlResult.len == 1
    assert(jsonResult == yamlResult[0], "Expected: " & $jsonResult & ", got: " &
        $yamlResult[0])
  except YamlStreamError as se:
    let e = (ref YamlParserError)(se.parent)
    echo "error occurred: " & e.msg
    echo "line: ", e.mark.line, ", column: ", e.mark.column
    echo e.lineContent
    raise e

suite "Constructing JSON":
  test "Simple Sequence":
    ensureEqual("- 1\n- 2\n- 3", "[1, 2, 3]")

  test "Simple Map":
    ensureEqual("a: b\nc: d", """{"a": "b", "c": "d"}""")

  test "Complex Structure":
    ensureEqual("""
%YAML 1.2
---
Foo:
  - - a
    - b
    - c
  - bla: blubb
Numbers, bools, special values:
 - 1
 - true
 - ~
 - 42.23
 - FALSE
""", """{
"Foo": [
    [ "a", "b", "c"],
    { "bla": "blubb"}
],
"Numbers, bools, special values": [
    1, true, null, 42.23, false
]
}""")

suite "JSONC":
  const config = """{
  // the service
  "name": "web/*api*/", /* not a comment inside the string */
  "ports": [
    80, // http
    443, /* https */
  ],
  "debug": /* inline */ true,
}
"""

  test "Comments and trailing commas":
    let c = loadAsJsonc[JsoncConfig](config)
    check c.name == "web/*api*/"
    check c.ports == @[80, 443]
    check c.debug

  test "Stream input":
    let c = loadAsJsonc[JsoncConfig](newStringStream(config))
    check c.ports == @[80, 443]

  test "Slashes in strings are kept":
    check loadAsJsonc[seq[string]]("""["a//b", "c\"//d", "e\\", "/*f*/"] // g""") ==
      @["a//b", "c\"//d", "e\\", "/*f*/"]

  test "Comments are blanked in place":
    let input = "{\"a\": /* x\n y */ 1} // z\r\n"
    let stripped = stripJsonComments(input)
    check stripped == "{\"a\":     \n      1}     \r\n"
    check stripped.len == input.len

  test "Error positions refer to the input":
    try:
      discard loadAsJsonc[JsoncConfig]("/* a */ {\"name\": \"x\",\n  /* b */ \"ports\": [1}")
      check false
    except YamlParserError as e:
      check e.mark.line == 2
      check e.mark.column == 22 # the stray '}'

  test "Unclosed block comment":
    try:
      discard stripJsonComments("[1,\n  2 /* three\n]")
      check false
    except YamlParserError as e:
      check e.mark.line == 2
      check e.mark.column == 5
      check e.lineContent == "  2 /* three\n    ^"

suite "JSON Lines":
  test "Loading":
    var events: seq[Record]
    loadJsonLines("""{"kind": "a", "count": 1}""" & "\r\n\n  \n" &
      """{"kind": "b\nc", "count": 2}""" & "\n", events)
    check events == @[Record(kind: "a", count: 1), Record(kind: "b\nc", count: 2)]

  test "Loading lazily from a stream":
    var counts: seq[int]
    for e in jsonLines[Record](newStringStream("{\"kind\": \"a\", \"count\": 1}\n{\"kind\": \"b\", \"count\": 2}")):
      counts.add(e.count)
    check counts == @[1, 2]

  test "Error lines refer to the input":
    var events: seq[Record]
    try:
      loadJsonLines("{\"kind\": \"a\", \"count\": 1}\n\n{\"kind\": \"b\", \"count\": [}\n", events)
      check false
    except YamlParserError as e:
      check e.mark.line == 3
      check e.mark.column == 25 # the stray '}'
    try:
      loadJsonLines("{\"kind\": \"a\", \"count\": 1}\n{\"kind\": \"b\", \"count\": \"x\"}\n", events)
      check false
    except YamlConstructionError as e:
      check e.mark.line == 2

  test "Dumping":
    let events = @[Record(kind: "a", count: 1), Record(kind: "b\nc", count: 2)]
    let output = jsonLinesDumper().dumpJsonLines(events)
    check output == "{\"kind\": \"a\", \"count\": 1}\n{\"kind\": \"b\\nc\", \"count\": 2}\n"
    var loaded: seq[Record]
    loadJsonLines(output, loaded)
    check loaded == events

  test "Dumping with any dumper takes one line per value":
    var d = jsonDumper()
    d.presentation.maxLineLength = some(10)
    check d.dumpJsonLines(@[Record(kind: "a long kind", count: 1)]) ==
      "{\"kind\": \"a long kind\", \"count\": 1}\n"
    check Dumper().dumpJsonLines(@[@["x", "y"], @["z"]]) == "[x, y]\n[z]\n"

  test "Dumping no values":
    check jsonLinesDumper().dumpJsonLines(newSeq[Record]()) == ""