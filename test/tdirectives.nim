#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests the parser's handling of NimYAML's ``%GLOBAL`` and ``%SCHEMA``
# directives: what each document's ``yamlStartDoc`` event reports as
# effective, how global directives are inherited and overridden, the issues
# recorded for misuse, and that the global state survives every way of
# continuing a stream (feed parser, checkpoints, parsing from a document
# start, error recovery). Each test states the rule it checks; the inputs
# are the fixtures.

import std/[strutils, unittest]
import "../yaml/data", "../yaml/parser", "../yaml/stream"

proc events(source: string, sourceUri = "", extensions = true): seq[Event] =
  for e in initYamlParser(directiveExtensions = extensions,
      sourceUri = sourceUri).parse(source):
    result.add(e)

proc documents(source: string, sourceUri = "", extensions = true): seq[Event] =
  ## The ``yamlStartDoc`` events of ``source``.
  for e in events(source, sourceUri, extensions):
    if e.kind == yamlStartDoc: result.add(e)

proc schemaOf(doc: Event): string =
  if doc.directives.isNil: "" else: doc.directives.schema

proc issueKinds(doc: Event): seq[DirectiveIssueKind] =
  if not doc.directives.isNil:
    for i in doc.directives.issues: result.add(i.kind)

proc tags(source: string): seq[string] =
  ## The tags of the scalars of ``source``, in order.
  for e in events(source):
    if e.kind == yamlScalar: result.add($e.scalarProperties.tag)

proc prefixOf(doc: Event, handle: string): string =
  for h in doc.handles:
    if h.handle == handle: return h.uriPrefix

suite "%SCHEMA":
  test "an absolute URI applies to the document that follows it":
    let docs = documents("%SCHEMA https://example.com/s.json\n--- a\n")
    check docs.len == 1
    check docs[0].schemaOf == "https://example.com/s.json"
    let d = docs[0].directives.declarations[0]
    check d.kind == dkSchema and d.origin == doDocument
    check d.reference == "https://example.com/s.json"
    check d.startPos == Mark(line: 1, column: 1)
    check d.valueStart == Mark(line: 1, column: 9)
    check d.valueEnd == Mark(line: 1, column: 35)
    check docs[0].issueKinds.len == 0

  test "only the next document":
    let docs = documents("%SCHEMA https://example.com/s.json\n--- a\n--- b\n")
    check docs[0].schemaOf == "https://example.com/s.json"
    check docs[1].schemaOf == ""
    check docs[1].directives.isNil

  test "relative references resolve against the source URI":
    let docs = documents("%SCHEMA ../schemas/s.json\n--- a\n",
        sourceUri = "file:///work/data/config.yaml")
    check docs[0].schemaOf == "file:///work/schemas/s.json"
    check docs[0].directives.declarations[0].reference == "../schemas/s.json"

  test "a relative reference without source URI is an error":
    let docs = documents("%SCHEMA s.json\n--- a\n")
    check docs[0].schemaOf == ""
    check docs[0].issueKinds == @[diUnresolvableSchema]
    let i = docs[0].directives.issues[0]
    check i.startPos == Mark(line: 1, column: 9)
    check i.endPos == Mark(line: 1, column: 15)

  test "an absolute reference needs no source URI":
    check documents("%SCHEMA urn:example:schema\n--- a\n")[0].schemaOf ==
        "urn:example:schema"

  test "at most one per document":
    let docs = documents(
        "%SCHEMA https://a.example/1\n%SCHEMA https://a.example/2\n--- a\n")
    check docs[0].schemaOf == "https://a.example/1"
    check docs[0].issueKinds == @[diDuplicateSchema]
    check docs[0].directives.issues[0].startPos.line == 2

  test "exactly one URI reference":
    check documents("%SCHEMA\n--- a\n")[0].issueKinds == @[diInvalidSchema]
    check documents("%SCHEMA a b\n--- a\n")[0].issueKinds == @[diInvalidSchema]
    check documents("%SCHEMA http://[x\n--- a\n")[0].issueKinds ==
        @[diInvalidSchema]
    check documents("%SCHEMA a # comment\n--- a\n", "file:///x.yaml")[0]
        .schemaOf == "file:///a"

