#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/jsonschema with the JSON Schema Test Suite (a git submodule):
# the validation tests of every supported draft, including the optional
# ones, the output tests and the annotation tests. The suite's JSON files are
# loaded with NimYAML itself. Tests specific to YAML follow at the end.

import std/[algorithm, os, strutils, tables, unittest, uri]
import "../yaml", "../yaml/dom", "../yaml/jsonschema", "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

const suiteDir = currentSourcePath.parentDir / "JSON-Schema-Test-Suite"

proc load(path: string): YamlNode = loadAs[YamlNode](readFile(path))

proc remoteLoader(): SchemaLoader =
  ## Serves the suite's remotes as http://localhost:1234/...
  result = proc(uri: string): YamlNode {.closure, raises: [CatchableError].} =
    const prefix = "http://localhost:1234/"
    if uri.startsWith(prefix):
      let path = suiteDir / "remotes" / uri[prefix.len .. ^1]
      if fileExists(path): return load(path)
    result = nil

const drafts = [("draft4", draft4), ("draft6", draft6), ("draft7", draft7),
    ("draft2019-09", draft2019), ("draft2020-12", draft2020)]

proc testFiles(dir: string): seq[string] =
  for path in walkDirRec(dir):
    if path.endsWith(".json"): result.add(path)
  result.sort()

for (dirName, draft) in drafts:
  let
    registry = newSchemaRegistry(remoteLoader(), draft)
    dir = suiteDir / "tests" / dirName
  for path in testFiles(dir):
    let
      relative = path[dir.len + 1 .. ^1]
      options = ValidationOptions(
          formatAssertion: relative.startsWith("optional/format/"),
          contentAssertion: relative == "optional/content.json")
    suite dirName & "/" & relative:
      for testCase in load(path).elems:
        let caseName = testCase["description"].content
        var schema: JsonSchema
        var compileError = ""
        try: schema = registry.compile(testCase["schema"], draft = draft)
        except JsonSchemaError as e: compileError = e.msg
        for t in testCase["tests"].elems:
          test caseName & ": " & t["description"].content:
            if compileError.len > 0:
              checkpoint(compileError)
              fail()
            else:
              let expected = t["valid"].jsonScalar.boolean
              check schema.isValid(t["data"], options) == expected
              check schema.validate(t["data"], options).valid == expected

for (dirName, draft) in drafts[3 .. 4]:
  let
    registry = newSchemaRegistry(remoteLoader(), draft)
    outputDir = suiteDir / "output-tests" / dirName
  registry.addSchema(load(outputDir / "output-schema.json"))
  for path in testFiles(outputDir / "content"):
    suite "output " & dirName & "/" & path.extractFilename:
      for testCase in load(path).elems:
        let schema = registry.compile(testCase["schema"], draft = draft)
        for t in testCase["tests"].elems:
          test testCase["description"].content & ": " & t["description"].content:
            let
              output = schema.validate(t["data"]).toYaml(ofBasic)
              outputSchema = registry.compile(t["output"]["basic"])
            if not outputSchema.isValid(output):
              checkpoint($output)
              fail()

proc compatible(compatibility: string, release: int): bool =
  ## Evaluates the ``compatibility`` of an annotation test case.
  if compatibility.len == 0: return true
  for constraint in compatibility.split(','):
    if constraint.startsWith("<="):
      if release > parseInt(constraint[2 .. ^1]): return false
    elif constraint.startsWith("="):
      if release != parseInt(constraint[1 .. ^1]): return false
    elif release < parseInt(constraint): return false
  result = true

const releases = [(draft4, 4), (draft6, 6), (draft7, 7), (draft2019, 2019),
    (draft2020, 2020)]

for (draft, release) in releases:
  for path in testFiles(suiteDir / "annotations" / "tests"):
    suite "annotations " & $draft & "/" & path.extractFilename:
      for testCase in load(path)["suite"].elems:
        let compatibility =
          if testCase.hasKey("compatibility"): testCase["compatibility"].content
          else: ""
        if not compatible(compatibility, release): continue
        let registry = newSchemaRegistry(defaultDraft = draft)
        if testCase.hasKey("externalSchemas"):
          for uri, external in testCase["externalSchemas"].members:
            registry.addSchema(external, uri)
        let schema = registry.compile(testCase["schema"], draft = draft)
        for i, t in testCase["tests"].elems:
          test testCase["description"].content & " #" & $i:
            let found = schema.validate(t["instance"]).annotations
            for assertion in t["assertions"].elems:
              var actual = initTable[string, YamlNode]()
              for a in found:
                if a.instanceLocation == assertion["location"].content and
                    a.keyword == assertion["keyword"].content:
                  # the suite names schemas by their pointer in the document
                  actual["#" & a.documentPointer] = a.value
              var expectedCount = 0
              for key, value in assertion["expected"].members:
                let location = decodeUrl(key, decodePlus = false)
                inc(expectedCount)
                if not actual.hasKey(location) or
                    not jsonEquals(actual[location], value):
                  checkpoint("missing or different at " & location &
                      " for " & assertion["keyword"].content & " at " &
                      escape(assertion["location"].content))
                  fail()
              if actual.len != expectedCount:
                checkpoint("unexpected annotations for " &
                    assertion["keyword"].content & " at " &
                    escape(assertion["location"].content) & ": " & $actual.len)
                fail()

