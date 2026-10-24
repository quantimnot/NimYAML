#!/usr/bin/env nim r -d:release -d:lto --hints:off --warnings:off --processing:off
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yaml: NimYAML's command line tool. Build it as ``yaml`` with
## ``nim c -d:release -o:yaml tools/yamlcli.nim``.
##
## Usage: ``yaml COMMAND [OPTIONS] [ARGS]``; ``yaml help COMMAND`` describes
## a command:
##
## * ``lint``: diagnostics of all rules, and JSON Schema validation
## * ``validate``: only the diagnostics of violations of the YAML spec, and
##   JSON Schema validation
## * ``format``: rewrites YAML in a uniform style
## * ``convert`` (or ``as``, ``to``): converts between YAML, JSON, JSONC,
##   JSON Lines and CBOR
## * ``query`` (or just a JSONPath starting with ``$``): selects nodes with
##   an RFC 9535 JSONPath
## * ``expand``: makes ``%GLOBAL`` directives portable
## * ``lsp``: the language server, over stdio
## * ``help``: this overview, or the usage of a command
##
## Commands that take files read standard input without them. ``lint``,
## ``validate``, ``format`` and the language server are configured by the
## ``.yaml`` or ``.yaml.yaml`` file found by walking up from each file's
## directory (see `yaml/toolconfig <../yaml/toolconfig.html>`_).
##
## Exit code: 0 on success, 1 if an input is invalid or has error
## diagnostics (or, with ``format --check``, is not formatted), 2 for usage,
## I/O and config errors.

import std/[os, parseopt, streams, strutils]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[data, dom, dumping, loading, parser, presenter, stream, cbor,
    jsonpath, toolconfig]
import ../yaml/private/lex
from ../yaml/hints import guessType, TypeHint
import yamllint, yamlexpand, yamllsp

type
  DataFormat = enum
    dfYaml = "yaml", dfJson = "json", dfJsonc = "jsonc",
    dfJsonLines = "jsonl", dfCbor = "cbor"

  Input = tuple[name, content: string]

  UsageError = object of ValueError

