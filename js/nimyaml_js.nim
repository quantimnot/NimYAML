#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## The JavaScript face of NimYAML: what ``js/build.mjs`` compiles into
## ``dist/nimyaml.mjs``.
##
## Every proc here that is exported to JavaScript is named ``nimyaml_X``,
## and the build turns each into the ES module export ``X``; nothing else
## of the compiled program is visible. The modules a program imports,
## ``yaml.mjs``, ``cli.mjs`` and those of ``lsp/``, wrap these in the API
## a JavaScript caller expects. The procs are one compiled program, rather
## than a program per tool, because the tools contain one another (the
## ``yaml`` command has ``lint``, ``expand`` and ``lsp`` subcommands) and
## all contain most of the library: one program carries it once.
##
## The boundary carries strings only: JavaScript strings in, JSON text
## out. A value goes in as JSON text and becomes a `YamlNode`, and a node
## comes out as JSON text written by the library's JSON presenter, so no
## part of the boundary converts between Nim and JavaScript objects field
## by field. Every result is an *envelope*, ``{"ok": RESULT}`` or
## ``{"error": {...}}``, rather than an exception: a Nim exception reaches
## JavaScript as an object of the Nim runtime, and the wrappers would have
## to know its shape. The error names its kind and, for an error in the
## input, its line and column, which the wrappers put on a ``YamlError``.
##
## Files and standard streams go through the host installed with
## `nimyaml_installHost` (see `yaml/private/jshost`).

import std/[json, jsffi, options, strutils, tables]
import std/streams except newFileStream, openFileStream
import ../yaml
import ../yaml/[dom, stream, jsonpath, jsonpatch, mergepatch, diff, schemainfer, jcs,
    jsonschema, lint, portable, edit, presenter]
import ../yaml/private/jshost
from ../yaml/hints import guessType, TypeHint
import ../tools/[yamllsp, yamlcli]

# envelopes

proc rootCause(e: ref Exception): ref Exception =
  ## The innermost error: streams wrap the error of the parser they read.
  result = e
  while not result.parent.isNil and result of YamlStreamError:
    result = result.parent

proc errorEnvelope(e: ref Exception): cstring =
  let cause = rootCause(e)
  var error = %*{"kind": $cause.name, "message": cause.msg}
  if cause of YamlLoadingError:
    let loading = (ref YamlLoadingError)(cause)
    error["line"] = %int(loading.mark.line)
    error["column"] = %int(loading.mark.column)
    error["lineContent"] = %loading.lineContent
  cstring($(%*{"error": error}))

proc okEnvelope(json: string): cstring =
  ## ``json`` is JSON text already.
  cstring("{\"ok\":" & json & "}")

template envelope(body: untyped): cstring =
  # Defects too: a bug should reach JavaScript as an error with a message,
  # not as an object of the Nim runtime
  try: okEnvelope(body)
  except Exception as e: errorEnvelope(e)

# values

proc presented(node: YamlNode, dumper: Dumper, json: bool): string =
  ## ``node`` written as ``dumper`` says. A node keeps the style it was read
  ## in, all flow and quotes for a value from JSON, which is dropped so that
  ## the dumper decides. JSON needs its tags resolved (to tell 1 from "1");
  ## YAML keeps them implicit, and keeps quotes only on a string that would
  ## read as another type without them, as the yaml command does.
  let events = newBufferYamlStream()
  for e in represent(node, dumper.serialization):
    var e = e
    # A node keeps a quoted string as the tag ``?`` and its quoted style:
    # the style says "string", and goes. The non-specific tag ``!`` says it
    # without a style.
    if e.kind == yamlScalar and e.scalarProperties.tag == yTagQuestionMark and
        e.scalarStyle in {ssSingleQuoted, ssDoubleQuoted, ssLiteral, ssFolded}:
      e.scalarProperties.tag = yTagExclamationMark
    var n = e.normalized(resolveToCoreYamlTags = json)
    if not json and n.kind == yamlScalar and
        n.scalarProperties.tag in [yTagExclamationMark, yTagString] and
        guessType(n.scalarContent) != yTypeUnknown:
      n.scalarStyle = ssDoubleQuoted
    events.put(n)
  present(events, dumper.presentation)