suite "JSON Schema on YAML":
  proc schemaOf(s: string): JsonSchema = compile(loadAs[YamlNode](s))
  proc instance(s: string): YamlNode = loadAs[YamlNode](s)

  test "tags decide types":
    let s = schemaOf("type: integer")
    check s.isValid(instance("1"))
    check not s.isValid(instance("'1'"))
    check not s.isValid(instance("!!str 1"))
    check s.isValid(instance("!!float 1")) # 1.0 is an integer
    check not s.isValid(instance("!custom 1"))
    check schemaOf("type: string").isValid(instance("2001-12-14"))

  test "non-string keys are not properties":
    let s = schemaOf("{additionalProperties: false, properties: {a: true}}")
    check s.isValid(instance("{a: 1, 0: x, [b]: y}"))
    check not s.isValid(instance("{a: 1, b: 2}"))

  test "aliases are followed":
    let s = schemaOf("{type: array, items: {required: [x]}}")
    check s.isValid(instance("[&a {x: 1}, *a]"))
    check not s.isValid(instance("[&a {y: 1}, *a]"))

  test "YAML special floats are numbers but not integers":
    let s = schemaOf("{type: number, maximum: 10}")
    check not s.isValid(instance(".inf"))
    check s.isValid(instance("-.inf"))
    check not schemaOf("type: integer").isValid(instance(".nan"))
    check schemaOf("type: number").isValid(instance(".nan"))

  test "exact decimal arithmetic":
    check schemaOf("multipleOf: 0.0001").isValid(instance("0.0075"))
    check not schemaOf("multipleOf: 0.0001").isValid(instance("0.00751"))
    check schemaOf("multipleOf: 0.5").isValid(instance("1e308"))
    check schemaOf("maximum: 972783798187987123879878123.188781371").isValid(
        instance("972783798187987123879878123.18878137"))
    check schemaOf("const: 1.0").isValid(instance("1"))
    check schemaOf("type: integer").isValid(instance("123456789012345678901234567890"))

  test "schemas written in YAML with anchors":
    let s = schemaOf("""
$defs:
  positive: &positive {type: integer, minimum: 1}
properties:
  a: *positive
  b: {$ref: '#/$defs/positive'}
""")
    check s.isValid(instance("{a: 1, b: 2}"))
    check not s.isValid(instance("{a: 0}"))
    check not s.isValid(instance("{b: 0}"))

  test "surrogate pair escapes form one code point":
    let s = loadAs[YamlNode]("\"\\uD83D\\uDCA9\"")
    check s.content == "\xF0\x9F\x92\xA9"
    check schemaOf("maxLength: 1").isValid(s)

