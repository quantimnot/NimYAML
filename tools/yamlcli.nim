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
##   an RFC 9535 JSONPath, or with ``PATH = VALUE`` replaces them
## * ``patch``: applies a JSON Patch (RFC 6902) or JSON Merge Patch
##   (RFC 7396)
## * ``merge``: applies merge keys (``<<``)
## * ``canonical`` (or ``jcs``): writes the RFC 8785 canonical JSON form
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
    jsonpath, toolconfig, edit, jsonpatch, mergepatch, merge, jcs]
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
  query     select nodes with a JSONPath (also: yaml '$...' [FILE...]),
            or replace them: yaml '$... = VALUE' [-i] [FILE...]
  patch     apply a JSON Patch or JSON Merge Patch to the documents
  merge     apply merge keys (<<)
  canonical write the canonical JSON form (RFC 8785) of each document
            (also: jcs)
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

  formatUsage = """usage: yaml format [--write | -i | --check] [--drop-comments] [--config:FILE]
                   [--style:STYLE] [--indent:N] [--line-length:N]
                   [--comment-indentation:node|source] [--comment-gap:N]
                   [--comment-blank-lines:keep|drop] [FILE...]

Rewrites YAML in the style of the format section of the config, and prints
it; with --write (or -i, --in-place), the files are rewritten in place
instead, and with --check, the files that are not formatted are listed
(exit code 1 if there are any). Several files require --write or --check.

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
       yaml query [--from:FORMAT] [--to:FORMAT] [-i] 'PATH = VALUE' [FILE...]
       yaml PATH [FILE...]   (when PATH starts with $; also with = VALUE)

Applies the RFC 9535 JSONPath PATH to each document and writes the
selected nodes, each as a document, in the format --to (default: yaml; see
yaml help convert). With --paths, their Normalized Paths are printed
instead, one per line.

With = VALUE (the first = outside of brackets and quotes), each selected
node is replaced by VALUE, read as YAML, and the edited input is written
instead: only the text of the selected nodes changes, so comments, styles
and layout stay. Several inputs and --to are written as by yaml convert.
With -i (or --in-place), each file in which a node is selected is edited
in place instead. CBOR has no text to edit and is encoded again."""

  patchUsage = """usage: yaml patch [--merge] [--from:FORMAT] [--to:FORMAT | -i] PATCH [FILE...]

Applies the patch in the file PATCH to each document. A patch that is a
sequence is a JSON Patch (RFC 6902): a list of operations like
{op: replace, path: /a/b, value: 1}. Any other patch is a JSON Merge Patch
(RFC 7396), which looks like the document: its members replace those of
the document, mappings are merged, and null removes a member. --merge
reads a sequence as a merge patch too, which then replaces the document.

The patched documents are written as by yaml convert, in the format of the
first input unless --to; with -i (or --in-place), each file is rewritten
in place instead. A patch that does not apply (a missing location, a
failed test) leaves all files as they were. Exit code 1 then."""

  mergeUsage = """usage: yaml merge [--from:FORMAT] [--to:FORMAT | -i] [FILE...]

Applies the merge keys (<<) of each document: a mapping with <<: *base,
or <<: [*a, *b], gets the entries of those mappings that it does not have
itself, earlier ones first. The documents are written as by yaml patch."""

  canonicalUsage = """usage: yaml canonical [--from:FORMAT] [FILE...]
       yaml jcs [--from:FORMAT] [FILE...]

Writes each document in the JSON Canonicalization Scheme (RFC 8785), one
line per document: no whitespace, members sorted, numbers and strings
written as ECMAScript writes them. Documents that JSON cannot represent
faithfully (non-string or duplicate keys, cycles, .inf, .nan) are refused
with exit code 1."""

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
  of "patch": patchUsage
  of "merge": mergeUsage
  of "canonical", "jcs": canonicalUsage
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
      # A quoted scalar that would read as another type when plain keeps
      # quotes, or "80" would come out as the number 80.
      e.scalarStyle =
        if e.scalarProperties.tag == yTagExclamationMark and
            guessType(e.scalarContent) != yTypeUnknown: ssDoubleQuoted
        else: ssAny
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

