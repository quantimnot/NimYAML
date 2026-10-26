#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==========================
## Module yaml/documentschema
## ==========================
##
## Decides which JSON Schema each document of a YAML stream declares for
## itself. Four conventions exist, and a document may use several of them;
## this module ranks them, highest first:
##
## 1. a ``%SCHEMA`` directive of the document,
## 2. a ``%GLOBAL SCHEMA`` directive of the stream,
## 3. a ``# yaml-language-server: $schema=<uri>`` modeline comment, the
##    convention of the YAML language server used by many editors,
## 4. a top-level ``$schema`` key whose value is a string.
##
## The highest one present wins. A directive may name several schemas
## (``%SCHEMA a.json b.json``), and then the document must be valid against
## each of them, as with ``allOf``; a modeline or key names one, and of
## several modelines the first wins. Schemas from different sources are
## never combined, and schemas are never merged keyword by keyword, because
## such a merge has no well-defined meaning and would hide that the
## document contradicts itself. When a document has sources that are not
## used, a ``schema-source`` diagnostic (severity info) names the winners,
## so that the ignored ones are not silently ignored.
##
## Directives are ranked above the other two because they are the only
## sources that are part of the YAML presentation rather than of its
## comments or content, and per-document beats global for the same reason
## per-document ``%TAG`` beats global ``%TAG``. A modeline beats a ``$schema``
## key because the key is content: in a JSON Schema document, ``$schema``
## names the meta-schema, which is exactly the schema to validate it with,
## but a document may also contain a ``$schema`` member for other reasons.
##
## Relative references of all sources resolve against the source URI of the
## stream (RFC 3986). The directives are resolved by the parser; a modeline
## or key that cannot be resolved (no source URI) is reported as
## ``unresolvable-schema-uri``, like the directives.
##
## A modeline belongs to the document whose source contains it: the span
## from the document's start (its first directive, ``---`` or content line,
## see `YamlDocumentStart`) up to the start of the next document. A modeline
## above the first document therefore belongs to the first document.
##
## The work is done by a `SchemaCollector`, which is fed the events and the
## lines of the source, in any interleaving, so that the single-pass `lint`
## engine can run it next to its rules. `documentSchemas` runs it on a
## string.

import std/strutils
import data, parser, stream, diagnostics, hints, private/uri, source
import std/streams

type
  SchemaSourceKind* = enum
    ## The ways a document can name its schema, in order of precedence.
    sskDocumentDirective = "%SCHEMA"
    sskGlobalDirective = "%GLOBAL SCHEMA"
    sskModeline = "modeline"
    sskSchemaKey = "$schema key"

  SchemaSource* = object
    kind*: SchemaSourceKind
    reference*: string ## as written
    uri*: string       ## resolved; empty if it could not be resolved
    startPos*, endPos*: Mark ## the reference in the source

  DocumentSchema* = object
    ## The schema sources of one document, highest precedence first.
    index*: int        ## 0-based index of the document in the stream
    position*: Mark    ## where the document starts
    sources*: seq[SchemaSource]

  SchemaCollector* = object
    ## Collects the schema sources of the documents of a stream. Feed it with
    ## `onDocumentStart` (for ``yamlStartDoc``), `onEvent` (for all other
    ## events) and `onLine` (for every line), then call `finish`.
    sourceUri: string
    documents: seq[DocumentSchema]
    startLines, endLines: seq[int]
    # documents dropped by error recovery: the line of the error and the
    # line the next document starts on (0 if none followed)
    dropped: seq[tuple[errorLine, resumeLine: int]]
    modelines: seq[tuple[line: int, source: SchemaSource]]
    # root mapping of the current document: nesting depth, number of
    # complete nodes directly in the root mapping, whether the last complete
    # one was a ``$schema`` key
    depth: int
    rootIsMapping: bool
    rootItems: int
    afterSchemaKey: bool

proc initSchemaCollector*(sourceUri = ""): SchemaCollector =
  ## ``sourceUri`` resolves relative modelines and ``$schema`` values.
  SchemaCollector(sourceUri: sourceUri)

