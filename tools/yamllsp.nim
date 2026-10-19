#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamllsp: a language server for YAML, built on NimYAML.
##
## Speaks JSON-RPC 2.0 over stdin/stdout with full document sync. When a
## document is opened, changed or saved, it is linted with the
## ``.nimyaml-lint.yaml`` found by walking up from the document's directory
## (defaults for documents without a ``file://`` URI), its documents are
## validated against the JSON Schemas they declare (``file:`` schemas only;
## the server never accesses the network), and the diagnostics are
## published. Saving a ``.nimyaml-lint.yaml`` reloads the configs and
## republishes the diagnostics of all open documents.
##
## The other features are about directives, the part of YAML editors know
## least about, and NimYAML's ``%GLOBAL`` and ``%SCHEMA`` in particular,
## whose effect is not visible where it applies:
##
## * completion of directive names after ``%`` and of the directives
##   ``%GLOBAL`` can wrap after ``%GLOBAL``,
## * hover on a directive: its effective value and whether it is global or
##   per-document, where a global one is overridden and what a
##   per-document one overrides,
## * hover on a ``---`` or ``...`` marker: the directives in effect for that
##   document, and its schema with the source it comes from,
## * go-to-definition and document links on schema references.
##
## They work on what the parser reports per document (the ``directives`` of
## each ``yamlStartDoc`` event) rather than on the text, so they agree with
## how the document is actually read. Documents with syntax errors are
## dropped by error recovery and have no such information.

import std/[json, os, streams, strutils, tables, uri]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[data, parser, stream, lint, jsonschema, documentschema,
    schemavalidation]

type
  ConfigEntry = tuple[config: LintConfig, error: string]

  Server* = object
    docs: Table[string, string]        # uri -> text
    configs: Table[string, ConfigEntry] # directory -> config
    shutdownRequested: bool
    exited*: bool
    exitCode*: int

const
  methodNotFound = -32601
  internalError = -32603

proc readMessage*(s: Stream): JsonNode =
  ## Reads one ``Content-Length`` framed message. Returns nil at the end of
  ## the input. Raises ``ValueError`` if the header has no
  ## ``Content-Length`` and ``JsonParsingError`` for an invalid body.
  var
    length = -1
    line: string
  while true:
    if not s.readLine(line): return nil
    line.stripLineEnd()
    if line.len == 0: break
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip().toLowerAscii() == "content-length":
      length = parseInt(line[colon + 1 .. ^1].strip())
  if length < 0: raise newException(ValueError, "missing Content-Length")
  let body = s.readStr(length)
  if body.len < length: return nil
  parseJson(body)

proc frame*(msg: JsonNode): string =
  ## ``msg`` with a ``Content-Length`` header.
  let body = $msg
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc utf16Column*(line: string, byteColumn: Positive): int =
  ## The 0-based UTF-16 offset of the 1-based byte column ``byteColumn`` of
  ## ``line``. Columns beyond the end of the line count one unit per byte.
  let stop = byteColumn - 1
  var i = 0
  while i < stop and i < line.len:
    let c = ord(line[i])
    if c >= 0xF0:
      result += 2
      i += 4
    elif c >= 0xE0:
      inc(result)
      i += 3
    elif c >= 0xC0:
      inc(result)
      i += 2
    else:
      inc(result)
      inc(i)
  if stop > i: result += stop - i

proc byteColumn*(line: string, utf16: int): int =
  ## The 1-based byte column of the 0-based UTF-16 offset ``utf16`` in
  ## ``line`` (the inverse of `utf16Column`).
  var
    units = 0
    i = 0
  while i < line.len and units < utf16:
    let c = ord(line[i])
    if c >= 0xF0:
      units += 2
      i += 4
    elif c >= 0xE0:
      inc(units)
      i += 3
    elif c >= 0xC0:
      inc(units)
      i += 2
    else:
      inc(units)
      inc(i)
  result = min(i, line.len) + 1 + max(utf16 - units, 0)

