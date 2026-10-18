#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/uritemplate with the uritemplate-test suite (a git submodule),
# whose JSON files are loaded with NimYAML itself, and with partial
# expansion, which the suite does not cover.

import std/[os, tables, unittest]
import "../yaml", "../yaml/dom", "../yaml/uritemplate", "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

proc templateVars(node: YamlNode): TemplateVars =
  result = initTable[string, TemplateValue]()
  for name, value in node.members:
    if value.jsonKind != jkNull: result[name] = templateValue(value)

for file in ["spec-examples.json", "spec-examples-by-section.json",
    "extended-tests.json", "negative-tests.json"]:
  let groups = loadAs[YamlNode](readFile(
      currentSourcePath.parentDir / "uritemplate-test" / file))
  for group, content in groups.members:
    suite file & ": " & group:
      let vars = templateVars(content["variables"])
      for testCase in content["testcases"].elems:
        let
          source = testCase.elems[0].content
          expected = testCase.elems[1]
        test source:
          if expected.jsonKind == jkBool:
            expect UriTemplateError:
              discard expand(source, vars)
          elif expected.kind == ySequence:
            let actual = expand(source, vars)
            var found = false
            for alternative in expected.elems:
              if alternative.content == actual: found = true
            if not found: checkpoint("got " & actual)
            check found
          else:
            check expand(source, vars) == expected.content

suite "URI Template partial expansion":
  let vars = {"email": tv"someone@example.com", "title": tv"The Awesome Thing",
      "a": tv"1"}.toTemplateVars
  test "deferred expressions are kept":
    check parseUriTemplate("mailto:{email}?subject={title}{&cc}")
        .expandPartially(vars, ["title", "cc"]) ==
        "mailto:someone%40example.com?subject={title}{&cc}"
  test "query expressions are split":
    check parseUriTemplate("x{?a,b}").expandPartially(vars, ["b"]) ==
        "x?a=1{&b}"
    check parseUriTemplate("x{?c,b*}").expandPartially(vars, ["b"]) ==
        "x{?b*}"
  test "variables":
    check parseUriTemplate("{a}{?b,a}{/c*}").variables == @["a", "b", "c"]

  test "README example":
    let vars = {"id": tv"jo", "fields": tv(@["name", "age"])}.toTemplateVars
    check expand("/users/{id}{?fields*}", vars) == "/users/jo?fields=name&fields=age"