const
  overview = """usage: yaml COMMAND [OPTIONS] [ARGS]

commands:
  lint      diagnostics of all lint rules and JSON Schema validation
  validate  only diagnostics of YAML spec violations, and JSON Schema
            validation
  format    rewrite YAML in a uniform style
  convert   convert between yaml, json, jsonc, jsonl and cbor (also: as, to)
  query     select nodes with a JSONPath (also: yaml '$...' [FILE...])
  expand    expand %GLOBAL directives into the documents
  lsp       the language server, over stdio
  help      this overview, or the usage of COMMAND

Commands that take files read standard input without them. Files are
configured by the nearest .yaml or .yaml.yaml file; see yaml help config."""

  lintUsage = """usage: yaml lint [--config:FILE] [--no-schema] [FILE...]

Prints the diagnostics of all lint rules, one per line, and validates the
documents against the JSON Schemas they declare (unless --no-schema, or
validate.schema is false in the config). --config:FILE uses FILE instead
of the nearest .yaml config. Exit code 1 if there are error diagnostics."""

  validateUsage = """usage: yaml validate [--config:FILE] [--no-schema] [FILE...]

Like yaml lint, but only with the rules that find violations of the YAML
spec (syntax errors, duplicate keys, undefined aliases and directive
issues), not the style rules, so that a file that validates is valid YAML
that conforms to its schemas."""

  formatUsage = """usage: yaml format [--write | --check] [--drop-comments] [--config:FILE]
                   [--style:STYLE] [--indent:N] [--line-length:N]
                   [--comment-indentation:node|source] [--comment-gap:N]
                   [--comment-blank-lines:keep|drop] [FILE...]

Rewrites YAML in the style of the format section of the config, and prints
it; with --write, the files are rewritten in place instead, and with
--check, the files that are not formatted are listed (exit code 1 if
there are any). Several files require --write or --check.

Comments are kept: a comment after content stays at the end of the line of
its node, and a comment line stays before the node it precedes or at the
end of the collection it ends. A collection that holds a comment is written
in block style. The minimal, json and json-lines styles have no room for
comments, so files with comments are refused with them unless
--drop-comments is given, which drops comments with any style.

--style:STYLE   default, minimal, explanatory, json, json-lines or block-only
--indent:N      spaces per indentation level
--line-length:N maximum line length; 0 for none
--comment-indentation:node|source
                indent comment lines like the node they precede or end
                (default), or keep their column in the input where it
                attaches them to the same node
--comment-gap:N spaces between content and a comment after it (default 2)
--comment-blank-lines:keep|drop
                whether a blank line before or after a comment line is kept
                (default keep)"""

  convertUsage = """usage: yaml convert [--from:FORMAT] TO [FILE...]
       yaml as TO [FILE...]  /  yaml to TO [FILE...]

Converts the documents of all files to one stream in the format TO: yaml,
json, jsonc (written as json), jsonl or cbor. The format of a file comes
from its extension (.json, .jsonc, .jsonl, .ndjson, .cbor; YAML
otherwise), standard input is YAML; --from:FORMAT sets it for all inputs.
YAML is written in the style of the format section of the config."""

  queryUsage = """usage: yaml query [--from:FORMAT] [--to:FORMAT] [--paths] PATH [FILE...]
       yaml PATH [FILE...]   (when PATH starts with $)

Applies the RFC 9535 JSONPath PATH to each document and writes the
selected nodes, each as a document, in the format --to (default: yaml; see
yaml help convert). With --paths, their Normalized Paths are printed
instead, one per line."""

  expandUsage = """usage: yaml expand [--modeline] [FILE]

Writes FILE (or standard input) with every %GLOBAL directive expanded into
the documents that inherit it, so that other YAML processors read the
documents as NimYAML does. With --modeline, %SCHEMA directives become
'# yaml-language-server: $schema=' comments."""

  lspUsage = """usage: yaml lsp [--stdio]

Starts the language server, speaking JSON-RPC over standard input and
output. Editors start it as the command `yaml` with the argument `lsp`."""

  helpUsage = """usage: yaml help [COMMAND]"""

  configHelp = """Configuration: the file .yaml or .yaml.yaml (not both) in a file's
directory or the nearest ancestor that has one; a legacy .nimyaml-lint.yaml
is read as its lint section. All keys are optional:

  lint:
    rules:                  # see the lint rules in NimYAML's README
      line-length: {level: warning, max: 100}
      truthy: {level: off}  # off, info, warning or error
  validate:
    schema: true            # validate against declared JSON Schemas
  format:
    style: default          # see yaml help format
    indentation: 2
    max-line-length: 80     # 0 for no limit
    comments: keep          # or drop
    comment-indentation: node  # or source
    comment-gap: 2
    comment-blank-lines: keep  # or drop"""

proc usageOf(command: string): string =
  case command
  of "lint": lintUsage
  of "validate": validateUsage
  of "format": formatUsage
  of "convert", "as", "to": convertUsage
  of "query": queryUsage
  of "expand": expandUsage
  of "lsp": lspUsage
  of "help": helpUsage
  of "config": configHelp
  else: ""

proc wantsHelp(args: seq[string]): bool =
  for arg in args:
    if arg in ["-h", "--help"]: return true
    if arg == "--": return false

iterator options(args: seq[string]): tuple[kind: CmdLineKind, key,
    val: string] =
  ## `getopt` of ``args``; that of an empty ``args`` would be the process's
  ## own command line.
  if args.len > 0:
    for option in getopt(args): yield option

proc fail(command: string) =
  raise newException(UsageError, usageOf(command))

# inputs

proc readInputs(files: seq[string]): seq[Input] =
  if files.len == 0: result.add(("<stdin>", stdin.readAll()))
  for file in files: result.add((file, readFile(file)))

proc formatOf(file: string): DataFormat =
  case file.splitFile.ext.toLowerAscii()
  of ".json": dfJson
  of ".jsonc": dfJsonc
  of ".jsonl", ".ndjson": dfJsonLines
  of ".cbor": dfCbor
  else: dfYaml

proc parseFormat(command, value: string): DataFormat =
  for f in DataFormat:
    if value == $f: return f
  fail(command)

