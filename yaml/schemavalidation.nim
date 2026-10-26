#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ============================
## Module yaml/schemavalidation
## ============================
##
## Validates each document of a YAML stream against the JSON Schemas it
## declares (see `documentschema <documentschema.html>`_) and reports the
## result as `Diagnostic`s, positioned at the offending nodes. This is what
## the ``yamllint`` command line tool and the ``yamllsp`` language server
## publish next to the lint diagnostics.
##
## Diagnostics:
##
## ============================ ========= =====================================
## ``schema-validation``        error     a node violates the schema; one per
##                                        failing assertion, at the node
## ``schema-unavailable``       warning   the schema cannot be retrieved or
##                                        compiled; at the reference
## ============================ ========= =====================================
##
## Only the assertions that failed by themselves are reported, not the
## applicators (``properties``, ``allOf``, ``$ref``, ...) that failed because
## of them: an editor should point at the value that is wrong, once.
##
## Schemas are resolved through a `SchemaRegistry`. Since NimYAML never
## accesses the network on its own, a registry only knows what it has been
## given; `fileSchemaLoader` lets it read ``file:`` URIs. A schema used by
## several documents is compiled once per call.
##
## This module needs the DOM (``YamlNode``) and therefore, like
## `jsonschema <jsonschema.html>`_, ORC.

import std/[os, strutils, tables, uri]
when defined(nimPreviewSlimSystem):
  import std/syncio
import data, dom, loading, native, parser, stream, diagnostics, fragment,
    jsonschema, documentschema, source, memory
import std/streams

proc fileUri*(path: string): string =
  ## The ``file:`` URI of the local file ``path``, which is made absolute,
  ## percent-encoded except for unreserved characters and ``/``. Tools use it
  ## as the source URI of the files they read.
  const keep = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/', ':'}
  # Windows paths (C:\a\b) become /C:/a/b, as RFC 8089 describes
  var absolute = absolutePath(path).replace('\\', '/')
  if not absolute.startsWith("/"): absolute = "/" & absolute
  result = "file://"
  for c in absolute:
    if c in keep: result.add(c)
    else: result.add('%' & toHex(ord(c), 2))

proc fileSchemaLoader*(): SchemaLoader =
  ## A loader that reads schemas from ``file:`` URIs, in YAML or JSON. Other
  ## URIs are left to the registry's bundled meta-schemas and added schemas.
  result = proc(uri: string): YamlNode {.closure, raises: [CatchableError].} =
    if not uri.startsWith("file://"): return nil
    let path = decodeUrl(uri["file://".len .. ^1], decodePlus = false)
    if not fileExists(path): return nil
    result = loadAs[YamlNode](readFile(path))

proc leafErrors(u: OutputUnit, output: var seq[OutputUnit]) =
  ## The failed keywords whose failure is not explained by a failed
  ## subschema below them.
  if u.valid: return
  var failedBelow = false
  for child in u.children:
    if not child.valid:
      failedBelow = true
      leafErrors(child, output)
  if not failedBelow and u.kind == oukKeyword: output.add(u)
  elif not failedBelow and u.error.len > 0: output.add(u) # false schema

proc rangeOf(root: YamlNode, instanceLocation: string,
    fallback: Mark): (Mark, Mark) =
  ## The source range of the node at ``instanceLocation``.
  try:
    let node = root.resolvePointer(instanceLocation)
    if node.startPos.line > 0 and node.endPos.line > 0:
      return (node.startPos, node.endPos)
  except YamlFragmentError: discard
  result = (fallback, Mark(line: fallback.line, column: fallback.column + 1))

proc validated(doc: DocumentSchema, buffer: BufferYamlStream,
    compiled: var Table[string, JsonSchema],
    unavailable: var Table[string, string], registry: SchemaRegistry,
    options: ValidationOptions, budget: MemoryBudget): seq[Diagnostic]