proc lspPosition(lines: seq[string], m: Mark): JsonNode =
  let text = if m.line <= lines.len: lines[m.line - 1] else: ""
  %*{"line": m.line - 1, "character": utf16Column(text, m.column)}

proc toLsp*(d: Diagnostic, lines: seq[string]): JsonNode =
  ## ``d`` as an LSP diagnostic; ``lines`` are the lines of the document.
  let severity =
    case d.severity
    of severityError: 1
    of severityWarning: 2
    of severityInfo: 3
  %*{"range": {"start": lspPosition(lines, d.startPos),
               "end": lspPosition(lines, d.endPos)},
     "severity": severity, "source": "nimyaml", "code": d.rule,
     "message": d.message}

proc lspRange(lines: seq[string], startPos, endPos: Mark): JsonNode =
  %*{"start": lspPosition(lines, startPos), "end": lspPosition(lines, endPos)}

proc documentPath(uri: string): string =
  const scheme = "file://"
  if uri.startsWith(scheme): decodeUrl(uri[scheme.len .. ^1], decodePlus = false)
  else: ""

proc configFor(s: var Server, uri: string): ConfigEntry =
  let path = documentPath(uri)
  if path.len == 0: return (defaultConfig(), "")
  let dir = path.parentDir()
  if dir notin s.configs:
    var entry: ConfigEntry = (defaultConfig(), "")
    let configPath = findLintConfig(dir)
    if configPath.len > 0:
      try:
        entry.config = loadLintConfig(configPath)
      except LintConfigError as e:
        entry.error = e.msg
    s.configs[dir] = entry
  s.configs[dir]

proc sourceUriOf(uri: string): string =
  ## The base for relative schema references of the document ``uri``: the
  ## URI itself if it is hierarchical (``file://``, ``https://``), else
  ## none (``untitled:`` buffers have no location).
  if "://" in uri: uri else: ""

# Directive information
#
# The language features below need, per document of a text, what the parser
# knows about its directives and markers. `analyze` collects it from one
# parse of the text.

type
  DocumentInfo = object
    index: int
    startLine: int          ## first line of the document's source
    markerLine, endLine: int ## lines of `---` and `...`; 0 if absent
    directives: DocumentDirectives
    schema: DocumentSchema

  Analysis = object
    documents: seq[DocumentInfo]
    lines: seq[string]

proc analyze(text, uri: string): Analysis =
  ## Parses ``text`` once (with error recovery) and records, per valid
  ## document, its markers, its directives and its schema sources.
  for _, line in text.sourceLines: result.lines.add(line)
  let sourceUri = sourceUriOf(uri)
  let schemas = documentSchemas(text, sourceUri)
  let events = initYamlParser(sourceUri = sourceUri).parseRecovering(text)
  for e in events:
    case e.kind
    of yamlStartDoc:
      let start = events.documentStart
      var info = DocumentInfo(index: start.index, startLine: start.line,
          markerLine: if e.explicitDirectivesEnd: int(e.startPos.line) else: 0,
          directives: e.directives)
      for schema in schemas:
        if schema.index == start.index: info.schema = schema
      result.documents.add(info)
    of yamlEndDoc:
      if e.explicitDocumentEnd: result.documents[^1].endLine = e.startPos.line
    else: discard

proc declarationsAt(a: Analysis, line: int): seq[tuple[doc: int, d: Directive]] =
  ## The declarations on ``line``; a global one is reported once, with the
  ## first document.
  for i, doc in a.documents:
    if doc.directives.isNil: continue
    for d in doc.directives.declarations:
      if d.startPos.line == line and (d.origin == doDocument or i == 0):
        result.add((i, d))

proc describe(d: Directive): string =
  ## ``d`` as it would be written on its own line.
  case d.kind
  of dkYaml: "%YAML " & d.version
  of dkTag: "%TAG " & d.handle & " " & d.prefix
  of dkSchema: "%SCHEMA " & d.reference

