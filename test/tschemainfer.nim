#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/schemainfer. The rules are checked on small samples, by the
# schema text they make. The promise that matters most, that a schema
# validates the documents it was made from, is checked by validating them
# with yaml/jsonschema, format assertion on: on the samples here, and on
# the instances of every test case of the JSON Schema Test Suite, which
# are many small documents of every type and shape, taken as one sample
# per test case.

import std/[os, strutils, unittest]
import "../yaml", "../yaml/dom", "../yaml/jsonschema", "../yaml/schemainfer",
    "../yaml/private/jsonmodel"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

const suiteDir = currentSourcePath.parentDir / "JSON-Schema-Test-Suite"

proc docs(yaml: string): seq[YamlNode] = loadMultiDoc(yaml, result)

proc inferred(yaml: string, options = InferenceOptions()): string =
  ## The schema text of the documents of ``yaml``, without ``$schema``.
  schemaText(inferSchema(docs(yaml), options)).split('\n', 1)[1]

proc validatesAll(documents: seq[YamlNode], options = InferenceOptions()): bool =
  let schema = compile(inferSchema(documents, options))
  result = true
  for document in documents:
    if not schema.isValid(document, ValidationOptions(formatAssertion: true)):
      checkpoint("not valid: " & $document)
      checkpoint(schemaText(inferSchema(documents, options)))
      result = false

