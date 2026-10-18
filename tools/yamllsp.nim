#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamllsp: a language server that publishes NimYAML lint diagnostics.
##
## Speaks JSON-RPC 2.0 over stdin/stdout with full document sync. When a
## document is opened, changed or saved, it is linted with the
## ``.nimyaml-lint.yaml`` found by walking up from the document's directory
## (defaults for documents without a ``file://`` URI) and the diagnostics
## are published. Saving a ``.nimyaml-lint.yaml`` reloads the configs and
## republishes the diagnostics of all open documents.

import std/[json, os, streams, strutils, tables, uri]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[data, lint]

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
    for d in lint(text, config): diagnostics.add(d.toLsp(lines))
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
                                            "save": {"includeText": false}}},
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