proc documentNumbers(numbers: seq[int]): string =
  ## 0-based document indexes as the 1-based numbers editors show.
  var names: seq[string]
  for n in numbers: names.add($(n + 1))
  names.join(", ")

proc hoverForDirective(a: Analysis, doc: int, d: Directive): string =
  ## Markdown: the effective value of ``d`` and where it applies.
  result = "**`" & d.describe & "`**\n\n"
  case d.kind
  of dkYaml: result.add("YAML version " & d.version & ".\n\n")
  of dkTag: result.add("Tags `" & d.handle & "suffix` stand for `" &
      d.prefix & "suffix`.\n\n")
  of dkSchema: result.add("Schema: <" & d.uri & ">\n\n")
  if d.origin == doGlobal:
    var overriddenIn: seq[int]
    for i, other in a.documents:
      if other.directives.isNil: continue
      for g in other.directives.declarations:
        if g.origin == doGlobal and g.startPos == d.startPos and g.overridden:
          overriddenIn.add(i)
    result.add("Global (`%GLOBAL`): applies to all " & $a.documents.len &
        " documents of the stream")
    if overriddenIn.len == 1:
      result.add(", except document " & overriddenIn.documentNumbers &
          ", which overrides it")
    elif overriddenIn.len > 1:
      result.add(", except documents " & overriddenIn.documentNumbers &
          ", which override it")
    result.add(".")
  else:
    result.add("Applies to document " & $(doc + 1) & " only.")
    for g in a.documents[doc].directives.declarations:
      if g.origin == doGlobal and g.overridden and g.kind == d.kind and
          (d.kind != dkTag or g.handle == d.handle):
        result.add(" Overrides the global `" & g.describe & "` (line " &
            $g.startPos.line & ").")
  if d.kind == dkSchema:
    let winner = a.documents[doc].schema.sources
    if winner.len > 0 and winner[0].startPos != d.valueStart:
      result.add("\n\nNot used for document " & $(doc + 1) & ": its schema " &
          "comes from the " & $winner[0].kind & " (line " &
          $winner[0].startPos.line & ").")

proc hoverForDocument(a: Analysis, doc: int): string =
  ## Markdown: the directives and the schema in effect for document ``doc``.
  let info = a.documents[doc]
  result = "**Document " & $(doc + 1) & "**\n"
  var any = false
  if not info.directives.isNil:
    for d in info.directives.declarations:
      if d.overridden or d.kind == dkSchema: continue
      any = true
      result.add("\n- `" & d.describe & "` (" &
          (if d.origin == doGlobal: "global" else: "document") & ", line " &
          $d.startPos.line & ")")
  if info.schema.sources.len > 0:
    let winner = info.schema.sources[0]
    any = true
    result.add("\n- schema <" & (if winner.uri.len > 0: winner.uri
        else: winner.reference) & "> (" & $winner.kind & ", line " &
        $winner.startPos.line & ")")
  if not any: result.add("\nNo directives; YAML 1.2 defaults.")

proc hover(s: Server, uri: string, line, character: int): JsonNode =
  ## A directive line explains that directive (or why it is ignored); a
  ## ``---`` or ``...`` marker lists what is in effect for its document.
  if uri notin s.docs: return newJNull()
  let a = analyze(s.docs[uri], uri)
  let markLine = line + 1
  if line >= a.lines.len: return newJNull()
  let text = a.lines[line]
  if text.startsWith("%"):
    let found = a.declarationsAt(markLine)
    if found.len > 0:
      let (doc, d) = found[0]
      return %*{"contents": {"kind": "markdown",
          "value": a.hoverForDirective(doc, d)},
          "range": lspRange(a.lines, d.startPos, d.endPos)}
    # an ignored directive: say why
    for doc in a.documents:
      if doc.directives.isNil: continue
      for i in doc.directives.issues:
        if i.startPos.line == markLine:
          return %*{"contents": {"kind": "markdown", "value":
              "Ignored: " & i.message & " (`" & $i.kind & "`)"},
              "range": lspRange(a.lines, i.startPos, i.endPos)}
  for i, doc in a.documents:
    # only on the marker itself, not on content that shares its line
    if markLine in [doc.markerLine, doc.endLine] and character < 3 and
        (text.startsWith("---") or text.startsWith("...")):
      return %*{"contents": {"kind": "markdown",
          "value": a.hoverForDocument(i)},
          "range": lspRange(a.lines, Mark(line: markLine, column: 1),
              Mark(line: markLine, column: 4))}
  newJNull()