proc jsonLinesAsYaml(content: string): string =
  ## Each line of ``content`` as a document of its own; positions keep their
  ## lines.
  for line in content.splitLines(keepEol = true):
    if line.strip().len > 0: result.add("--- ")
    result.add(line)

proc events(input: Input, format: DataFormat): YamlStream =
  var parser = initYamlParser()
  case format
  of dfYaml, dfJson: parser.parse(input.content)
  of dfJsonc: parser.parse(stripJsonComments(input.content))
  of dfJsonLines: parser.parse(jsonLinesAsYaml(input.content))
  of dfCbor: parseCbor(input.content)

proc rootCause(e: ref Exception): ref Exception =
  result = e
  while result of YamlStreamError and not result.parent.isNil:
    result = result.parent

proc describe(name: string, e: ref Exception): string =
  let cause = rootCause(e)
  if cause of YamlParserError:
    let m = (ref YamlParserError)(cause).mark
    name & ":" & $m.line & ":" & $m.column & ": " & cause.msg
  elif cause of YamlLoadingError:
    let m = (ref YamlLoadingError)(cause).mark
    name & ":" & $m.line & ":" & $m.column & ": " & cause.msg
  else: name & ": " & cause.msg

proc collect(target: BufferYamlStream, source: YamlStream) =
  ## Adds the documents of ``source`` to ``target``.
  for e in source:
    if e.kind notin {yamlStartStream, yamlEndStream}: target.put(e)

proc newStream(): BufferYamlStream =
  result = newBufferYamlStream()
  result.put(startStreamEvent())

# outputs

proc normalize(events: BufferYamlStream, resolveTags: bool) =
  ## Drops the styles of the input, so that the output's options decide
  ## them. With ``resolveTags``, non-specific tags are resolved by the core
  ## schema, so that JSON gets numbers, booleans and nulls.
  for e in events.mitems:
    case e.kind
    of yamlStartDoc: e.explicitDirectivesEnd = false
    of yamlEndDoc: e.explicitDocumentEnd = false
    of yamlStartMap:
      e.mapStyle = csAny
      if resolveTags and e.mapProperties.tag in
          [yTagQuestionMark, yTagExclamationMark]:
        e.mapProperties.tag = yTagMapping
    of yamlStartSeq:
      e.seqStyle = csAny
      if resolveTags and e.seqProperties.tag in
          [yTagQuestionMark, yTagExclamationMark]:
        e.seqProperties.tag = yTagSequence
    of yamlScalar:
      e.scalarStyle = ssAny
      if resolveTags:
        if e.scalarProperties.tag == yTagQuestionMark:
          e.scalarProperties.tag = case guessType(e.scalarContent)
            of yTypeInteger: yTagInteger
            of yTypeFloat, yTypeFloatInf, yTypeFloatNaN: yTagFloat
            of yTypeBoolTrue, yTypeBoolFalse: yTagBoolean
            of yTypeNull: yTagNull
            of yTypeTimestamp: yTagTimestamp
            of yTypeUnknown: yTagString
        elif e.scalarProperties.tag == yTagExclamationMark:
          e.scalarProperties.tag = yTagString
    else: discard

proc writeEach(output: File, events: BufferYamlStream,
    options: PresentationOptions) =
  ## Writes each document of ``events`` as a stream of its own, ending with
  ## a line break.
  var doc: BufferYamlStream
  for e in events:
    case e.kind
    of yamlStartDoc:
      doc = newStream()
      doc.put(e)
    of yamlEndDoc:
      doc.put(e)
      doc.put(endStreamEvent())
      output.write(present(doc, options).strip(leading = false) & "\n")
    of yamlStartStream, yamlEndStream: discard
    else: doc.put(e)

proc write(output: File, events: BufferYamlStream, format: DataFormat,
    yamlStyle: FormatConfig) =
  ## Writes the stream ``events``, which has no end event yet. JSON gets one
  ## value per document, like JSON Lines but not limited to one line each.
  events.put(endStreamEvent())
  events.normalize(resolveTags = format in {dfJson, dfJsonc, dfJsonLines})
  case format
  of dfYaml: output.write(present(events, yamlStyle.dumper.presentation))
  of dfJson, dfJsonc: output.writeEach(events, jsonDumper().presentation)
  of dfCbor: output.write(presentCbor(events))
  of dfJsonLines:
    var options = jsonLinesDumper().presentation
    options.newlines = nlNone
    options.maxLineLength = none(int)
    output.writeEach(events, options)