suite "%GLOBAL":
  const tagged = """%GLOBAL TAG !e! tag:example.com,2000:
--- !e!a 1
...
--- !e!b 2
...
--- !e!c 3
"""
  test "global TAG applies to every document":
    check tags(tagged) == @["tag:example.com,2000:a", "tag:example.com,2000:b",
        "tag:example.com,2000:c"]
    for doc in documents(tagged):
      check doc.prefixOf("!e!") == "tag:example.com,2000:"
      check doc.directives.declarations[0].origin == doGlobal

  test "without the extensions, later documents do not know the handle":
    expect YamlStreamError:
      discard events(tagged, extensions = false)

  test "global YAML and per-document override":
    let docs = documents("""%GLOBAL YAML 1.1
--- a
...
%YAML 1.2
--- b
...
--- c
""")
    check docs[0].version == "1.1"
    check docs[1].version == "1.2"
    check docs[2].version == "1.1"
    check docs[1].directives.declarations[0].overridden
    check not docs[2].directives.declarations[0].overridden

  test "global SCHEMA and per-document override":
    let docs = documents("""%GLOBAL SCHEMA https://example.com/global.json
--- a
...
%SCHEMA https://example.com/second.json
--- b
...
--- c
""")
    check docs[0].schemaOf == "https://example.com/global.json"
    check docs[1].schemaOf == "https://example.com/second.json"
    check docs[2].schemaOf == "https://example.com/global.json"
    let second = docs[1].directives.declarations
    check second.len == 2
    check second[0].origin == doGlobal and second[0].overridden
    check second[1].origin == doDocument and not second[1].overridden

  test "per-document TAG overrides the global TAG of the same handle":
    let source = """%GLOBAL TAG !e! tag:global:
%GLOBAL TAG !f! tag:other:
--- !e!a 1
...
%TAG !e! tag:local:
---
[!e!b 2, !f!c 3]
...
--- !e!d 4
"""
    check tags(source) == @["tag:global:a", "tag:local:b", "tag:other:c",
        "tag:global:d"]
    let second = documents(source)[1].directives.declarations
    check second[0].handle == "!e!" and second[0].overridden
    check second[1].handle == "!f!" and not second[1].overridden

  test "the first document's own directives override its globals":
    let source = "%TAG !e! tag:local:\n%GLOBAL TAG !e! tag:global:\n" &
        "--- !e!a 1\n...\n--- !e!b 2\n"
    check tags(source) == @["tag:local:a", "tag:global:b"]

  test "global TAG can redefine the default handles":
    check tags("%GLOBAL TAG ! tag:mine:\n--- !a 1\n...\n--- !b 2\n") ==
        @["tag:mine:a", "tag:mine:b"]

  test "relative global SCHEMA resolves against the source URI":
    let docs = documents("%GLOBAL SCHEMA s.json\n--- a\n...\n--- b\n",
        sourceUri = "https://example.com/data/x.yaml")
    check docs[1].schemaOf == "https://example.com/data/s.json"
    let unresolved = documents("%GLOBAL SCHEMA s.json\n--- a\n")
    check unresolved[0].issueKinds == @[diUnresolvableSchema]
    check unresolved[0].schemaOf == ""

  test "a single document stream":
    let docs = documents("%GLOBAL SCHEMA https://e.example/s\n%GLOBAL YAML 1.2\n--- a\n")
    check docs.len == 1
    check docs[0].schemaOf == "https://e.example/s"
    check docs[0].version == "1.2"

suite "%GLOBAL errors":
  test "outside the first directive block":
    let docs = documents("--- a\n...\n%GLOBAL TAG !e! tag:x:\n--- b\n")
    check docs[1].issueKinds == @[diMisplacedGlobal]
    check docs[1].prefixOf("!e!") == ""
    let i = docs[1].directives.issues[0]
    check i.startPos == Mark(line: 3, column: 1)
    check i.endPos == Mark(line: 3, column: 23) # exclusive

  test "a misplaced %GLOBAL SCHEMA has no effect":
    let docs = documents(
        "--- a\n...\n%GLOBAL SCHEMA https://x.example/s\n--- b\n...\n--- c\n")
    check docs[1].issueKinds == @[diMisplacedGlobal]
    check docs[1].schemaOf == "" and docs[2].schemaOf == ""

  test "duplicate global YAML, SCHEMA and TAG handle":
    let docs = documents("""%GLOBAL YAML 1.2
%GLOBAL YAML 1.1
%GLOBAL SCHEMA https://x.example/1
%GLOBAL SCHEMA https://x.example/2
%GLOBAL TAG !e! tag:1:
%GLOBAL TAG !e! tag:2:
%GLOBAL TAG !f! tag:3:
--- a
""")
    check docs[0].issueKinds == @[diDuplicateGlobal, diDuplicateGlobal,
        diDuplicateGlobal]
    check docs[0].version == "1.2"
    check docs[0].schemaOf == "https://x.example/1"
    check docs[0].prefixOf("!e!") == "tag:1:"
    check docs[0].prefixOf("!f!") == "tag:3:"
    var lines: seq[int]
    for i in docs[0].directives.issues: lines.add(i.startPos.line)
    check lines == @[2, 4, 6]

  test "nested %GLOBAL":
    let docs = documents("%GLOBAL GLOBAL TAG !e! tag:x:\n--- a\n")
    check docs[0].issueKinds == @[diNestedGlobal]
    check docs[0].prefixOf("!e!") == ""

  test "missing directive":
    check documents("%GLOBAL\n--- a\n")[0].issueKinds == @[diMissingGlobal]
    check documents("%GLOBAL   # nothing\n--- a\n")[0].issueKinds ==
        @[diMissingGlobal]
    let i = documents("%GLOBAL\n--- a\n")[0].directives.issues[0]
    check i.startPos == Mark(line: 1, column: 1)
    check i.endPos == Mark(line: 1, column: 8)

  test "unknown directive inside %GLOBAL: warning, ignored":
    let docs = documents("%GLOBAL FOO bar baz\n--- a\n")
    check docs[0].issueKinds == @[diUnknownGlobal]
    check docs[0].directives.declarations.len == 0

  test "syntax errors of the wrapped directive are syntax errors":
    expect YamlStreamError:
      discard events("%GLOBAL YAML one\n--- a\n")
    expect YamlStreamError:
      discard events("%GLOBAL TAG x tag:y:\n--- a\n")