proc renderEach(output: var string, events: BufferYamlStream,
    options: PresentationOptions) =
  ## Renders each document of ``events`` as a stream of its own, ending
  ## with a line break.
  var doc: BufferYamlStream
  for e in events:
    case e.kind
    of yamlStartDoc:
      doc = newStream()
      doc.put(e)
    of yamlEndDoc:
      doc.put(e)
      doc.put(endStreamEvent())
      output.add(present(doc, options).strip(leading = false) & "\n")
    of yamlStartStream, yamlEndStream: discard
    else: doc.put(e)

proc render(events: BufferYamlStream, format: DataFormat,
    yamlStyle: FormatConfig): string =
  ## Renders the stream ``events``, which has no end event yet. JSON gets
  ## one value per document, like JSON Lines but not limited to one line
  ## each.
  events.put(endStreamEvent())
  events.normalize(resolveTags = format in {dfJson, dfJsonc, dfJsonLines})
  case format
  of dfYaml: result = present(events, yamlStyle.dumper.presentation)
  of dfJson, dfJsonc: result.renderEach(events, jsonDumper().presentation)
  of dfCbor: result = presentCbor(events)
  of dfJsonLines:
    var options = jsonLinesDumper().presentation
    options.newlines = nlNone
    options.maxLineLength = none(int)
    result.renderEach(events, options)

proc write(output: File, events: BufferYamlStream, format: DataFormat,
    yamlStyle: FormatConfig) =
  ## Writes the stream ``events``, which has no end event yet; see `render`.
  output.write(render(events, format, yamlStyle))

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
      of "write", "w", "in-place", "i": write = true
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

proc splitAssignment(expr: string):
    tuple[path, value: string, assigns: bool] =
  ## Splits ``PATH = VALUE`` at its first ``=`` outside of brackets,
  ## parentheses and string literals; comparisons are in filters, so in
  ## brackets.
  var
    depth = 0
    quote = '\0'
    i = 0
  while i < expr.len:
    let c = expr[i]
    if quote != '\0':
      if c == '\\': inc i
      elif c == quote: quote = '\0'
    else:
      case c
      of '\'', '"': quote = c
      of '[', '(': inc depth
      of ']', ')': dec depth
      of '=':
        if depth == 0:
          return (expr[0 ..< i].strip(), expr[i + 1 .. ^1].strip(), true)
      else: discard
    inc i
  (expr, "", false)

proc assignedCbor(input: Input, path: JsonPath, value: string):
    tuple[text: string, count: int] =
  ## Like `assigned`, for CBOR: the documents are encoded again.
  let documents = newStream()
  var s = events(input, dfCbor)
  discard s.next() # yamlStartStream
  while s.peek().kind == yamlStartDoc:
    var root: YamlNode
    construct(s, root)
    for found in root.queryLocated(path):
      # a value of its own for each node, so that none is an alias
      var node: YamlNode
      load(value, node)
      found.node[] = node[]
      inc(result.count)
    documents.collect(represent(root))
  result.text =
    if result.count > 0: render(documents, dfCbor, FormatConfig())
    else: input.content

proc assigned(input: Input, format: DataFormat, path: JsonPath,
    value: string, style: FormatConfig): tuple[text: string, count: int] =
  ## ``input`` with ``value`` assigned to the nodes that ``path`` selects,
  ## and their number; see `yaml/edit <../yaml/edit.html>`_.
  case format
  of dfCbor: result = assignedCbor(input, path, value)
  of dfJsonLines:
    var lineNumber = 0
    for line in input.content.splitLines(keepEol = true):
      inc(lineNumber)
      let content = line.strip(leading = false, chars = {'\l', '\c'})
      if content.strip().len == 0:
        result.text.add(line)
        continue
      try:
        let (text, count) = edit.assign(content, path, value, json = true)
        result.text.add(text & line[content.len .. ^1])
        result.count += count
      except YamlParserError as e:
        e.mark.line = lineNumber
        raise e
  else:
    result = edit.assign(input.content, path, value,
        style.dumper.presentation,
        json = format in {dfJson, dfJsonc})