suite "JSON Schema API":
  test "errors of the basic output format":
    let
      s = compile(loadAs[YamlNode]("""
type: object
required: [name]
properties:
  age: {type: integer, minimum: 0}
"""))
      r = s.validate(loadAs[YamlNode]("{age: -1}"))
    check not r.valid
    var locations: seq[(string, string)]
    for e in r.errors:
      if e.keyword in ["required", "minimum"]:
        locations.add((e.keywordLocation, e.instanceLocation))
    check ("/required", "") in locations
    check ("/properties/age/minimum", "/age") in locations
    check r.annotations.len == 0

  test "annotations of a valid result":
    let
      s = compile(loadAs[YamlNode]("{title: Root, properties: {a: {default: 1}}}"))
      r = s.validate(loadAs[YamlNode]("{a: 2}"))
    check r.valid
    var found: seq[(string, string)]
    for a in r.annotations: found.add((a.keyword, a.instanceLocation))
    check ("title", "") in found
    check ("default", "/a") in found
    check ("properties", "") in found

  test "output formats":
    let
      s = compile(loadAs[YamlNode]("{anyOf: [{type: string}, {type: integer}]}"))
      bad = s.validate(loadAs[YamlNode]("[]"))
      good = s.validate(loadAs[YamlNode]("1"))
    check bad.toYaml(ofFlag)["valid"].content == "false"
    check bad.toYaml(ofBasic)["errors"].len >= 3
    check not good.toYaml(ofBasic).hasKey("errors")
    let detailed = bad.toYaml(ofDetailed)
    check detailed["keywordLocation"].content == "/anyOf"
    check detailed["errors"].len == 2
    check bad.toYaml(ofVerbose)["errors"].len == 1
    check bad.outputTree.children[0].keyword == "anyOf"

  test "loader and registry":
    var requested: seq[string]
    let registry = newSchemaRegistry(proc(uri: string): YamlNode
        {.closure, raises: [CatchableError].} =
      requested.add(uri)
      if uri == "https://example.com/positive":
        result = loadAs[YamlNode]("{type: integer, minimum: 1}"))
    registry.addSchema(loadAs[YamlNode]("{$id: 'https://example.com/name', type: string}"))
    let s = registry.compile(loadAs[YamlNode]("""
$id: https://example.com/person
properties:
  name: {$ref: name}
  age: {$ref: positive}
"""))
    check requested == @["https://example.com/positive"]
    check s.isValid(loadAs[YamlNode]("{name: Ada, age: 36}"))
    check not s.isValid(loadAs[YamlNode]("{name: 1}"))
    check registry.compile("https://example.com/positive").isValid(
        loadAs[YamlNode]("3"))

  test "compile errors":
    expect JsonSchemaError:
      discard compile(loadAs[YamlNode]("$ref: 'https://unknown.example/s'"))
    expect JsonSchemaError:
      discard compile(loadAs[YamlNode]("$ref: '#/$defs/missing'"))
    expect JsonSchemaError:
      discard compile(loadAs[YamlNode]("minLength: -1"))
    expect JsonSchemaError:
      discard compile(loadAs[YamlNode]("pattern: '('"))
    expect JsonSchemaError:
      discard compile(loadAs[YamlNode]("type: thing"))

  test "compile errors name the invalid subschema":
    try:
      discard compile(loadAs[YamlNode]("{properties: {a/b: {items: string}}}"))
      check false
    except JsonSchemaError as e:
      check e.msg == "invalid schema at #/properties/a~1b/items: expected a schema"

  test "lenient resources skip invalid keywords":
    const text = """
$defs: {list: {type: array, items: string}}
properties:
  p: {$ref: '#/$defs/list'}
  q: {type: integer, required: true}
  r: {$ref: 'vscode://schemas/missing'}
"""
    let loader = proc(uri: string): YamlNode
        {.closure, raises: [CatchableError].} =
      if uri == "vscode://schemas/s": result = loadAs[YamlNode](text)
    let lenient = newSchemaRegistry(loader,
        lenient = proc(uri: string): bool = uri.startsWith("vscode:"))
    let s = lenient.compile("vscode://schemas/s")
    check s.isValid(loadAs[YamlNode]("{p: [1], q: 1, r: 2}"))
    check not s.isValid(loadAs[YamlNode]("{p: 1}"))
    check not s.isValid(loadAs[YamlNode]("{q: x}"))
    # other resources are not lenient
    expect JsonSchemaError:
      discard lenient.compile(loadAs[YamlNode]("items: string"))
    expect JsonSchemaError:
      discard newSchemaRegistry(loader).compile("vscode://schemas/s")

  test "infinite recursion is reported":
    let s = compile(loadAs[YamlNode]("$ref: '#'"))
    expect JsonSchemaError:
      discard s.isValid(loadAs[YamlNode]("1"))

  test "cyclic instances":
    let
      s = compile(loadAs[YamlNode]("{type: array, items: {$ref: '#'}}"))
      cyclic = loadAs[YamlNode]("&a [*a, *a]")
    check s.isValid(cyclic)
    check s.validate(cyclic).valid
    check not compile(loadAs[YamlNode]("{items: {$ref: '#'}, maxItems: 1}")).isValid(cyclic)

  test "deeply nested instances":
    var nested = ""
    for _ in 0 ..< 200: nested.add('[')
    for _ in 0 ..< 200: nested.add(']')
    let s = compile(loadAs[YamlNode]("{type: array, items: {$ref: '#'}}"))
    check s.isValid(loadAs[YamlNode](nested))
    check s.validate(loadAs[YamlNode](nested)).valid

  test "two schemas without $id do not collide":
    let registry = newSchemaRegistry()
    let
      a = registry.compile(loadAs[YamlNode]("{$defs: {x: {type: string}}, $ref: '#/$defs/x'}"))
      b = registry.compile(loadAs[YamlNode]("{$defs: {x: {type: integer}}, $ref: '#/$defs/x'}"))
    check a.isValid(loadAs[YamlNode]("s")) and not a.isValid(loadAs[YamlNode]("1"))
    check b.isValid(loadAs[YamlNode]("1")) and not b.isValid(loadAs[YamlNode]("s"))

  test "checkSchema validates against the meta-schema":
    let registry = newSchemaRegistry()
    check registry.checkSchema(loadAs[YamlNode]("{type: string}")).valid
    check not registry.checkSchema(loadAs[YamlNode]("{type: 5}")).valid
    check not registry.checkSchema(loadAs[YamlNode](
        "{$schema: 'http://json-schema.org/draft-04/schema#', minimum: 1, exclusiveMinimum: 2}")).valid

  test "README example":
    let schema = compile(loadAs[YamlNode]("""
type: object
required: [name]
properties:
  name: {type: string, minLength: 1}
  age: {type: integer, minimum: 0}
"""))
    let person = loadAs[YamlNode]("{name: Ada, age: -1}")
    check not schema.isValid(person)
    var messages: seq[string]
    for error in schema.validate(person).errors:
      messages.add(error.instanceLocation & ": " & error.error)
    check "/age: -1 is less than the minimum of 0" in messages