proc onDocumentStart*(c: var SchemaCollector, e: Event,
    start: YamlDocumentStart) =
  ## Starts a document. ``start`` is the stream's `documentStart` after
  ## ``e``. The document's directive sources are taken from ``e``.
  var doc = DocumentSchema(index: start.index, position: e.startPos)
  if not e.directives.isNil:
    for d in e.directives.declarations:
      if d.kind != dkSchema: continue
      doc.sources.add(SchemaSource(
          kind: if d.origin == doGlobal: sskGlobalDirective
                else: sskDocumentDirective,
          reference: d.reference, uri: d.uri, startPos: d.valueStart,
          endPos: d.valueEnd))
  c.documents.add(doc)
  c.startLines.add(start.line)
  c.endLines.add(high(int))
  c.depth = 0
  c.rootIsMapping = false
  c.rootItems = 0
  c.afterSchemaKey = false

proc isString(e: Event): bool =
  ## Whether the scalar ``e`` is a string as JSON sees it: quoted, tagged
  ## ``!!str``, or plain with content that the core schema reads as a
  ## string (``42`` and ``true`` are not schema references).
  let tag = e.scalarProperties.tag
  tag == yTagExclamationMark or tag == yTagString or
      (tag == yTagQuestionMark and
       guessType(e.scalarContent) in {yTypeUnknown, yTypeTimestamp})

proc resolveReference(c: SchemaCollector, reference: string): string =
  ## Resolves a modeline or ``$schema`` reference like the parser resolves
  ## ``%SCHEMA``; empty if it is relative and there is no source URI.
  if reference.isAbsolute: reference
  elif c.sourceUri.len == 0: ""
  else: resolve(c.sourceUri, reference)

proc onEvent*(c: var SchemaCollector, e: Event) =
  ## Watches the root mapping of the current document for a ``$schema``
  ## member with a string value.
  if c.documents.len == 0: return
  let startsNode = e.kind in {yamlScalar, yamlAlias, yamlStartMap, yamlStartSeq}
  if startsNode and c.depth == 1 and c.rootIsMapping:
    let isKey = c.rootItems mod 2 == 0
    if not isKey and c.afterSchemaKey and e.kind == yamlScalar and
        e.isString:
      c.documents[^1].sources.add(SchemaSource(kind: sskSchemaKey,
          reference: e.scalarContent,
          uri: c.resolveReference(e.scalarContent),
          startPos: e.startPos, endPos: e.endPos))
    c.afterSchemaKey = isKey and e.kind == yamlScalar and
        e.scalarContent == "$schema"
  case e.kind
  of yamlStartMap, yamlStartSeq:
    if c.depth == 0: c.rootIsMapping = e.kind == yamlStartMap
    inc(c.depth)
  of yamlEndMap, yamlEndSeq:
    dec(c.depth)
    if c.depth == 1: inc(c.rootItems)
  of yamlScalar, yamlAlias:
    if c.depth == 1: inc(c.rootItems)
  of yamlEndDoc: c.endLines[^1] = e.endPos.line
  else: discard

proc onDocumentDropped*(c: var SchemaCollector, error: YamlDocumentError) =
  ## Tells the collector about a document that error recovery dropped, so
  ## that its modelines are not attributed to the document before it.
  c.dropped.add((error.error.mark.line,
      if error.resumedAt.offset < 0: 0 else: error.resumedAt.line))

const modelineKey = "yaml-language-server:"

proc onLine*(c: var SchemaCollector, line: int, text: string) =
  ## Recognizes ``# yaml-language-server: $schema=<uri>`` comments. Only
  ## comment lines qualify; the comment may be indented.
  let stripped = text.strip(trailing = false)
  if not stripped.startsWith("#"): return
  var rest = stripped[1 .. ^1].strip(trailing = false)
  if not rest.startsWith(modelineKey): return
  rest = rest[modelineKey.len .. ^1].strip(trailing = false)
  if not rest.startsWith("$schema="): return
  let reference = rest["$schema=".len .. ^1].strip().split({' ', '\t'})[0]
  if reference.len == 0: return
  let column = text.find("$schema=") + "$schema=".len + 1
  c.modelines.add((line, SchemaSource(kind: sskModeline, reference: reference,
      uri: c.resolveReference(reference),
      startPos: Mark(line: line, column: column),
      endPos: Mark(line: line, column: column + reference.len))))