proc validateWith(recovering: YamlRecoveringStream, lines: Stream,
    sourceUri: string, registry: SchemaRegistry, options: ValidationOptions,
    budget: MemoryBudget): seq[Diagnostic] =
  var compiled = initTable[string, JsonSchema]()
  var unavailable = initTable[string, string]()
  # the events of the current document are held until its schema sources
  # are known, so that only documents with a schema are constructed, and a
  # document that cannot be constructed (e.g. for a duplicate key, which
  # lint reports) affects only itself
  var
    held: seq[Event]
    charged = 0
    diagnostics: seq[Diagnostic]
  proc onEvent(e: Event) =
    if e.kind in {yamlStartStream, yamlEndStream}: return
    let size = 64 + (if e.kind == yamlScalar: e.scalarContent.len else: 0)
    budget.reserve(size, "holding a document to validate it")
    charged += size
    held.add(e)
  proc onDocument(doc: DocumentSchema) =
    let buffer = newBufferYamlStream()
    for e in held: buffer.put(e)
    held.setLen(0)
    budget.release(charged)
    charged = 0
    if doc.schema.len > 0:
      diagnostics.add(validated(doc, buffer, compiled, unavailable,
          registry, options, budget))
  discard readSchemas(recovering, lines, sourceUri, onEvent,
      proc (line: int, text: string) = discard, onDocument)
  diagnostics

proc validated(doc: DocumentSchema, buffer: BufferYamlStream,
    compiled: var Table[string, JsonSchema],
    unavailable: var Table[string, string], registry: SchemaRegistry,
    options: ValidationOptions, budget: MemoryBudget): seq[Diagnostic] =
  ## The diagnostics of the document ``doc`` whose events are in
  ## ``buffer``. ``budget`` is charged for its DOM while it is validated.
  let index = doc.index
  var charged = 0
  defer: budget.release(charged)
  block:
    let applied = doc.schemas
    var root: YamlNode
    try:
      var docEvents = YamlStream(buffer)
      charged = construct(docEvents, root, budget)
    except YamlStreamError as e:
      # a document that does not fit is an error of the input, not of it
      if not memoryLimitError(e).isNil: raise memoryLimitError(e)
      result.add(Diagnostic(rule: "schema-unavailable",
          severity: severityWarning, startPos: applied[0].startPos,
          endPos: applied[0].endPos,
          message: "cannot validate document " & $(index + 1) & ": " & e.msg))
      return
    except CatchableError as e:
      result.add(Diagnostic(rule: "schema-unavailable",
          severity: severityWarning, startPos: applied[0].startPos,
          endPos: applied[0].endPos,
          message: "cannot validate document " & $(index + 1) & ": " & e.msg))
      return
    # valid against all of them: each is reported on its own
    for declared in applied:
      let uri = declared.uri
      if uri.len == 0: continue
      if uri notin compiled and uri notin unavailable:
        try: compiled[uri] = registry.compile(uri)
        except JsonSchemaError as e: unavailable[uri] = e.msg
      if uri in unavailable:
        result.add(Diagnostic(rule: "schema-unavailable",
            severity: severityWarning, startPos: declared.startPos,
            endPos: declared.endPos,
            message: "cannot use schema " & uri & ": " & unavailable[uri]))
        continue
      var validation: ValidationResult
      try: validation = compiled[uri].validate(root, options)
      except JsonSchemaError as e:
        result.add(Diagnostic(rule: "schema-unavailable",
            severity: severityWarning, startPos: declared.startPos,
            endPos: declared.endPos,
            message: "cannot validate against " & uri & ": " & e.msg))
        continue
      if validation.valid: continue
      var leaves: seq[OutputUnit]
      leafErrors(validation.outputTree, leaves)
      for unit in leaves:
        let (startPos, endPos) = root.rangeOf(unit.instanceLocation,
            root.startPos)
        result.add(Diagnostic(rule: "schema-validation",
            severity: severityError, startPos: startPos, endPos: endPos,
            message: unit.error & " (" & unit.keywordLocation & " in " &
                uri & ")"))

proc validateDocuments*(source: string, registry: SchemaRegistry,
    sourceUri = "", options = ValidationOptions()): seq[Diagnostic] =
  ## Validates every valid document of ``source`` that declares a schema.
  ## ``sourceUri`` resolves relative schema references.
  validateWith(initYamlParser(sourceUri = sourceUri).parseRecovering(source),
      newStringStream(source), sourceUri, registry, options, nil)

proc validateDocuments*(src: YamlSource, registry: SchemaRegistry,
    sourceUri = "", options = ValidationOptions()): seq[Diagnostic] =
  ## Like the `string` variant, for input of any size: one document is held
  ## at a time. ``src`` is read twice, so it must have random access; a
  ## stream is read into memory.
  if not src.randomAccess:
    return validateDocuments(src.readAll("validating " & src.name), registry,
        sourceUri, options)
  validateWith(initYamlParser(sourceUri = sourceUri, budget = src.budget).
        parseRecovering(newSourceStream(src)),
      newSourceStream(src), sourceUri, registry, options, src.budget)
