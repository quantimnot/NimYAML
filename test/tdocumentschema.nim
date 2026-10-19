#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests which schema each document of a stream declares
# (yaml/documentschema) and its validation against that schema
# (yaml/schemavalidation): the precedence of %SCHEMA, %GLOBAL SCHEMA,
# modeline and $schema key, the schema-source info, resolution of relative
# references, and the diagnostics validation produces.

import std/[os, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import "../yaml", "../yaml/dom", "../yaml/data", "../yaml/diagnostics",
    "../yaml/documentschema", "../yaml/jsonschema", "../yaml/schemavalidation"

proc winners(source: string, sourceUri = ""): seq[string] =
  for doc in documentSchemas(source, sourceUri): result.add(doc.schema)

proc kindsOf(source: string, sourceUri = ""): seq[seq[SchemaSourceKind]] =
  for doc in documentSchemas(source, sourceUri):
    var kinds: seq[SchemaSourceKind]
    for s in doc.sources: kinds.add(s.kind)
    result.add(kinds)

proc rules(diagnostics: seq[Diagnostic]): seq[string] =
  for d in diagnostics: result.add(d.rule)

const
  directive = "%SCHEMA https://x.example/directive\n"
  global = "%GLOBAL SCHEMA https://x.example/global\n"
  modeline = "# yaml-language-server: $schema=https://x.example/modeline\n"
  key = "$schema: https://x.example/key\n"

suite "schema precedence":
  test "each source alone":
    check winners(directive & "--- a\n") == @["https://x.example/directive"]
    check winners(global & "--- a\n") == @["https://x.example/global"]
    check winners(modeline & "a: 1\n") == @["https://x.example/modeline"]
    check winners(key & "a: 1\n") == @["https://x.example/key"]
    check winners("a: 1\n") == @[""]

  test "per-document %SCHEMA beats everything":
    let source = modeline & global & directive & "---\n" & key
    check winners(source) == @["https://x.example/directive"]
    check kindsOf(source) == @[@[sskDocumentDirective, sskGlobalDirective,
        sskModeline, sskSchemaKey]]

  test "%GLOBAL SCHEMA beats modeline and key":
    check winners(modeline & global & "---\n" & key) ==
        @["https://x.example/global"]

  test "modeline beats key":
    check winners(modeline & key) == @["https://x.example/modeline"]

  test "schema-source names the winner when there are several":
    let d = documentSchemas(modeline & key).diagnostics
    check d.rules == @["schema-source"]
    check d[0].severity == severityInfo
    check "https://x.example/modeline" in d[0].message
    check "$schema key" in d[0].message
    check d[0].startPos == Mark(line: 1, column: 33)
    check documentSchemas(key).diagnostics.len == 0

  test "globals are sources of every document; overrides are ranked":
    let source = global & "--- a\n...\n" & directive & "--- b\n...\n--- c\n"
    check winners(source) == @["https://x.example/global",
        "https://x.example/directive", "https://x.example/global"]
    check kindsOf(source)[1] == @[sskDocumentDirective, sskGlobalDirective]
    check documentSchemas(source).diagnostics.rules == @["schema-source"]

  test "the $schema key counts only at the root":
    check winners("a:\n  $schema: https://x.example/nested\n") == @[""]
    check winners("- $schema: https://x.example/item\n") == @[""]
    check winners("$schema: [not, a, string]\n") == @[""]
    check kindsOf("$schema: 42\nb: 1\n") == @[newSeq[SchemaSourceKind]()]
    check kindsOf("$schema: '42'\n", "file:///d/x.yaml") == @[@[sskSchemaKey]]
    check winners("b: {$schema: x}\n$schema: https://x.example/k\n") ==
        @["https://x.example/k"]

suite "modelines":
  test "belong to the document whose source contains them":
    let source = modeline & "a: 1\n---\n" &
        "# yaml-language-server: $schema=https://x.example/second\nb: 2\n"
    check winners(source) == @["https://x.example/modeline",
        "https://x.example/second"]

  test "indented and with extra spacing":
    check winners("  #   yaml-language-server:   $schema=s.json  \na: 1\n",
        "file:///w/d.yaml") == @["file:///w/s.json"]

  test "only comments are modelines":
    check winners("a: '# yaml-language-server: $schema=x'\n") == @[""]

  test "in a document dropped by error recovery":
    let source = "a: 1\n...\n# yaml-language-server: $schema=https://x.example/bad\n" &
        "[unclosed\n...\nb: 2\n"
    check winners(source) == @["", ""]

suite "relative references":
  test "resolve against the source URI":
    let uri = "file:///work/data/config.yaml"
    check winners("%SCHEMA ../s/a.json\n--- x\n", uri) == @["file:///work/s/a.json"]
    check winners("# yaml-language-server: $schema=b.json\nx: 1\n", uri) ==
        @["file:///work/data/b.json"]
    check winners("$schema: c.json\n", uri) == @["file:///work/data/c.json"]

  test "without a source URI they are errors":
    let d = documentSchemas("# yaml-language-server: $schema=b.json\n" &
        "$schema: c.json\n").diagnostics
    check d.rules == @["unresolvable-schema-uri", "unresolvable-schema-uri",
        "schema-source"]
    check winners("# yaml-language-server: $schema=b.json\nx: 1\n") == @[""]

suite "schema validation":
  let registry = newSchemaRegistry()
  registry.addSchema(loadAs[YamlNode]("""
type: object
required: [name]
properties:
  name: {type: string}
  port: {type: integer, maximum: 65535}
"""), "https://x.example/service")

  test "documents are validated against their schema":
    let source = """%GLOBAL SCHEMA https://x.example/service
--- {name: a, port: 80}
...
--- {name: b, port: 70000}
...
--- {port: 1}
"""
    let d = validateDocuments(source, registry)
    check d.rules == @["schema-validation", "schema-validation"]
    check d[0].startPos == Mark(line: 4, column: 21)
    check "maximum" in d[0].message
    check d[1].startPos.line == 6
    check "name" in d[1].message

  test "documents without schema are not validated":
    check validateDocuments("{port: x}\n", registry).len == 0

  test "an unknown schema is reported once per document":
    let d = validateDocuments(
        "%SCHEMA https://x.example/missing\n--- a\n", registry)
    check d.rules == @["schema-unavailable"]
    check d[0].startPos == Mark(line: 1, column: 9)

  test "schemas from files":
    let dir = getTempDir() / "nimyaml-tdocumentschema"
    createDir(dir)
    writeFile(dir / "s.yaml", "{type: array}\n")
    let files = newSchemaRegistry(fileSchemaLoader())
    let uri = "file://" & dir / "data.yaml"
    check validateDocuments("%SCHEMA s.yaml\n--- []\n", files, uri).len == 0
    check validateDocuments("%SCHEMA s.yaml\n--- {}\n", files, uri).rules ==
        @["schema-validation"]
    removeDir(dir)