# commands

proc hasComments(text: string): bool =
  ## Whether ``text`` has a comment. False if the lexer fails, which
  ## formatting then reports.
  var lex: Lexer
  lex.directiveExtensions = true
  lex.keepComments = true
  lex.init(text)
  while true:
    try: lex.next()
    except LexerError: return false
    if lex.comments.len > 0: return true
    if lex.cur == Token.StreamEnd: return false

proc formatCommand(args: seq[string]): int =
  var
    files: seq[string]
    write, checkOnly, dropComments = false
    configPath = ""
    overrides = FormatConfig()
  for kind, key, val in options(args):
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "write", "w": write = true
      of "check": checkOnly = true
      of "drop-comments": dropComments = true
      of "comment-indentation":
        for i in CommentIndentation:
          if val == $i: overrides.commentIndentation = some(i)
        if overrides.commentIndentation.isNone: fail("format")
      of "comment-blank-lines":
        for k in Keeping:
          if val == $k: overrides.commentBlankLines = some(k)
        if overrides.commentBlankLines.isNone: fail("format")
      of "comment-gap":
        let n = try: parseInt(val) except ValueError: 0
        if n < 1: fail("format")
        overrides.commentGap = some(n)
      of "config": configPath = val
      of "style":
        for s in FormatStyle:
          if val == $s: overrides.style = some(s)
        if overrides.style.isNone: fail("format")
      of "indent", "line-length":
        let n = try: parseInt(val) except ValueError: -1
        if n < 0 or (key == "indent" and n notin 1 .. 9): fail("format")
        if key == "indent": overrides.indentation = some(n)
        else: overrides.maxLineLength = some(n)
      else: fail("format")
      if key in ["config", "style", "indent", "line-length"] and
          val.len == 0: fail("format")
    of cmdEnd: discard
  if (write and checkOnly) or (files.len == 0 and write) or
      (files.len > 1 and not (write or checkOnly)): fail("format")
  let explicit =
    if configPath.len > 0: some(loadToolConfig(configPath))
    else: none(ToolConfig)
  for (name, content) in readInputs(files):
    var style =
      if explicit.isSome: explicit.get().format
      elif files.len == 0: toolConfigFor(getCurrentDir() / "-").format
      else: toolConfigFor(name).format
    if overrides.style.isSome: style.style = overrides.style
    if overrides.indentation.isSome: style.indentation = overrides.indentation
    if overrides.maxLineLength.isSome:
      style.maxLineLength = overrides.maxLineLength
    if overrides.commentIndentation.isSome:
      style.commentIndentation = overrides.commentIndentation
    if overrides.commentBlankLines.isSome:
      style.commentBlankLines = overrides.commentBlankLines
    if overrides.commentGap.isSome: style.commentGap = overrides.commentGap
    if dropComments: style.comments = some(kDrop)
    let dumper = style.dumper
    if style.comments.get(kKeep) == kKeep and
        not dumper.presentation.keepsComments and hasComments(content):
      stderr.writeLine(name & ": has comments, which the " &
          $style.style.get(fsDefault) & " style cannot keep; " &
          "use --drop-comments to format it anyway")
      result = 1
      continue
    var formatted: string
    try:
      formatted = dumper.transform(content)
    except YamlParserError, YamlPresenterJsonError:
      stderr.writeLine(describe(name, getCurrentException()))
      result = 1
      continue
    if checkOnly:
      if formatted != content:
        stdout.writeLine(name)
        result = 1
    elif write:
      if formatted != content: writeFile(name, formatted)
    else: stdout.write(formatted)

