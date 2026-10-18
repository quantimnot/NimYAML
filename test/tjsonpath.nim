#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/jsonpath in two parts. The JSONPath Compliance Test Suite (a git
# submodule) defines conformance to RFC 9535 on JSON documents; since JSON is
# YAML, its cts.json is loaded with NimYAML itself and every document arrives
# as the YamlNode graph the queries run on. The remaining tests cover what the
# suite cannot: how YAML-specific features (tags, non-string keys, aliases,
# cycles) read as JSON, and the I-Regexp engine behind match() and search().

import std/[os, strutils, unittest]
import "../yaml", "../yaml/dom", "../yaml/jsonpath", "../yaml/private/jsonmodel",
    "../yaml/private/iregexp"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

proc paths(found: seq[LocatedNode]): seq[string] =
  for f in found: result.add(f.path)

proc sameNodes(actual: seq[LocatedNode], expected: YamlNode): bool =
  if actual.len != expected.elems.len: return false
  for i, f in actual:
    if not jsonEquals(f.node, expected.elems[i]): return false
  result = true

proc strings(node: YamlNode): seq[string] =
  for item in node.elems: result.add(item.content)

suite "JSONPath Compliance Test Suite":
  let
    ctsPath = currentSourcePath.parentDir /
        "jsonpath-compliance-test-suite" / "cts.json"
    cts = loadAs[YamlNode](readFile(ctsPath))
  for testCase in cts["tests"].elems:
    let name = testCase["name"].content
    test name:
      let selector = testCase["selector"].content
      if testCase.hasKey("invalid_selector"):
        expect YamlJsonPathError:
          discard parseJsonPath(selector)
      else:
        let found = testCase["document"].queryLocated(parseJsonPath(selector))
        if testCase.hasKey("result"):
          check found.sameNodes(testCase["result"])
          check found.paths == testCase["result_paths"].strings
        else:
          # several results are correct when object member order matters
          var matched = false
          for i, alternative in testCase["results"].elems:
            if found.sameNodes(alternative) and
                found.paths == testCase["results_paths"].elems[i].strings:
              matched = true
          check matched

suite "JSONPath on YAML":
  test "tags decide scalar types":
    let root = loadAs[YamlNode]("""
- {v: 1}
- {v: "1"}
- {v: !!str 1}
- {v: 1.0}
- {v: !!float 1}
- {v: true}
- {v: !custom 1}
""")
    check root.queryLocated("$[?@.v == 1]").paths ==
        @["$[0]", "$[3]", "$[4]"]
    check root.queryLocated("$[?@.v == '1']").paths ==
        @["$[1]", "$[2]", "$[6]"]
    check root.query("$[?@.v == true]").len == 1

  test "non-string keys are invisible":
    let root = loadAs[YamlNode]("""
0: zero
? [a]
: list
!custom k: custom
"0": quoted
""")
    let found = root.queryLocated("$.*")
    check found.len == 1
    check found[0].path == "$['0']"
    check found[0].node.content == "quoted"
    check root.query("$[?length(@) > 0]").len == 1
    check root.query("$[?count($.*) == 1]").len == 1

  test "aliases are followed along every path":
    let root = loadAs[YamlNode]("""
a: &x {v: 1}
b: *x
""")
    let found = root.query("$..v")
    check found.len == 2
    check cast[pointer](found[0]) == cast[pointer](found[1])
    check root.queryLocated("$.b.v").paths == @["$['b']['v']"]

  test "descendant segment terminates on cyclic graphs":
    let root = loadAs[YamlNode]("&a {name: root, self: *a, kids: [*a, leaf]}")
    check root.query("$..name").len == 1
    check root.queryLocated("$..*").paths.len == 5 # name self kids [0] [1]
    check root.query("$.self.self.kids[0].name")[0].content == "root"

  test "normalized path escapes":
    let root = loadAs[YamlNode]("""{"a'b\\c\u0001\n": 1}""")
    check root.queryLocated("$.*").paths == @["$['a\\'b\\\\c\\u0001\\n']"]

  test "results are the document's own nodes":
    let root = loadAs[YamlNode]("items: [{id: &one 1}, {id: 2}]")
    let found = root.query("$.items[0].id")
    check found[0].content == "1"
    check found[0].startPos.line == 1

  test "parsed queries are reusable":
    let path = parseJsonPath("$[?@ > 1]")
    check $path == "$[?@ > 1]"
    check not path.isSingular
    check parseJsonPath("$.a[0]['b']").isSingular
    check loadAs[YamlNode]("[1, 2, 3]").query(path).len == 2
    check loadAs[YamlNode]("[5]").query(path).len == 1

  test "errors report the position":
    try:
      discard parseJsonPath("$.a[?@.b ==]")
      fail()
    except YamlJsonPathError as e:
      check e.pos == 11
      check e.query == "$.a[?@.b ==]"
    expect YamlJsonPathError:
      discard loadAs[YamlNode]("{}").query("$[?length(@.*) > 1]")

suite "I-Regexp":
  proc matches(pattern, input: string): bool =
    compileIRegexp(pattern).matches(input)
  proc searches(pattern, input: string): bool =
    compileIRegexp(pattern).matchesSubstring(input)

  test "match is anchored, search is not":
    check matches("ab|cd", "cd")
    check not matches("ab|cd", "abc")
    check searches("b", "abc")
    check searches("", "x")
    check not searches("z", "abc")

  test "quantifiers":
    check matches("a{2,3}", "aaa")
    check not matches("a{2,3}", "aaaa")
    check matches("a{2,}", "aaaaa")
    check matches("(ab){2}", "abab")
    check matches("x?", "")
    check matches("(a*)*b", "aaab")
    # would take exponential time with a backtracking engine
    check not matches("(a*)*b", repeat('a', 5000))

  test "character classes":
    check matches("[a-z]+", "abc")
    check matches("[^a-z]", "Q")
    check matches("[-a]", "-")
    check matches("[a-]", "-")
    check matches("a[\\].]c", "a]c")
    check matches("a.c", "a€c")
    check not matches("a.c", "a\nc")

  test "anchors":
    # RFC 9485 has no anchors, but the compliance suite expects them
    check matches("^ab.*", "abc")
    check matches("^$", "")
    check not matches("^$", "^$")
    check matches("\\^[$]", "^$")
    check not matches("a^b", "ab")
    check not searches("^b", "abc")
    check searches("^a", "abc")
    check searches("c$", "abc")
    check not searches("b$", "abc")

  test "Unicode categories":
    check matches("\\p{Lu}", "Ж")
    check not matches("\\p{Lu}", "ж")
    check matches("\\P{Lu}", "ж")
    check matches("\\p{Nd}+", "١٢٣") # Arabic-Indic digits
    check matches("\\p{L}\\p{Zs}\\p{Sc}", "a €")
    check matches("[\\p{N}x]+", "x9x")
    check matches("\\p{Cn}", "\u{40000}") # unassigned

  test "invalid patterns":
    for pattern in ["a**", "(", ")", "[", "[]", "a{3,2}", "\\d", "[b-a]",
        "\\p{Xx}", "\\p{Cs}", "[a-\\p{L}]", "{", "a{", "\\p{Lõ}", "a{99999999}"]:
      expect IRegexpError:
        discard compileIRegexp(pattern)