suite "schemainfer":
  test "scalars by the core schema":
    check inferred("1") == "type: integer\n"
    check inferred("1.5") == "type: number\n"
    check inferred("'1'") == "type: string\n"
    check inferred("true") == "type: boolean\n"
    check inferred("~") == "type: \"null\"\n"
    check inferred("!Ref x") == "type: string\n"
    check inferred("0x10") == "type: string\n" # as jsonschema reads it

  test "unions of types, integers within numbers":
    check inferred("--- 1\n--- x\n--- ~\n") ==
        "type:\n  - string\n  - integer\n  - \"null\"\n"
    check inferred("--- 1\n--- 2.5\n") == "type: number\n"
    check inferred("--- 1\n--- 2\n", InferenceOptions(integers: false)) ==
        "type: number\n"

  test "properties in first-seen order, required by every object":
    check inferred("--- {b: 1, a: x}\n--- {a: y, c: true}\n") ==
        "type: object\nproperties:\n  b:\n    type: integer\n" &
        "  a:\n    type: string\n  c:\n    type: boolean\nrequired:\n  - a\n"
    check inferred("{a: 1}", InferenceOptions(required: false)) ==
        "type: object\nproperties:\n  a:\n    type: integer\n"

  test "required is per object, not per document":
    # the root is an object in one document only; its members still count
    # among the objects
    check inferred("--- {a: 1}\n--- x\n") == "type:\n  - object\n" &
        "  - string\nproperties:\n  a:\n    type: integer\nrequired:\n  - a\n"

  test "additionalProperties":
    check inferred("{a: {b: 1}}", InferenceOptions(additionalProperties: false)) ==
        "type: object\nproperties:\n  a:\n    type: object\n    properties:\n" &
        "      b:\n        type: integer\n    required:\n      - b\n" &
        "    additionalProperties: false\nrequired:\n  - a\n" &
        "additionalProperties: false\n"

  test "items merged across all arrays":
    check inferred("--- [{a: 1}, {a: 2, b: x}]\n--- [{a: 3}]\n") ==
        "type: array\nitems:\n  type: object\n  properties:\n" &
        "    a:\n      type: integer\n    b:\n      type: string\n" &
        "  required:\n    - a\n"
    check inferred("[]") == "type: array\n"
    check inferred("[1, x]") ==
        "type: array\nitems:\n  type:\n    - string\n    - integer\n"

  test "keys that are not strings are not members":
    check inferred("{1: a, [x]: b, '2': c}") ==
        "type: object\nproperties:\n  \"2\":\n    type: string\n" &
        "required:\n  - \"2\"\n"

  test "formats":
    check inferred("--- 2024-01-02\n--- 2023-12-31\n") ==
        "type: string\nformat: date\n"
    check inferred("2024-01-02T03:04:05Z") == "type: string\nformat: \"date-time\"\n"
    check inferred("ada@example.com") == "type: string\nformat: email\n"
    check inferred("https://example.com/a") == "type: string\nformat: uri\n"
    check inferred("urn:isbn:0451450523") == "type: string\n"
    check inferred("--- 2024-01-02\n--- soon\n") == "type: string\n"
    check inferred("--- 2024-01-02\n--- 1\n") ==
        "type:\n  - string\n  - integer\nformat: date\n"
    check inferred("2024-01-02", InferenceOptions(formats: false)) ==
        "type: string\n"

  test "enums of repeated strings":
    let sample = "[active, active, retired, active, ~]"
    check inferred(sample) == "type: array\nitems:\n  type:\n" &
        "    - string\n    - \"null\"\n"
    check inferred(sample, InferenceOptions(enumLimit: 3)) ==
        "type: array\nitems:\n  type:\n    - string\n    - \"null\"\n" &
        "  enum:\n    - active\n    - retired\n    - null\n"
    # too many, or not repeated
    check "enum" notin inferred(sample, InferenceOptions(enumLimit: 1))
    check "enum" notin inferred("[a, b, c]", InferenceOptions(enumLimit: 5))
    # strings that would read as something else stay strings
    check inferred("['1', '1', 'true', 'true']", InferenceOptions(enumLimit: 2)) ==
        "type: array\nitems:\n  type: string\n  enum:\n    - \"1\"\n" &
        "    - \"true\"\n"
    check "enum" notin inferred("[1, 1, 1]", InferenceOptions(enumLimit: 2))

  test "aliases and cycles":
    check inferred("a: &x {b: 1}\nc: *x\n") == "type: object\nproperties:\n" &
        "  a:\n    type: object\n    properties:\n      b:\n" &
        "        type: integer\n    required:\n      - b\n" &
        "  c:\n    type: object\n    properties:\n      b:\n" &
        "        type: integer\n    required:\n      - b\n" &
        "required:\n  - a\n  - c\n"
    let cyclic = docs("&a {self: *a, n: 1}")
    check validatesAll(cyclic)

  test "incremental, and without documents":
    var inference = initSchemaInference()
    check schemaText(inference.toSchema()) ==
        "$schema: \"https://json-schema.org/draft/2020-12/schema\"\n"
    for document in docs("--- {a: 1}\n--- {a: 2, b: 3}\n"):
      inference.add(document)
    check inference.documents == 2
    check schemaText(inference.toSchema()) == schemaText(
        inferSchema(docs("--- {a: 1}\n--- {a: 2, b: 3}\n")))

  test "the schema reads back as written":
    let schema = inferSchema(docs("--- {a: '80', b: [~, x]}\n--- {a: x}\n"),
        InferenceOptions(enumLimit: 4))
    check jsonEquals(loadAs[YamlNode](schemaText(schema)), schema)

  test "the schema validates its documents":
    let sample = docs("""
--- {name: Ada, born: 1815-12-10, tags: [math], site: 'https://ada.example'}
--- {name: Alan, tags: [], score: 1.5, id: 4b0b6a3c-8f3e-4c7e-9a0e-1b2c3d4e5f60}
--- {name: Grace, score: 2, when: '2024-01-02T03:04:05Z', mail: g@example.com}
--- [1, "2", {x: [[], [~]]}]
--- ~
""")
    check validatesAll(sample)
    check validatesAll(sample, InferenceOptions(additionalProperties: false,
        enumLimit: 10, integers: false))

  test "the schema validates the JSON Schema Test Suite's instances":
    var samples = 0
    for path in walkDirRec(suiteDir / "tests" / "draft2020-12"):
      if not path.endsWith(".json"): continue
      for group in loadAs[YamlNode](readFile(path)).elems:
        var instances: seq[YamlNode]
        for testCase in group["tests"].elems: instances.add(testCase["data"])
        for options in [InferenceOptions(),
            InferenceOptions(additionalProperties: false, enumLimit: 3)]:
          if not validatesAll(instances, options):
            checkpoint(path & ": " & group["description"].content)
            fail()
        inc samples
    check samples > 300