proc convertCommand(command: string, args: seq[string]): int =
  var
    positional: seq[string]
    source = none(DataFormat)
  for kind, key, val in options(args):
    case kind
    of cmdArgument: positional.add(key)
    of cmdLongOption, cmdShortOption:
      if key == "from": source = some(parseFormat(command, val))
      else: fail(command)
    of cmdEnd: discard
  if positional.len == 0: fail(command)
  let
    target = parseFormat(command, positional[0])
    files = positional[1 .. ^1]
    yamlStyle = toolConfigFor(
        if files.len > 0: files[0] else: getCurrentDir() / "-").format
    stream = newStream()
  for input in readInputs(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    try:
      stream.collect(events(input, format))
    except YamlStreamError, YamlParserError:
      stderr.writeLine(describe(input.name, getCurrentException()))
      return 1
  try:
    stdout.write(stream, target, yamlStyle)
  except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
    stderr.writeLine(describe("<output>", getCurrentException()))
    return 1

proc queryCommand(args: seq[string]): int =
  var
    positional: seq[string]
    source = none(DataFormat)
    target = dfYaml
    paths = false
  for kind, key, val in options(args):
    case kind
    of cmdArgument: positional.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "from": source = some(parseFormat("query", val))
      of "to": target = parseFormat("query", val)
      of "paths": paths = true
      else: fail("query")
    of cmdEnd: discard
  if positional.len == 0: fail("query")
  var path: JsonPath
  try:
    path = parseJsonPath(positional[0])
  except YamlJsonPathError as e:
    stderr.writeLine("invalid JSONPath: " & e.msg)
    return 2
  let
    files = positional[1 .. ^1]
    yamlStyle = toolConfigFor(
        if files.len > 0: files[0] else: getCurrentDir() / "-").format
    selected = newStream()
  for input in readInputs(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    try:
      var s = events(input, format)
      discard s.next() # yamlStartStream
      while s.peek().kind == yamlStartDoc:
        var root: YamlNode
        construct(s, root)
        for found in root.queryLocated(path):
          if paths: stdout.writeLine(found.path)
          else: selected.collect(represent(found.node))
    except YamlStreamError, YamlParserError, YamlConstructionError:
      stderr.writeLine(describe(input.name, getCurrentException()))
      return 1
  if not paths:
    try:
      stdout.write(selected, target, yamlStyle)
    except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
      stderr.writeLine(describe("<output>", getCurrentException()))
      return 1

proc lspCommand(args: seq[string]): int =
  for arg in args:
    if arg != "--stdio" and not arg.startsWith("--clientProcessId"):
      fail("lsp")
  serve(newFileStream(stdin), stdout)

proc helpCommand(args: seq[string]): int =
  if args.len == 0:
    stdout.writeLine(overview)
  elif args.len == 1 and usageOf(args[0]).len > 0:
    stdout.writeLine(usageOf(args[0]))
  else: fail("help")

proc run*(args: seq[string]): int =
  ## Runs the command line ``args`` and returns the exit code.
  if args.len == 0:
    stderr.writeLine(overview)
    return 2
  let
    command = args[0]
    rest = args[1 .. ^1]
  if command in ["-h", "--help"]: return helpCommand(@[])
  if usageOf(command).len > 0 and command notin ["help", "config"] and
      rest.wantsHelp:
    return helpCommand(@[command])
  try:
    case command
    of "lint": yamllint.run(rest, lmLint, lintUsage, toolConfigs = true)
    of "validate":
      yamllint.run(rest, lmValidate, validateUsage, toolConfigs = true)
    of "format": formatCommand(rest)
    of "convert", "as", "to": convertCommand(command, rest)
    of "query": queryCommand(rest)
    of "expand": yamlexpand.run(rest, stdin, stdout)
    of "lsp": lspCommand(rest)
    of "help": helpCommand(rest)
    else:
      if command.startsWith("$"): queryCommand(args)
      else:
        stderr.writeLine("unknown command: " & command & "\n\n" & overview)
        2
  except UsageError as e:
    stderr.writeLine(e.msg)
    2
  except ToolConfigError as e:
    stderr.writeLine("config error: " & e.msg)
    2
  except IOError, OSError:
    stderr.writeLine(getCurrentExceptionMsg())
    2

when isMainModule:
  quit(run(commandLineParams()))