proc jsonText(node: YamlNode): string =
  ## ``node`` as JSON text, on one line.
  var dumper = jsonDumper()
  dumper.presentation.maxLineLength = none(int)
  dumper.presentation.newlines = nlNone
  presented(node, dumper, json = true).strip()

proc nodeOf(json: cstring): YamlNode =
  loadAs[YamlNode]($json)

proc documents(text: string): seq[YamlNode] =
  loadMultiDoc(text, result)

proc jsonArray(nodes: openArray[YamlNode]): string =
  result = "["
  for i, node in nodes:
    if i > 0: result.add(',')
    result.add(node.jsonText)
  result.add(']')

# the library

proc nimyaml_installHost(host: JsObject) {.exportc.} =
  installHost(host)

proc nimyaml_loadAll(text: cstring): cstring {.exportc.} =
  ## The documents of the YAML (or JSON) ``text`` as JSON values.
  envelope(jsonArray(documents($text)))

proc nimyaml_dump(json: cstring, style: cstring): cstring {.exportc.} =
  ## The JSON value ``json`` as YAML in ``style``: ``default``, ``block``,
  ## ``minimal``, ``canonical``, ``explanatory`` or ``json``.
  envelope:
    let dumper = case $style
      of "", "default": Dumper()
      of "block": blockOnlyDumper()
      of "minimal": minimalDumper()
      of "canonical": canonicalDumper()
      of "explanatory": explanatoryDumper()
      of "json": jsonDumper()
      else: raise newException(ValueError, "unknown style: " & $style)
    $(%presented(nodeOf(json), dumper, json = $style == "json"))

proc diagnosticsJson(found: openArray[Diagnostic]): string =
  var list = newJArray()
  for d in found:
    list.add(%*{"rule": d.rule, "severity": $d.severity,
        "message": d.message,
        "start": {"line": int(d.startPos.line), "column": int(d.startPos.column)},
        "end": {"line": int(d.endPos.line), "column": int(d.endPos.column)}})
  $list

proc nimyaml_lint(text, config, uri: cstring): cstring {.exportc.} =
  ## The diagnostics of ``text`` under the lint config ``config`` (the text
  ## of a ``.nimyaml-lint.yaml``; empty for the defaults).
  envelope:
    let cfg = if config.len == 0: defaultConfig() else: parseLintConfig($config)
    diagnosticsJson(lint($text, cfg, $uri))

proc nimyaml_validate(instance, schema, format: cstring): cstring
    {.exportc.} =
  ## The JSON Schema output (``flag``, ``basic``, ``detailed`` or
  ## ``verbose``) of validating the JSON value ``instance`` against the
  ## JSON value ``schema``.
  envelope:
    let outputFormat = case $format
      of "flag": ofFlag
      of "", "basic": ofBasic
      of "detailed": ofDetailed
      of "verbose": ofVerbose
      else: raise newException(ValueError, "unknown output format: " & $format)
    jsonText(compile(nodeOf(schema)).validate(nodeOf(instance)).toYaml(
        outputFormat))

proc nimyaml_query(json, path: cstring): cstring {.exportc.} =
  ## The nodes the JSONPath ``path`` selects in the JSON value ``json``,
  ## each as ``{"path": NORMALIZED_PATH, "value": VALUE}``.
  envelope:
    var parts: seq[string]
    for found in queryLocated(nodeOf(json), $path):
      parts.add("{\"path\":" & $(%found.path) & ",\"value\":" &
          found.node.jsonText & "}")
    "[" & parts.join(",") & "]"

proc nimyaml_applyPatch(json, patch: cstring): cstring {.exportc.} =
  ## The JSON value ``json`` changed by the JSON Patch ``patch``.
  envelope(applyJsonPatch(nodeOf(json), nodeOf(patch)).jsonText)