proc queryCommand(args: seq[string]): int =
  var
    positional: seq[string]
    source, target = none(DataFormat)
    paths, inPlace = false
  for kind, key, val in options(args):
    case kind
    of cmdArgument: positional.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "from": source = some(parseFormat("query", val))
      of "to": target = some(parseFormat("query", val))
      of "paths": paths = true
      of "in-place", "i": inPlace = true
      else: fail("query")
    of cmdEnd: discard
  if positional.len == 0: fail("query")
  let
    (pathText, valueText, assigns) = splitAssignment(positional[0])
    files = positional[1 .. ^1]
  if (assigns and paths) or (inPlace and (not assigns or files.len == 0)):
    fail("query")
  var path: JsonPath
  try:
    path = parseJsonPath(pathText)
  except YamlJsonPathError as e:
    stderr.writeLine("invalid JSONPath: " & e.msg)
    return 2
  if assigns:
    try:
      var value: YamlNode
      load(valueText, value)
    except YamlParserError, YamlConstructionError:
      stderr.writeLine("invalid value: " & getCurrentExceptionMsg())
      return 2
  let
    yamlStyle = toolConfigFor(
        if files.len > 0: files[0] else: getCurrentDir() / "-").format
    selected = newStream()
  var asText = false # the edited text of a single input is written as is
  for input in readInputs(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    try:
      if assigns:
        let edited = assigned(input, format, path, valueText,
            if files.len == 0: yamlStyle
            else: toolConfigFor(input.name).format)
        if inPlace:
          if edited.count > 0: writeFile(input.name, edited.text)
        elif files.len <= 1 and target.isNone and format != dfCbor:
          asText = true
          stdout.write(edited.text)
        else: selected.collect(events((input.name, edited.text), format))
        continue
      var s = events(input, format)
      discard s.next() # yamlStartStream
      while s.peek().kind == yamlStartDoc:
        var root: YamlNode
        construct(s, root)
        for found in root.queryLocated(path):
          if paths: stdout.writeLine(found.path)
          else: selected.collect(represent(found.node))
    except YamlEditError as e:
      stderr.writeLine(input.name & ": " & e.msg)
      return 1
    except YamlStreamError, YamlParserError, YamlConstructionError,
        YamlPresenterCborError:
      stderr.writeLine(describe(input.name, getCurrentException()))
      return 1
  if not (paths or inPlace or asText):
    try:
      stdout.write(selected, target.get(dfYaml), yamlStyle)
    except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
      stderr.writeLine(describe("<output>", getCurrentException()))
      return 1

proc documents(input: Input, format: DataFormat): seq[YamlNode] =
  ## The documents of ``input`` as graphs.
  var s = events(input, format)
  discard s.next() # yamlStartStream
  while s.peek().kind == yamlStartDoc:
    var root: YamlNode
    construct(s, root)
    result.add(root)

proc transformCommand(command: string, args: seq[string], operands: int,
    prepare: proc(operands: seq[string]): int,
    transform: proc(root: YamlNode): YamlNode): int =
  ## Shared by the commands that change each document of their inputs as a
  ## whole. The first ``operands`` arguments go to ``prepare``, which runs
  ## before any input is read and returns an exit code (0 to go on),
  ## instead of being read as files. The results are written like ``yaml convert``
  ## writes, in the format of the first input unless --to; with -i, each
  ## file is rewritten in its own format, but only once all of them have
  ## been transformed, so that an error leaves every file as it was.
  var
    positional: seq[string]
    source, target = none(DataFormat)
    inPlace = false
  for kind, key, val in options(args):
    case kind
    of cmdArgument: positional.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "from": source = some(parseFormat(command, val))
      of "to": target = some(parseFormat(command, val))
      of "in-place", "i": inPlace = true
      else: fail(command)
    of cmdEnd: discard
  if positional.len < operands: fail(command)
  let files = positional[operands .. ^1]
  if inPlace and (files.len == 0 or target.isSome): fail(command)
  result = prepare(positional[0 ..< operands])
  if result != 0: return
  let yamlStyle = toolConfigFor(
      if files.len > 0: files[0] else: getCurrentDir() / "-").format
  var
    output = newStream()
    outputFormat = target
    rewritten: seq[tuple[file, text: string]]
  for input in readInputs(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    if outputFormat.isNone: outputFormat = some(format)
    let transformed = if inPlace: newStream() else: output
    try:
      for root in documents(input, format):
        # tsAll keeps every node's own tag, so "1" stays a string
        transformed.collect(represent(transform(root),
            SerializationOptions(tagStyle: tsAll)))
      if inPlace:
        rewritten.add((input.name, render(transformed, format,
            toolConfigFor(input.name).format)))
    except YamlStreamError, YamlParserError, YamlConstructionError,
        YamlPresenterJsonError, YamlPresenterCborError:
      stderr.writeLine(describe(input.name, getCurrentException()))
      return 1
    except YamlJsonPatchError:
      stderr.writeLine(input.name & ": " & getCurrentExceptionMsg())
      return 1
  if inPlace:
    for (file, text) in rewritten: writeFile(file, text)
    return 0
  try:
    stdout.write(output, outputFormat.get(dfYaml), yamlStyle)
  except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
    stderr.writeLine(describe("<output>", getCurrentException()))
    return 1

proc patchCommand(args: seq[string]): int =
  var mergePatch = false
  var rest: seq[string]
  for arg in args:
    if arg == "--merge": mergePatch = true
    else: rest.add(arg)
  var
    patch: YamlNode
    jsonPatch: JsonPatch
  proc readPatch(operands: seq[string]): int =
    let file = operands[0]
    try:
      let docs = documents((file, readFile(file)), formatOf(file))
      if docs.len != 1:
        stderr.writeLine(file & ": a patch must be a single document")
        return 1
      patch = docs[0]
      if patch.kind == ySequence and not mergePatch:
        jsonPatch = parseJsonPatch(patch)
    except YamlStreamError, YamlParserError, YamlConstructionError:
      stderr.writeLine(describe(file, getCurrentException()))
      return 1
    except YamlJsonPatchError as e:
      stderr.writeLine(file & ": " & e.msg)
      return 1
  proc applyPatch(root: YamlNode): YamlNode =
    if patch.kind == ySequence and not mergePatch:
      root.applyJsonPatch(jsonPatch)
    else: root.applyMergePatch(patch)
  transformCommand("patch", rest, 1, readPatch, applyPatch)

proc mergeCommand(args: seq[string]): int =
  var
    files: seq[string]
    source, target = none(DataFormat)
    inPlace = false
  for kind, key, val in options(args):
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "from": source = some(parseFormat("merge", val))
      of "to": target = some(parseFormat("merge", val))
      of "in-place", "i": inPlace = true
      else: fail("merge")
    of cmdEnd: discard
  if inPlace and (files.len == 0 or target.isSome): fail("merge")
  # The stream filter, unlike representing the merged graph, writes merged
  # values out instead of giving them anchors, and keeps scalar styles.
  let yamlStyle = toolConfigFor(
      if files.len > 0: files[0] else: getCurrentDir() / "-").format
  var
    output = newStream()
    outputFormat = target
    rewritten: seq[tuple[file, text: string]]
  for input in readInputs(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    if outputFormat.isNone: outputFormat = some(format)
    try:
      if inPlace:
        let merged = newStream()
        merged.collect(mergeKeysApplied(events(input, format)))
        rewritten.add((input.name, render(merged, format,
            toolConfigFor(input.name).format)))
      else: output.collect(mergeKeysApplied(events(input, format)))
    except YamlStreamError, YamlParserError, YamlPresenterJsonError,
        YamlPresenterCborError:
      let cause = rootCause(getCurrentException())
      if cause of YamlMergeError:
        let m = (ref YamlMergeError)(cause).mark
        stderr.writeLine(input.name & ":" & $m.line & ":" & $m.column & ": " &
            cause.msg)
      else: stderr.writeLine(describe(input.name, getCurrentException()))
      return 1
  if inPlace:
    for (file, text) in rewritten: writeFile(file, text)
    return 0
  try:
    stdout.write(output, outputFormat.get(dfYaml), yamlStyle)
  except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
    stderr.writeLine(describe("<output>", getCurrentException()))
    return 1

proc canonicalCommand(args: seq[string]): int =
  var
    files: seq[string]
    source = none(DataFormat)
  for kind, key, val in options(args):
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      if key == "from": source = some(parseFormat("canonical", val))
      else: fail("canonical")
    of cmdEnd: discard
  for input in readInputs(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    try:
      for root in documents(input, format):
        stdout.writeLine(canonicalJson(root))
    except YamlStreamError, YamlParserError, YamlConstructionError:
      stderr.writeLine(describe(input.name, getCurrentException()))
      return 1
    except YamlJcsError as e:
      stderr.writeLine(input.name & ": " & e.msg)
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
    of "patch": patchCommand(rest)
    of "merge": mergeCommand(rest)
    of "canonical", "jcs": canonicalCommand(rest)
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