proc finish*(c: var SchemaCollector): seq[DocumentSchema] =
  ## The schema sources of every document, sorted by precedence.
  for (line, source) in c.modelines:
    if c.documents.len == 0: break
    var owner = 0
    for i, startLine in c.startLines:
      if startLine <= line: owner = i
    # after the end of its owner, a modeline may belong to a dropped
    # document: one whose error comes after the owner's end and whose
    # region (up to where parsing resumed) contains the modeline
    var inDropped = false
    if line > c.endLines[owner]:
      for (errorLine, resumeLine) in c.dropped:
        if errorLine > c.endLines[owner] and
            (resumeLine == 0 or line < resumeLine):
          inDropped = true
    if not inDropped: c.documents[owner].sources.add(source)
  for doc in c.documents.mitems:
    var sorted: seq[SchemaSource]
    for kind in SchemaSourceKind:
      for s in doc.sources:
        if s.kind == kind: sorted.add(s)
    doc.sources = sorted
  result = c.documents

proc schemas*(doc: DocumentSchema): seq[SchemaSource] =
  ## The sources whose schemas ``doc`` is validated with, all of them: the
  ## references of the winning directive, or the winning modeline or key.
  if doc.sources.len == 0: return
  let kind = doc.sources[0].kind
  if kind in {sskModeline, sskSchemaKey}: return @[doc.sources[0]]
  for s in doc.sources:
    if s.kind == kind: result.add(s)

proc schema*(doc: DocumentSchema): string =
  ## The URI of the first schema that ``doc`` is validated with; empty if
  ## it declares none (or the winning declaration could not be resolved).
  if doc.sources.len > 0: doc.sources[0].uri else: ""

proc diagnostics*(documents: seq[DocumentSchema]): seq[Diagnostic] =
  ## ``schema-source`` for documents with several schema sources, and
  ## ``unresolvable-schema-uri`` for modelines and ``$schema`` values that
  ## could not be resolved. (Unresolvable directives are reported by the
  ## parser.)
  for doc in documents:
    for s in doc.sources:
      if s.uri.len == 0 and s.kind in {sskModeline, sskSchemaKey}:
        result.add(Diagnostic(rule: $diUnresolvableSchema,
            severity: severityError, startPos: s.startPos, endPos: s.endPos,
            message: "relative schema reference " & escape(s.reference) &
                " in the " & $s.kind &
                " cannot be resolved: the input has no source URI"))
    let winners = doc.schemas
    if doc.sources.len > winners.len:
      let winner = winners[0]
      var references, others: seq[string]
      for s in winners: references.add(escape(s.reference))
      for s in doc.sources[winners.len .. ^1]: others.add($s.kind)
      result.add(Diagnostic(rule: "schema-source", severity: severityInfo,
          startPos: winner.startPos, endPos: winner.endPos,
          message: "document " & $(doc.index + 1) & " is validated against " &
              references.join(" and ") & " from the " & $winner.kind &
              "; ignored: " & others.join(", ")))

proc documentSchemasOf(events: YamlRecoveringStream, lines: Stream,
    sourceUri: string): seq[DocumentSchema] =
  var c = initSchemaCollector(sourceUri)
  for e in events:
    if e.kind == yamlStartDoc: c.onDocumentStart(e, events.documentStart)
    else: c.onEvent(e)
  for n, text in lines.sourceLines: c.onLine(n, text)
  for error in events.errors: c.onDocumentDropped(error)
  result = c.finish()

proc documentSchemas*(source: string, sourceUri = ""): seq[DocumentSchema] =
  ## The schema sources of the valid documents of ``source``.
  documentSchemasOf(initYamlParser(sourceUri = sourceUri).
      parseRecovering(source), newStringStream(source), sourceUri)

proc documentSchemas*(src: YamlSource, sourceUri = ""): seq[DocumentSchema] =
  ## Like the `string` variant, for input of any size. ``src`` is read
  ## twice, so it must have random access; a stream is read into memory.
  if not src.randomAccess:
    return documentSchemas(src.readAll("reading " & src.name), sourceUri)
  documentSchemasOf(initYamlParser(sourceUri = sourceUri, budget = src.budget).
      parseRecovering(newSourceStream(src)), newSourceStream(src), sourceUri)