proc nimyaml_applyMergePatch(json, patch: cstring): cstring {.exportc.} =
  envelope(applyMergePatch(nodeOf(json), nodeOf(patch)).jsonText)

proc nimyaml_createMergePatch(source, target: cstring): cstring {.exportc.} =
  envelope(createMergePatch(nodeOf(source), nodeOf(target)).jsonText)

proc nimyaml_diff(old, new: cstring): cstring {.exportc.} =
  ## The JSON Patch that turns the JSON value ``old`` into ``new``.
  envelope(toJsonPatch(diff(nodeOf(old), nodeOf(new))).jsonText)

proc nimyaml_inferSchema(json: cstring): cstring {.exportc.} =
  ## The JSON Schema of the documents of the JSON array ``json``.
  envelope:
    let all = nodeOf(json)
    if all.kind != ySequence:
      raise newException(ValueError, "expected an array of documents")
    inferSchema(all.elems).jsonText

proc nimyaml_canonicalize(json: cstring): cstring {.exportc.} =
  ## The JSON Canonicalization Scheme (RFC 8785) form of the JSON value.
  envelope($(%canonicalJson(nodeOf(json))))

proc nimyaml_expandDirectives(text, uri: cstring): cstring {.exportc.} =
  ## ``text`` with NimYAML's ``%GLOBAL`` and ``%SCHEMA`` directives
  ## expanded, so that any YAML processor reads it the same way.
  envelope($(%expandDirectives($text, sourceUri = $uri)))

proc nimyaml_assign(text, path, value: cstring): cstring {.exportc.} =
  ## ``text`` with each node the JSONPath ``path`` selects replaced by the
  ## YAML ``value``, keeping the rest of the text as it is, as
  ## ``{"text": TEXT, "count": NODES}``.
  envelope:
    let (edited, count) = assign($text, parseJsonPath($path), $value)
    $(%*{"text": edited, "count": count})

# the yaml command

proc nimyaml_runCli(args: cstring): int {.exportc.} =
  ## Runs the ``yaml`` command with the JSON array of arguments ``args``,
  ## on the host's files and standard streams, and returns its exit code.
  var list: seq[string]
  try:
    for a in parseJson($args): list.add(a.getStr())
    result = yamlcli.run(list)
  except Exception as e:
    stderr.writeLine("yaml: " & e.msg)
    when not defined(release): stderr.write(e.getStackTrace())
    result = 2
  stdout.flushFile()
  stderr.flushFile()

# the language server core

type LspCore = ref object
  server: Server
  persist: bool ## whether the driver saves the open documents

proc nimyaml_lspNew(): LspCore {.exportc.} =
  LspCore()

proc nimyaml_lspStep(core: LspCore, batch: cstring): cstring {.exportc.} =
  ## Handles the JSON array of messages ``batch`` as one batch (see
  ## `handleBatch`) and returns ``{"out": MESSAGES, "save": [{"uri", "text"}],
  ## "exited": BOOL, "exitCode": N}``. ``$/nimyaml/configure {"persist":
  ## BOOL}``, a message of the driver's own, says whether to ``save`` the
  ## documents a batch opens or changes.
  try:
    var messages: seq[JsonNode]
    var touched: seq[string]
    for msg in parseJson($batch):
      let meth = msg{"method"}.getStr()
      if meth == "$/nimyaml/configure":
        core.persist = msg{"params"}{"persist"}.getBool()
        continue
      if meth in ["textDocument/didOpen", "textDocument/didChange"]:
        let uri = msg{"params"}{"textDocument"}{"uri"}.getStr()
        if uri notin touched: touched.add(uri)
      messages.add(msg)
    let output = core.server.handleBatch(messages)
    var save = newJArray()
    if core.persist:
      for uri in touched:
        let (open, text) = core.server.documentText(uri)
        if open: save.add(%*{"uri": uri, "text": text})
    okEnvelope($(%*{"out": output, "save": save,
        "exited": core.server.exited, "exitCode": core.server.exitCode}))
  except Exception as e:
    errorEnvelope(e)