suite "reserved directives":
  test "are ignored with a warning (YAML 1.2, §6.8)":
    let docs = documents("%FOO bar baz # comment\n--- a\n")
    check docs[0].issueKinds == @[diUnknownDirective]
    let i = docs[0].directives.issues[0]
    check i.startPos == Mark(line: 1, column: 1)
    check i.endPos == Mark(line: 1, column: 13)

  test "without the extensions, GLOBAL and SCHEMA are reserved directives":
    let docs = documents("%GLOBAL YAML abc\n%SCHEMA https://x.example/s\n--- a\n",
        extensions = false)
    check docs[0].issueKinds == @[diUnknownDirective, diUnknownDirective]
    check docs[0].schemaOf == ""
    check docs[0].version == ""

suite "continuing a stream":
  const source = """%GLOBAL TAG !e! tag:example.com,2000:
%GLOBAL SCHEMA https://example.com/s.json
--- !e!a 1
...
--- !e!b 2
...
--- !e!c 3
"""
  test "feed parser, one character at a time":
    let expected = events(source)
    let fp = newYamlFeedParser(initYamlParser())
    var actual: seq[Event]
    for c in source:
      fp.feed([c])
      for e in fp.events: actual.add(e)
    fp.finish()
    for e in fp.events: actual.add(e)
    check actual == expected
    var schemas: seq[string]
    for e in actual:
      if e.kind == yamlStartDoc: schemas.add(e.schemaOf)
    check schemas == @["https://example.com/s.json", "https://example.com/s.json",
        "https://example.com/s.json"]

  test "checkpoint and resume between documents":
    let s = initYamlParser().parse(source)
    var before: seq[Event]
    while true:
      let e = s.next()
      before.add(e)
      if e.kind == yamlEndDoc: break
    let cp = s.checkpoint()
    let resumed = initYamlParser().resume(cp, source[cp.offset .. ^1])
    var tagsAfter: seq[string]
    var schemas: seq[string]
    while true:
      let e = resumed.next()
      if e.kind == yamlScalar: tagsAfter.add($e.scalarProperties.tag)
      if e.kind == yamlStartDoc: schemas.add(e.schemaOf)
      if e.kind == yamlEndStream: break
    check tagsAfter == @["tag:example.com,2000:b", "tag:example.com,2000:c"]
    check schemas == @["https://example.com/s.json", "https://example.com/s.json"]

  test "checkpoint with a peeked document start":
    let s = initYamlParser().parse(source)
    while s.next().kind != yamlEndDoc: discard
    discard s.peek()
    let cp = s.checkpoint()
    let resumed = initYamlParser().resume(cp, source[cp.offset .. ^1])
    let doc = resumed.next()
    check doc.kind == yamlStartDoc
    check doc.schemaOf == "https://example.com/s.json"
    check doc.directives.declarations.len == 2

  test "parsing from a later document start":
    let s = initYamlParser().parse(source)
    var starts: seq[YamlDocumentStart]
    for e in s:
      if e.kind == yamlStartDoc: starts.add(s.documentStart)
    check starts.len == 3
    check starts[0].index == 0 and starts[0].globals.len == 0
    check starts[2].index == 2 and starts[2].globals.len == 2
    var found: seq[string]
    for e in initYamlParser().parse(source[starts[2].offset .. ^1], starts[2]):
      if e.kind == yamlScalar: found.add($e.scalarProperties.tag)
    check found == @["tag:example.com,2000:c"]

  test "%GLOBAL in a document parsed from a later start is misplaced":
    let s = initYamlParser().parse(source)
    var starts: seq[YamlDocumentStart]
    for e in s:
      if e.kind == yamlStartDoc: starts.add(s.documentStart)
    let rest = "%GLOBAL YAML 1.1\n--- x\n"
    for e in initYamlParser().parse(rest, starts[1]):
      if e.kind == yamlStartDoc: check e.issueKinds == @[diMisplacedGlobal]

  test "a document dropped by error recovery still declares its globals":
    let broken = "%GLOBAL TAG !e! tag:x:\n---\n[unclosed\n...\n--- !e!a 1\n"
    let rs = initYamlParser().parseRecovering(broken)
    var found: seq[string]
    for e in rs:
      if e.kind == yamlScalar: found.add($e.scalarProperties.tag)
    check rs.errors.len == 1
    check found == @["tag:x:a"]
    check rs.errors[0].resumedAt.index == 1
    check rs.errors[0].resumedAt.globals.len == 1