const
  directiveNames = [
    ("YAML", "The YAML version of the document (YAML 1.2, §6.8.1)"),
    ("TAG", "A tag handle and the prefix it stands for (YAML 1.2, §6.8.2)"),
    ("SCHEMA", "The JSON Schema of the document (NimYAML)"),
    ("GLOBAL", "Makes a YAML, TAG or SCHEMA directive apply to every " &
        "document; only before the first document (NimYAML)")]

proc completion(s: Server, uri: string, line, character: int): JsonNode =
  ## Directive names after ``%``; after ``%GLOBAL``, the directives it can
  ## wrap.
  result = newJArray()
  if uri notin s.docs: return
  var text = ""
  var n = 0
  for _, l in s.docs[uri].sourceLines:
    if n == line:
      text = l
      break
    inc(n)
  let before = text[0 ..< min(byteColumn(text, character) - 1, text.len)]
  var names: seq[(string, string)]
  if before.startsWith("%GLOBAL") and before.len > "%GLOBAL".len and
      before["%GLOBAL".len] in {' ', '\t'} and
      before["%GLOBAL".len .. ^1].strip().allCharsInSet(Letters):
    names = @[directiveNames[0], directiveNames[1], directiveNames[2]]
  elif before.startsWith("%") and before[1 .. ^1].allCharsInSet(Letters):
    names = @directiveNames
  for (name, doc) in names:
    result.add(%*{"label": name, "kind": 14, "detail": doc,
        "insertText": name})

proc schemaReferences(a: Analysis): seq[tuple[startPos, endPos: Mark,
    target: string]] =
  ## Every resolvable schema reference of the text, each once.
  for doc in a.documents:
    for source in doc.schema.sources:
      if source.uri.len == 0: continue
      var seen = false
      for r in result:
        if r.startPos == source.startPos: seen = true
      if not seen: result.add((source.startPos, source.endPos, source.uri))

proc definition(s: Server, uri: string, line, character: int): JsonNode =
  ## The schema a reference under the cursor points to.
  if uri notin s.docs: return newJNull()
  let a = analyze(s.docs[uri], uri)
  if line >= a.lines.len: return newJNull()
  let column = byteColumn(a.lines[line], character)
  for r in a.schemaReferences:
    if r.startPos.line == line + 1 and column >= r.startPos.column and
        column <= r.endPos.column:
      return %*{"uri": r.target, "range": {"start": {"line": 0, "character": 0},
          "end": {"line": 0, "character": 0}}}
  newJNull()

proc documentLinks(s: Server, uri: string): JsonNode =
  ## Every resolvable schema reference as a link to its schema.
  result = newJArray()
  if uri notin s.docs: return
  let a = analyze(s.docs[uri], uri)
  for r in a.schemaReferences:
    result.add(%*{"range": lspRange(a.lines, r.startPos, r.endPos),
        "target": r.target})

proc publish(s: var Server, uri: string): JsonNode =
  var diagnostics = newJArray()
  if uri in s.docs:
    let text = s.docs[uri]
    let (config, error) = s.configFor(uri)
    if error.len > 0:
      diagnostics.add(%*{"range": {"start": {"line": 0, "character": 0},
                                   "end": {"line": 0, "character": 1}},
                         "severity": 1, "source": "nimyaml", "code": "config",
                         "message": "invalid lint config: " & error})
    var lines: seq[string]
    for _, line in text.sourceLines: lines.add(line)
    let sourceUri = sourceUriOf(uri)
    for d in lint(text, config, sourceUri): diagnostics.add(d.toLsp(lines))
    # a fresh registry per publish, so that edits of schema files take
    # effect on the next change
    let registry = newSchemaRegistry(fileSchemaLoader())
    for d in validateDocuments(text, registry, sourceUri):
      diagnostics.add(d.toLsp(lines))
  %*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
     "params": {"uri": uri, "diagnostics": diagnostics}}

