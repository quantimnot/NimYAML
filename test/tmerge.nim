#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/merge. The merge key specification has no test suite; its own
# example, where four spellings of the same mapping must come out equal, is
# the first test. The rest covers precedence, merge chains, the errors, and
# the two ways of loading native values with merge keys applied.

import std/[tables, unittest]
import "../yaml", "../yaml/dom", "../yaml/merge", "../yaml/parser"

when defined(nimPreviewSlimSystem):
  import std/assertions

proc merged(yaml: string): YamlNode =
  result = loadAs[YamlNode](yaml)
  result.applyMergeKeys()

proc node(yaml: string): YamlNode = loadAs[YamlNode](yaml)

suite "Merge keys":
  test "the example of the specification":
    let root = merged("""
- &CENTER { x: 1, y: 2 }
- &LEFT { x: 0, y: 2 }
- &BIG { r: 10 }
- &SMALL { r: 1 }

# All the following maps are equal:

- # Explicit keys
  x: 1
  y: 2
  r: 10
  label: center/big

- # Merge one map
  << : *CENTER
  r: 10
  label: center/big

- # Merge multiple maps
  << : [ *CENTER, *BIG ]
  label: center/big

- # Override
  << : [ *BIG, *LEFT, *SMALL ]
  x: 1
  label: center/big
""")
    for i in 5 .. 7:
      check root.elems[i] == root.elems[4]

  test "own keys win over merged ones":
    check merged("{<<: {a: 1, b: 1}, a: 2}") == node("{a: 2, b: 1}")

  test "earlier mappings win in a sequence":
    check merged("{<<: [{a: 1}, {a: 2, b: 2}]}") == node("{a: 1, b: 2}")

  test "merged mappings are merged first":
    check merged("""
base: &base {a: 1}
middle: &middle {<<: *base, b: 2}
top: {<<: *middle, c: 3}
""")["top"] == node("{a: 1, b: 2, c: 3}")

  test "merging does not depend on visiting order":
    let root = merged("""
top: {<<: &middle {<<: &base {a: 1}, b: 2}, c: 3}
again: *middle
base: *base
""")
    check root["top"] == node("{a: 1, b: 2, c: 3}")
    check root["again"] == node("{a: 1, b: 2}")

  test "!!merge tags merge, quoted keys do not":
    check merged("{!!merge <<: {a: 1}}") == node("{a: 1}")
    check merged("{\"<<\": {a: 1}}") == node("{\"<<\": {a: 1}}")

  test "merged values are shared":
    let root = merged("{base: &b {list: [1]}, copy: {<<: *b}}")
    check cast[pointer](root["copy"]["list"]) == cast[pointer](root["base"]["list"])

  test "merge keys in nested and cyclic graphs":
    let root = merged("&top {self: *top, child: {<<: {a: 1}}}")
    check root["child"] == node("{a: 1}")
    check cast[pointer](root["self"]) == cast[pointer](root)

  test "mapping keys are rehashed":
    let root = merged("{? {<<: {a: 1}} : value}")
    check root[node("{a: 1}")].content == "value"

  test "a mapping key that was merged through another path":
    let root = merged("[&k {<<: {a: 1}}, {*k : v, <<: {{a: 1}: w}}]")
    check root.elems[1] == node("{{a: 1}: v}")

  test "invalid merge values":
    for yaml in ["{<<: 1}", "{<<: [{a: 1}, 2]}"]:
      expect YamlMergeError:
        discard merged(yaml)

  test "mappings that merge themselves":
    expect YamlMergeError:
      discard merged("&a {<<: *a}")
    expect YamlMergeError:
      discard merged("&a {b: &b {<<: *a}, <<: *b}")

type
  Database = object
    adapter, host, database: string

suite "Loading with merge keys":
  test "loadMerged constructs native values":
    var config: Table[string, Database]
    loadMerged("""
defaults: &defaults {adapter: postgres, host: localhost, database: none}
development: {<<: *defaults, database: dev}
production: {<<: *defaults, host: db.example, database: prod}
""", config)
    check config["development"] ==
        Database(adapter: "postgres", host: "localhost", database: "dev")
    check config["production"] ==
        Database(adapter: "postgres", host: "db.example", database: "prod")

  test "errors keep their positions":
    var config: Table[string, Database]
    try:
      loadMerged("a: {<<: {adapter: x, database: d}, host: y}\nb: {wrong: 2}",
          config)
      check false
    except YamlConstructionError as e:
      check e.mark.line == 2

  test "merge errors surface as such":
    var root: YamlNode
    expect YamlMergeError:
      loadMerged("{<<: 1}", root)

  test "the stream filter keeps documents and tags":
    var
      parser = initYamlParser()
      events = mergeKeysApplied(parser.parse(
          "--- {<<: {a: !!str 1}}\n--- [x]\n"))
      docs: seq[YamlNode]
    discard events.next()
    while events.peek().kind == yamlStartDoc:
      var doc: YamlNode
      construct(events, doc)
      docs.add(doc)
    check docs.len == 2
    check docs[0] == node("{a: !!str 1}")
    check docs[1] == node("[x]")

  test "the input's aliases are kept, merged values are written out":
    var root: YamlNode
    loadMerged("""
base: &b {v: 1}
list: &l [1]
again: *l
derived: {<<: *b}
""", root)
    check cast[pointer](root["list"]) == cast[pointer](root["again"])
    check cast[pointer](root["derived"]["v"]) != cast[pointer](root["base"]["v"])
    loadMerged("&top {self: *top, <<: {x: 1}}", root)
    check cast[pointer](root["self"]) == cast[pointer](root)
    check root["x"].content == "1"

  test "cycles made by merging keep an alias":
    var root: YamlNode
    loadMerged("a: &a {k: {<<: *a}}", root)
    let inner = root["a"]["k"]
    check cast[pointer](inner["k"]) == cast[pointer](inner)