proc respond(id, value: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "result": value}

proc respondError(id: JsonNode, code: int, message: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id,
     "error": {"code": code, "message": message}}

proc handle*(s: var Server, msg: JsonNode): seq[JsonNode] =
  ## Handles one message and returns the messages to send. Raises on
  ## malformed messages.
  let
    meth = msg{"method"}.getStr()
    id = msg{"id"}
    params = msg{"params"}
  case meth
  of "initialize":
    result.add(respond(id, %*{
      "capabilities": {"textDocumentSync": {"openClose": true, "change": 1,
                                            "save": {"includeText": false}},
                       "completionProvider": {"triggerCharacters": ["%", " "]},
                       "hoverProvider": true, "definitionProvider": true,
                       "documentLinkProvider": {"resolveProvider": false}},
      "serverInfo": {"name": "yamllsp"}}))
  of "textDocument/didOpen":
    let doc = params["textDocument"]
    let uri = doc["uri"].getStr()
    s.docs[uri] = doc["text"].getStr()
    result.add(s.publish(uri))
  of "textDocument/didChange":
    let uri = params["textDocument"]["uri"].getStr()
    let changes = params["contentChanges"]
    if changes.len > 0: s.docs[uri] = changes[changes.len - 1]["text"].getStr()
    result.add(s.publish(uri))
  of "textDocument/didSave":
    let uri = params["textDocument"]["uri"].getStr()
    if documentPath(uri).extractFilename() == configFileName:
      s.configs.clear()
      var uris: seq[string]
      for open in s.docs.keys: uris.add(open)
      for open in uris: result.add(s.publish(open))
    elif uri in s.docs:
      result.add(s.publish(uri))
  of "textDocument/didClose":
    let uri = params["textDocument"]["uri"].getStr()
    s.docs.del(uri)
    result.add(s.publish(uri))
  of "textDocument/completion", "textDocument/hover",
     "textDocument/definition":
    let
      uri = params["textDocument"]["uri"].getStr()
      position = params["position"]
      line = position["line"].getInt()
      character = position["character"].getInt()
    let answer = case meth
      of "textDocument/completion": s.completion(uri, line, character)
      of "textDocument/hover": s.hover(uri, line, character)
      else: s.definition(uri, line, character)
    result.add(respond(id, answer))
  of "textDocument/documentLink":
    result.add(respond(id, s.documentLinks(params["textDocument"]["uri"].getStr())))
  of "shutdown":
    s.shutdownRequested = true
    result.add(respond(id, newJNull()))
  of "exit":
    s.exited = true
    s.exitCode = if s.shutdownRequested: 0 else: 1
  else:
    if not id.isNil:
      result.add(respondError(id, methodNotFound, "method not found: " & meth))

proc serve*(input: Stream, output: File): int =
  ## Serves messages from ``input`` until ``exit`` or the end of the input.
  ## Returns the exit code.
  var server: Server
  while not server.exited:
    var msg: JsonNode
    try:
      msg = readMessage(input)
    except CatchableError as e:
      stderr.writeLine("yamllsp: " & e.msg)
      continue
    if msg.isNil: return 1
    var replies: seq[JsonNode]
    try:
      replies = server.handle(msg)
    except CatchableError as e:
      if msg{"id"}.isNil: stderr.writeLine("yamllsp: " & e.msg)
      else: replies = @[respondError(msg{"id"}, internalError, e.msg)]
    for reply in replies: output.write(frame(reply))
    output.flushFile()
  server.exitCode

when isMainModule:
  quit(serve(newFileStream(stdin), stdout))
