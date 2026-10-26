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
## * ``diff``: the semantic differences between two files, or the JSON
##   Patch or JSON Merge Patch that makes them
## * ``expand``: makes ``%GLOBAL`` directives portable
## * ``config``: writes the config in effect, with all defaults, to
##   ``.yaml.yaml``
## * ``index``: builds, prints or drops the index of node locations that
##   ``query`` reads nodes through (see `yaml/nodeindex
##   <../yaml/nodeindex.html>`_)
## * ``lsp``: the language server, over stdio
## * ``help``: this overview, or the usage of a command
##
## Commands that take files read standard input without them. ``lint``,
## ``validate``, ``format`` and the language server are configured by the
## ``.yaml`` or ``.yaml.yaml`` file found by walking up from each file's
## directory (see `yaml/toolconfig <../yaml/toolconfig.html>`_).
##
## Exit code: 0 on success, 1 if an input is invalid or has error
## diagnostics (or, with ``format --check``, is not formatted, or with
## ``diff``, the files differ), 2 for usage, I/O and config errors (and with
## ``diff``, invalid inputs), 3 if the memory limit is exceeded.
##
## Every command takes ``--memory-limit:SIZE`` (like ``64MiB``, or
## ``unlimited``) and ``--source:TIER`` (``auto``, ``memory``, ``mmap``,
## ``seek`` or ``stream``), which override the ``memory`` section of the
## config, and ``--verbose``, which prints how each input is read.

import std/[options, os, parseopt, streams, strutils, terminal]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[data, dom, dumping, loading, parser, presenter, stream, cbor,
    jsonpath, toolconfig, edit, jsonpatch, mergepatch, merge, jcs, diff,
    nodeindex, spans, memory, source]
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
  diff      the semantic differences between two files, or the JSON Patch
            or JSON Merge Patch that makes them
  expand    expand %GLOBAL directives into the documents
  config    write the config in effect, with all defaults, to .yaml.yaml
  index     build, print or drop the index that query reads nodes through
  lsp       the language server, over stdio
  help      this overview, or the usage of COMMAND

Commands that take files read standard input without them. Files are
configured by the nearest .yaml or .yaml.yaml file; see yaml help config.

options of every command:
  --memory-limit:SIZE  the memory budget, like 64MiB, or unlimited
                       (default: memory.limit in the config, auto: half of
                       the host memory)
  --source:TIER        how files are read: auto, memory, mmap, seek or
                       stream (default: memory.source in the config)
  --verbose            print how each input is read

Exit code 0 on success, 1 for invalid inputs, 2 for usage, I/O and config
errors, 3 if the memory limit is exceeded."""

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
in place instead. CBOR has no text to edit and is encoded again.

With an index (index.mode in the config; see yaml help index), a PATH that
names a single location, like $.a.b[0], is looked up in the index of each
YAML or JSON file first, and the node is read from its slice of the file
without parsing the rest. A file without a current index is parsed, which
brings its index up to date."""

  indexUsage = """usage: yaml index [--mode:all|recent] [--format:cbor|yaml]
                  [--location:beside|project|user] FILE...
       yaml index --print [--mode:...] [--format:...] [--location:...] FILE...
       yaml index --drop [--mode:...] [--format:...] [--location:...] FILE...

Builds the index of each YAML or JSON file, which records where each node
is, so that yaml query reads a node from its slice of the file instead of
parsing all of it, and prints the path of each index written. The index
section of the config sets how files are indexed; the options override it.
Without either, the mode is all.

--mode:all      every node (the default here)
--mode:recent   only the paths looked up lately, at most index.recent-limit
--format:F      cbor (default) or yaml
--location:L    beside: .NAME.index.FORMAT next to the file; project: in
                .yaml-index next to the config file; user: in the user's
                cache directory (default)
--print         write the index of each file as YAML instead (building it
                if it is missing or stale)
--drop          remove the index of each file

An index holds a fingerprint of its file, so an index of a file changed by
anything else is not used. Commands that edit files in place (format -i,
query -i, patch -i, merge -i) build the index of the files they write."""

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

  diffUsage = """usage: yaml diff [--from:FORMAT] [--paths:pointer|path] [--color:WHEN] [-q] OLD NEW
       yaml diff (--patch | --merge-patch) [--from:FORMAT] [--to:FORMAT] OLD NEW

Compares the documents of the files OLD and NEW (- for standard input) by
what they mean, not how they are written: key order, styles, quotes,
comments, anchors and aliases make no difference, and numbers are compared
by value. Sequences are aligned, so an inserted item is one change. Each
added (+), removed (-) or changed (~) node is printed on a line with its
JSON Pointer (or JSON Path with --paths:path) and its value; removed nodes
have their path in OLD, the others in NEW. When a file has several
documents, they are compared in order, and paths start with #N, the number
of the document. --color:WHEN is auto (if standard output is a terminal),
always or never. With -q (or --quiet), nothing is printed.

With --patch, the JSON Patch (RFC 6902) that turns each document of OLD
into that of NEW is written instead, which yaml patch applies; with
--merge-patch, the JSON Merge Patch (RFC 7396), which cannot set a member
to null. They are written as by yaml convert, in the format of NEW unless
--to. A patch addresses only members whose keys are strings.

Exit code 0 if the files are the same, 1 if they differ, 2 for invalid
inputs.

As a git diff driver, yaml diff is called with the 7 arguments PATH
OLD-FILE OLD-HEX OLD-MODE NEW-FILE NEW-HEX NEW-MODE, and prints the
changes of PATH under a heading; its exit code is then 0. Set it up with

  git config diff.yaml.command 'yaml diff'
  echo '*.yaml diff=yaml' >> .gitattributes"""

  expandUsage = """usage: yaml expand [--modeline] [FILE]

Writes FILE (or standard input) with every %GLOBAL directive expanded into
the documents that inherit it, so that other YAML processors read the
documents as NimYAML does. With --modeline, %SCHEMA directives become
'# yaml-language-server: $schema=' comments."""

  lspUsage = """usage: yaml lsp [--stdio]

Starts the language server, speaking JSON-RPC over standard input and
output. Editors start it as the command `yaml` with the argument `lsp`."""

  helpUsage = """usage: yaml help [COMMAND]"""

  configUsage = """usage: yaml config [--config:FILE] [--print] [--force] [DIR]

Writes the config in effect for DIR (default: the current directory) to
DIR/.yaml.yaml, with every key set to its configured or default value: the
nearest .yaml or .yaml.yaml file (or --config:FILE), or the defaults if
there is none. --print writes it to standard output instead. An existing
DIR/.yaml.yaml is only replaced with --force; a DIR/.yaml is never, as a
directory cannot have both.

"""

  configHelp = configUsage & """Configuration: the file .yaml or .yaml.yaml (not both) in a file's
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
    comment-blank-lines: keep  # or drop
  index:                    # see yaml help index
    mode: off               # off, recent or all
    format: cbor            # or yaml
    location: user          # beside, project or user
    recent-limit: 256
  memory:
    limit: auto             # auto (half the host memory), unlimited or a
                            # size like 64MiB; exit code 3 when exceeded
    source: auto            # auto, memory, mmap, seek or stream
    mmap: auto              # or off
    map-window: auto        # size of a mapped window of a file
    page-cache: auto        # cached pages of a file read by seeking
    spool: auto             # or off: streams that need random access are
                            # read into memory instead of a temporary file
    spool-dir: auto         # directory of spooled streams"""

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
  of "diff": diffUsage
  of "expand": expandUsage
  of "lsp": lspUsage
  of "help": helpUsage
  of "config": configHelp
  of "index": indexUsage
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

# memory
#
# One budget for the whole run, made from the config of the first input
# read and the --memory-limit option; each input is read by the policy of
# its own config and the --source option.

var
  memoryOverride: tuple[limit: Option[int], source: Option[TierChoice]]
  verbose = false
  runBudget: MemoryBudget
  opened: seq[YamlSource] # closed when the run ends

proc configFile(file: string): string =
  ## The path a config is looked up for: the file, or for standard input a
  ## file in the current directory.
  if file.len == 0 or file == "-": getCurrentDir() / "-" else: file

proc budgetFor(file: string): MemoryBudget =
  if runBudget.isNil:
    runBudget = newMemoryBudget(memoryOverride.limit.get(
        toolConfigFor(configFile(file)).memoryLimit))
  runBudget

proc policyFor(file: string): SourcePolicy =
  result = toolConfigFor(configFile(file)).sourcePolicy
  if memoryOverride.source.isSome: result.choice = memoryOverride.source.get()

proc openInput(file: string, randomAccess = false): YamlSource =
  ## The source of ``file``; "" or "-" is standard input.
  let
    budget = budgetFor(file)
    policy = policyFor(file)
  result =
    if file.len == 0 or file == "-":
      openSource(stdin, "<stdin>", budget, policy, randomAccess)
    else: openSource(file, budget, policy, randomAccess)
  opened.add(result)
  if verbose:
    stderr.writeLine(result.name & ": tier " & $result.tier & ", limit " &
        formatSize(budget.limit))

proc randomInput(file: string): YamlSource =
  ## The source of ``file`` for commands that read it more than once.
  openInput(file, randomAccess = true)

proc readText(file: string, randomAccess = false): Input =
  ## The whole text of ``file`` (standard input for "" or "-"), which must
  ## fit into the budget.
  let src = openInput(file, randomAccess)
  try: result = (src.name, src.readAll("reading " & src.name))
  finally: src.close()

proc takeMemoryOptions(args: seq[string]): seq[string] =
  ## ``args`` without the options every command takes, which are applied.
  for arg in args:
    if arg == "--": return
  for i, arg in args:
    if arg == "--":
      return result & args[i .. ^1]
    var key, value = ""
    if arg.startsWith("--"):
      let sep = arg.find({':', '='})
      key = if sep < 0: arg[2 .. ^1] else: arg[2 ..< sep]
      value = if sep < 0: "" else: arg[sep + 1 .. ^1]
    case key
    of "memory-limit":
      try: memoryOverride.limit = some(parseSize(value))
      except ValueError:
        raise newException(UsageError, "invalid --memory-limit: " & value)
    of "source":
      try: memoryOverride.source = some(parseEnum[TierChoice](value))
      except ValueError:
        raise newException(UsageError, "invalid --source: " & value &
            "; use auto, memory, mmap, seek or stream")
    of "verbose": verbose = true
    else: result.add(arg)

# inputs

proc formatOf(file: string): DataFormat =
  case file.splitFile.ext.toLowerAscii()
  of ".json": dfJson
  of ".jsonc": dfJsonc
  of ".jsonl", ".ndjson": dfJsonLines
  of ".cbor": dfCbor
  else: dfYaml

# indexes
#
# A file queried again and again is read through its index (see
# yaml/nodeindex); whatever writes a file brings its index up to date, since
# the writer knows the new content.

proc indexable(format: DataFormat): bool = format in {dfYaml, dfJson, dfJsonc}

proc writeSource(file, text: string) =
  ## Writes ``text`` to ``file`` and builds its index, if files there are
  ## indexed.
  writeFile(file, text)
  let format = formatOf(file)
  if format.indexable:
    refreshIndex(file, text, indexSettingsFor(file), json = format != dfYaml)

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

proc events(src: YamlSource, format: DataFormat): YamlStream =
  ## The events of ``src``, read as a stream within its budget.
  var parser = initYamlParser(budget = src.budget)
  case format
  of dfYaml, dfJson: parser.parse(src)
  of dfJsonc: parser.parse(newJsonCommentStripStream(newSourceStream(src)))
  of dfJsonLines: parser.parse(newJsonLinesStream(newSourceStream(src)))
  of dfCbor: parseCbor(newSourceStream(src), src.budget)

iterator inputSources(files: seq[string]): YamlSource =
  ## The sources of ``files`` (standard input without any), one open at a
  ## time.
  for file in (if files.len == 0: @[""] else: files):
    let src = openInput(file)
    try: yield src
    finally: src.close()

proc rootCause(e: ref Exception): ref Exception =
  result = e
  while result of YamlStreamError and not result.parent.isNil:
    result = result.parent

proc describe(name: string, e: ref Exception): string =
  var cause = rootCause(e)
  # a stream filter (like the JSONC one) reports its own parser error
  # through the parser that reads it; that one is the actual cause
  var inner = cause
  while not inner.isNil:
    if inner != cause and inner of YamlParserError: cause = inner
    inner = inner.parent
  let limit = memoryLimitError(e)
  if not limit.isNil:
    var at = name
    var current = e
    while not current.isNil:
      if current of YamlParserError:
        let m = (ref YamlParserError)(current).mark
        at.add(":" & $m.line & ":" & $m.column)
        break
      current = current.parent
    return at & ": " & limit.describe &
        ". Raise memory.limit or use --memory-limit"
  if cause of YamlParserError:
    let m = (ref YamlParserError)(cause).mark
    name & ":" & $m.line & ":" & $m.column & ": " & cause.msg
  elif cause of YamlLoadingError:
    let m = (ref YamlLoadingError)(cause).mark
    name & ":" & $m.line & ":" & $m.column & ": " & cause.msg
  else: name & ": " & cause.msg

proc failed(name: string, e: ref Exception): int =
  ## Reports the error ``e`` of the input ``name``; the exit code is 3 if
  ## the memory limit was exceeded, else 1.
  stderr.writeLine(describe(name, e))
  if memoryLimitError(e).isNil: 1 else: 3

proc collect(target: BufferYamlStream, source: YamlStream) =
  ## Adds the documents of ``source`` to ``target``.
  for e in source:
    if e.kind notin {yamlStartStream, yamlEndStream}: target.put(e)

proc newStream(): BufferYamlStream =
  result = newBufferYamlStream()
  result.put(startStreamEvent())

# outputs
#
# Output is written as the events are pulled from the inputs, so that a
# command holds at most what one document needs. Output on stdout may thus
# end early when a later input fails (the exit code says so); files written
# in place are written to a temporary file first, and replaced only once
# every file has been written.

proc normalize(e: var Event, resolveTags: bool) =
  ## Drops the style of the input, so that the output's options decide it.
  ## With ``resolveTags``, a non-specific tag is resolved by the core schema,
  ## so that JSON gets numbers, booleans and nulls.
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

type DocumentBuffer = ref object of StreamObj
  ## Holds the output of the document being written, so that an error in
  ## the input does not leave a partial document on ``target``; a document
  ## whose output exceeds ``documentBufferSize`` is written out as it goes.
  target: Stream
  data: string

const documentBufferSize = 65536

proc commit(b: DocumentBuffer) =
  ## Writes the output held.
  if b.data.len > 0:
    b.target.write(b.data)
    b.data.setLen(0)

proc documentBufferWrite(s: Stream, buffer: pointer, bufLen: int) =
  let b = DocumentBuffer(s)
  let old = b.data.len
  b.data.setLen(old + bufLen)
  if bufLen > 0: copyMem(addr b.data[old], buffer, bufLen)
  if b.data.len > documentBufferSize: b.commit()

proc normalizing(s: YamlStream, resolveTags: bool,
    buffer: DocumentBuffer): YamlStream =
  ## The events of ``s``, normalized as they are pulled. The output of a
  ## document is in ``buffer`` once the event after it is pulled, so it is
  ## committed then, before more input is read.
  initYamlStream(iterator(): Event {.gcsafe, raises: [CatchableError].} =
    while true:
      var e = s.next()
      {.cast(gcsafe).}: e.normalize(resolveTags)
      yield e
      if e.kind == yamlEndStream: break
      if e.kind == yamlEndDoc: buffer.commit())

proc nextDocument(s: YamlStream): YamlStream =
  ## The document of ``s`` that starts with its next event, as a stream of
  ## its own.
  initYamlStream(iterator(): Event {.gcsafe, raises: [CatchableError].} =
    yield startStreamEvent()
    while true:
      let e = s.next()
      yield e
      if e.kind == yamlEndDoc: break
    yield endStreamEvent())

type TrimmingStream = ref object of StreamObj
  ## Writes to ``target`` all but the whitespace at the end.
  target: Stream
  held: string

proc trimmingWrite(s: Stream, buffer: pointer, bufLen: int) =
  let t = TrimmingStream(s)
  let data = cast[ptr UncheckedArray[char]](buffer)
  var last = bufLen - 1
  while last >= 0 and data[last] in Whitespace: dec last
  if last >= 0:
    if t.held.len > 0:
      t.target.write(t.held)
      t.held.setLen(0)
    t.target.writeData(buffer, last + 1)
  for i in last + 1 ..< bufLen: t.held.add(data[i])

proc writeStream(target: Stream, events: YamlStream, format: DataFormat,
    yamlStyle: FormatConfig, budget: MemoryBudget) =
  ## Writes the stream ``events`` in ``format``, as it is pulled, each
  ## document once it is complete (or, if its output is large, as it goes).
  ## JSON gets one value per document, like JSON Lines but not limited to
  ## one line each.
  let output = DocumentBuffer(target: target,
      writeDataImpl: documentBufferWrite)
  let s = normalizing(events,
      resolveTags = format in {dfJson, dfJsonc, dfJsonLines}, output)
  case format
  of dfYaml: present(s, output, yamlStyle.dumper.presentation)
  of dfCbor: presentCbor(s, output, budget)
  of dfJson, dfJsonc, dfJsonLines:
    var options = jsonDumper().presentation
    if format == dfJsonLines:
      options = jsonLinesDumper().presentation
      options.newlines = nlNone
      options.maxLineLength = none(int)
    discard s.next() # yamlStartStream
    while s.peek().kind == yamlStartDoc:
      # each document is a stream of its own, ending with a line break
      let trimmed = TrimmingStream(target: output, writeDataImpl: trimmingWrite)
      present(nextDocument(s), trimmed, options)
      output.write("\n")
    discard s.next() # yamlEndStream
  output.commit()
  target.flush()

proc render(events: BufferYamlStream, format: DataFormat,
    yamlStyle: FormatConfig): string =
  ## Renders the stream ``events``, which has no end event yet; see
  ## `writeStream`.
  events.put(endStreamEvent())
  let output = newStringStream()
  writeStream(output, events, format, yamlStyle, nil)
  output.data

proc write(output: File, events: BufferYamlStream, format: DataFormat,
    yamlStyle: FormatConfig) =
  ## Writes the stream ``events``, which has no end event yet; see
  ## `writeStream`.
  events.put(endStreamEvent())
  writeStream(newFileStream(output), events, format, yamlStyle, budgetFor(""))

type DocumentsOf = proc (src: YamlSource, format: DataFormat): YamlStream
  ## the documents a command makes of an input, as a stream

proc inputFormat(files: seq[string], name: string,
    source: Option[DataFormat]): DataFormat =
  ## The format of the input ``name``: ``source`` if given, else by its
  ## extension; standard input is YAML.
  source.get(if files.len == 0: dfYaml else: formatOf(name))

proc concatenated(files: seq[string], source: Option[DataFormat],
    each: DocumentsOf, current: ref string): YamlStream =
  ## One stream of the documents ``each`` makes of every input, opened one
  ## after the other; ``current`` is the name of the input being read.
  let names = if files.len == 0: @[""] else: files
  initYamlStream(iterator(): Event {.gcsafe, raises: [CatchableError].} =
    yield startStreamEvent()
    for name in names:
      var
        src: YamlSource
        s: YamlStream
      {.cast(gcsafe), cast(raises: [CatchableError]).}:
        src = openInput(name)
        current[] = src.name
        s = each(src, inputFormat(files, name, source))
      try:
        while true:
          let e = s.next()
          if e.kind == yamlEndStream: break
          if e.kind != yamlStartStream: yield e
      finally: src.close()
    yield endStreamEvent())

proc failedInput(name: string, e: ref Exception): int =
  ## Reports the error ``e`` of reading the input ``name``; see `failed`.
  ## An input that cannot be read is an I/O error, exit code 2.
  let cause = rootCause(e)
  if cause of IOError or cause of OSError:
    stderr.writeLine(cause.msg)
    return 2
  if cause of YamlMergeError:
    let m = (ref YamlMergeError)(cause).mark
    stderr.writeLine(name & ":" & $m.line & ":" & $m.column & ": " & cause.msg)
    return 1
  failed(name, e)

proc commitFiles(temps: seq[tuple[temp, file: string]]) =
  ## Replaces each file by its temporary file, and builds its index if
  ## files there are indexed.
  for (temp, file) in temps:
    moveFile(temp, file)
    let format = formatOf(file)
    let settings = indexSettingsFor(file)
    if format.indexable and settings.mode != imOff:
      refreshIndex(file, readText(file).content, settings,
          json = format != dfYaml)

proc writeDocuments(files: seq[string], source, target: Option[DataFormat],
    inPlace: bool, each: DocumentsOf): int =
  ## Writes the documents ``each`` makes of all inputs: as one stream on
  ## stdout, in the format ``target`` or else that of the first input, or
  ## with ``inPlace``, each into its file, in its own format. Files are
  ## replaced only once all of them have been written, so that an error
  ## leaves every file as it was.
  if inPlace:
    var temps: seq[tuple[temp, file: string]]
    proc removeTemps() =
      for (temp, _) in temps:
        try: removeFile(temp)
        except OSError: discard
    var name = ""
    try:
      for file in files:
        let
          src = openInput(file)
          format = inputFormat(files, file, source)
          temp = file & ".yaml-tmp-" & $getCurrentProcessId()
        name = src.name
        temps.add((temp, file))
        let output = newFileStream(temp, fmWrite)
        if output.isNil:
          src.close()
          raise newException(IOError, temp & ": cannot write")
        try:
          writeStream(output, each(src, format), format,
              toolConfigFor(file).format, src.budget)
        finally:
          output.close()
          src.close()
    except YamlStreamError, YamlParserError, YamlConstructionError,
        YamlPresenterJsonError, YamlPresenterCborError,
        YamlPresenterOutputError, YamlMemoryLimitError:
      removeTemps()
      return failedInput(name, getCurrentException())
    except IOError, OSError:
      removeTemps()
      raise
    commitFiles(temps)
    return 0
  let
    names = if files.len == 0: @[""] else: files
    format = target.get(inputFormat(files, names[0], source))
    yamlStyle = toolConfigFor(configFile(names[0])).format
    current = new string
    output = newFileStream(stdout)
  try:
    writeStream(output, concatenated(files, source, each, current), format,
        yamlStyle, budgetFor(names[0]))
  except YamlStreamError:
    output.flush()
    return failedInput(current[], getCurrentException())
  except YamlPresenterJsonError, YamlPresenterCborError,
      YamlPresenterOutputError, YamlMemoryLimitError:
    output.flush()
    return failed("<output>", getCurrentException())

# commands

type ComparingStream = ref object of StreamObj
  ## Compares what is written to it with ``expected``.
  expected: Stream
  buffer: string
  differs: bool

proc comparingWrite(s: Stream, buffer: pointer, bufLen: int) =
  let c = ComparingStream(s)
  if c.differs or bufLen == 0: return
  c.buffer.setLen(bufLen)
  var n: int
  {.cast(tags: []).}: n = c.expected.readData(addr c.buffer[0], bufLen)
  if n != bufLen or not equalMem(addr c.buffer[0], buffer, bufLen):
    c.differs = true

proc differs(c: ComparingStream): bool =
  ## Whether what was written differs from all of ``expected``.
  c.differs or not c.expected.atEnd

proc sameContent(a: string, b: YamlSource): bool =
  ## Whether the file ``a`` has the content of ``b``.
  if getFileSize(a) != b.size: return false
  let
    fa = newFileStream(a, fmRead)
    fb = newSourceStream(b)
  defer: fa.close()
  var x, y = newString(65536)
  while true:
    let n = fa.readData(addr x[0], x.len)
    if fb.readData(addr y[0], y.len) != n: return false
    if n == 0: return true
    if not equalMem(addr x[0], addr y[0], n): return false

proc hasComments(src: YamlSource): bool =
  ## Whether ``src`` has a comment. False if the lexer fails, which
  ## formatting then reports.
  var lex: Lexer
  lex.directiveExtensions = true
  lex.keepComments = true
  lex.init(newSourceStream(src))
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
  for file in (if files.len == 0: @[""] else: files):
    # comments need random access to the lines next to the events
    let src = openInput(file, randomAccess = true)
    defer: src.close()
    let name = src.name
    var style =
      if explicit.isSome: explicit.get().format
      else: toolConfigFor(configFile(file)).format
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
        not dumper.presentation.keepsComments and hasComments(src):
      stderr.writeLine(name & ": has comments, which the " &
          $style.style.get(fsDefault) & " style cannot keep; " &
          "use --drop-comments to format it anyway")
      result = 1
      continue
    # the output is written as the input is read: compared with the input,
    # into a temporary file that replaces the file if it differs, or on
    # standard output
    let temp = file & ".yaml-tmp-" & $getCurrentProcessId()
    try:
      if checkOnly:
        let compared = ComparingStream(expected: newSourceStream(src),
            writeDataImpl: comparingWrite)
        dumper.transform(src, compared)
        if compared.differs:
          stdout.writeLine(name)
          result = 1
      elif write:
        let output = newFileStream(temp, fmWrite)
        if output.isNil: raise newException(IOError, temp & ": cannot write")
        try: dumper.transform(src, output)
        finally: output.close()
        if sameContent(temp, src): removeFile(temp)
        else: commitFiles(@[(temp, file)])
      else:
        let output = newFileStream(stdout)
        try: dumper.transform(src, output)
        finally: output.flush()
    except YamlParserError, YamlPresenterJsonError, YamlPresenterOutputError,
        YamlMemoryLimitError:
      if fileExists(temp): removeFile(temp)
      result = max(result, failed(name, getCurrentException()))

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
  writeDocuments(files, source, some(target), false, events)

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

iterator selected(src: YamlSource, format: DataFormat, path: JsonPath,
    indexed: bool): tuple[path: string, node: YamlNode] =
  ## The nodes ``path`` selects in ``src``, document by document. With
  ## ``indexed`` (``src`` is a file that may be indexed), a path that names
  ## a single location is read through the index, and the index is brought
  ## up to date otherwise.
  let
    location = path.normalizedPath
    settings =
      if indexed and format.indexable: indexSettingsFor(src.name)
      else: IndexSettings(mode: imOff)
    nodes =
      if location.len > 0 and settings.mode != imOff:
        indexedNodes(src.name, location, settings)
      else: none(seq[YamlNode])
  if nodes.isSome:
    for node in nodes.get(): yield (location, node)
  else:
    var s = events(src, format)
    discard s.next() # yamlStartStream
    while s.peek().kind == yamlStartDoc:
      var root: YamlNode
      let charged = construct(s, root, src.budget)
      for found in root.queryLocated(path): yield (found.path, found.node)
      src.budget.release(charged)
    if settings.mode != imOff:
      # the index is built from the whole text (see yaml/nodeindex)
      updateIndex(src.name, readText(src.name).content, [location], settings,
          json = format != dfYaml)

proc selectCommand(path: JsonPath, files: seq[string],
    source, target: Option[DataFormat], paths: bool): int =
  ## ``yaml query`` without an assignment: the selected nodes are written as
  ## they are found, or with ``paths``, their Normalized Paths.
  if paths:
    for input in inputSources(files):
      try:
        for found in selected(input, inputFormat(files, input.name, source),
            path, indexed = files.len > 0):
          stdout.writeLine(found.path)
      except YamlStreamError, YamlParserError, YamlConstructionError:
        return failedInput(input.name, getCurrentException())
    return 0
  proc nodes(src: YamlSource, format: DataFormat): YamlStream =
    initYamlStream(iterator(): Event {.gcsafe, raises: [CatchableError].} =
      yield startStreamEvent()
      {.cast(gcsafe), cast(raises: [CatchableError]).}:
        for found in selected(src, format, path, indexed = files.len > 0):
          for e in represent(found.node):
            if e.kind notin {yamlStartStream, yamlEndStream}: yield e
      yield endStreamEvent())
  writeDocuments(files, source, some(target.get(dfYaml)), false, nodes)

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
  if not assigns: return selectCommand(path, files, source, target, paths)
  let
    yamlStyle = toolConfigFor(
        if files.len > 0: files[0] else: getCurrentDir() / "-").format
    selected = newStream()
  var asText = false # the edited text of a single input is written as is
  for name in (if files.len == 0: @[""] else: files):
    let format = source.get(if files.len == 0: dfYaml else: formatOf(name))
    let input = readText(name, randomAccess = assigns)
    try:
      if assigns:
        let edited = assigned(input, format, path, valueText,
            if files.len == 0: yamlStyle
            else: toolConfigFor(input.name).format)
        if inPlace:
          if edited.count > 0: writeSource(input.name, edited.text)
        elif files.len <= 1 and target.isNone and format != dfCbor:
          asText = true
          stdout.write(edited.text)
        else: selected.collect(events((input.name, edited.text), format))
    except YamlEditError as e:
      stderr.writeLine(input.name & ": " & e.msg)
      return 1
    except YamlStreamError, YamlParserError, YamlConstructionError,
        YamlPresenterCborError:
      return failed(input.name, getCurrentException())
  if not (paths or inPlace or asText):
    try:
      stdout.write(selected, target.get(dfYaml), yamlStyle)
    except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
      return failed("<output>", getCurrentException())

iterator eachDocument(input: YamlSource, format: DataFormat): YamlNode =
  ## The documents of ``input`` as graphs, one at a time.
  var s = events(input, format)
  discard s.next() # yamlStartStream
  while s.peek().kind == yamlStartDoc:
    var root: YamlNode
    let charged = construct(s, root, input.budget)
    yield root
    input.budget.release(charged)

proc documents(input: YamlSource, format: DataFormat): seq[YamlNode] =
  ## The documents of ``input`` as graphs.
  for root in eachDocument(input, format): result.add(root)

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
  proc transformed(src: YamlSource, format: DataFormat): YamlStream =
    initYamlStream(iterator(): Event {.gcsafe, raises: [CatchableError].} =
      var s = events(src, format)
      yield s.next() # yamlStartStream
      while s.peek().kind == yamlStartDoc:
        var root: YamlNode
        let charged = construct(s, root, src.budget)
        # tsAll keeps every node's own tag, so "1" stays a string
        var doc: YamlStream
        {.cast(gcsafe), cast(raises: [CatchableError]).}:
          doc = represent(transform(root), SerializationOptions(tagStyle: tsAll))
        for e in doc:
          if e.kind notin {yamlStartStream, yamlEndStream}: yield e
        src.budget.release(charged)
      yield s.next()) # yamlEndStream
  result = writeDocuments(files, source, target, inPlace, transformed)

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
      let src = openInput(file)
      defer: src.close()
      let docs = documents(src, formatOf(file))
      if docs.len != 1:
        stderr.writeLine(file & ": a patch must be a single document")
        return 1
      patch = docs[0]
      if patch.kind == ySequence and not mergePatch:
        jsonPatch = parseJsonPatch(patch)
    except YamlStreamError, YamlParserError, YamlConstructionError:
      return failed(file, getCurrentException())
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
  proc merged(src: YamlSource, format: DataFormat): YamlStream =
    mergeKeysApplied(events(src, format), src.budget)
  writeDocuments(files, source, target, inPlace, merged)

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
  for input in inputSources(files):
    let format = source.get(
        if files.len == 0: dfYaml else: formatOf(input.name))
    try:
      for root in eachDocument(input, format):
        stdout.writeLine(canonicalJson(root))
    except YamlStreamError, YamlParserError, YamlConstructionError:
      return failed(input.name, getCurrentException())
    except YamlJcsError as e:
      stderr.writeLine(input.name & ": " & e.msg)
      return 1

type
  ColorMode = enum
    cmAuto = "auto", cmAlways = "always", cmNever = "never"

proc diffLine(change: DiffChange, document: int, numbered, asJsonPath,
    color: bool): string =
  ## ``change`` as a line of the report, its path prefixed with ``#N`` if
  ## ``numbered``.
  let
    path = if change.kind == dkRemoved: change.oldPath else: change.newPath
    (sign, code) = case change.kind
      of dkAdded: ("+", "32")
      of dkRemoved: ("-", "31")
      of dkChanged: ("~", "33")
  var name = if asJsonPath: path.toJsonPath else: path.toJsonPointer
  if numbered:
    name = "#" & $(document + 1) & (if name.len > 0: " " & name else: "")
  elif name.len == 0: name = "(root)"
  let value = case change.kind
    of dkAdded: change.newNode.flowText
    of dkRemoved: change.oldNode.flowText
    of dkChanged: change.oldNode.flowText & " -> " & change.newNode.flowText
  result = sign & " " & name & ": " & value
  if color: result = "\e[" & code & "m" & result & "\e[0m"

proc diffCommand(args: seq[string]): int =
  var
    positional: seq[string]
    source, target = none(DataFormat)
    asJsonPath, quiet, patch, mergePatch = false
    colorMode = cmAuto
  for kind, key, val in options(args):
    case kind
    of cmdArgument: positional.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "": positional.add("-") # a lone - is standard input
      of "from": source = some(parseFormat("diff", val))
      of "to": target = some(parseFormat("diff", val))
      of "paths":
        if val notin ["pointer", "path"]: fail("diff")
        asJsonPath = val == "path"
      of "color", "colour":
        var known = false
        for m in ColorMode:
          if val == $m:
            colorMode = m
            known = true
        if not known: fail("diff")
      of "quiet", "q": quiet = true
      of "patch": patch = true
      of "merge-patch": mergePatch = true
      else: fail("diff")
    of cmdEnd: discard
  # git calls a diff driver with PATH OLD-FILE OLD-HEX OLD-MODE NEW-FILE
  # NEW-HEX NEW-MODE, and stops if it exits with anything but 0
  let gitDriver = positional.len == 7
  if positional.len notin [2, 7] or (patch and mergePatch) or
      (target.isSome and not (patch or mergePatch)): fail("diff")
  let
    files = if gitDriver: @[positional[1], positional[4]] else: positional
    # git's temporary files need not have the extension of the path
    names = if gitDriver: @[positional[0], positional[0]] else: files
  # the documents of both files are compared pair by pair, as they are read
  var
    inputs: array[2, YamlSource]
    streams: array[2, YamlStream]
    formats: array[2, DataFormat]
    docs: array[2, YamlNode] # the current pair; nil after the last one
    charged: array[2, int]
    side = 0 # the file being read
  proc readNext(i: int) =
    side = i
    docs[i] = nil
    charged[i] = 0
    if streams[i].peek().kind == yamlStartDoc:
      charged[i] = construct(streams[i], docs[i], inputs[i].budget)
  proc release() =
    for i in 0 .. 1:
      inputs[i].budget.release(charged[i])
      charged[i] = 0
  proc remaining(i: int): int =
    ## Skips the documents of file ``i`` that are left, and counts them.
    side = i
    while streams[i].peek().kind == yamlStartDoc:
      while streams[i].next().kind != yamlEndDoc: discard
      inc result
  try:
    for i in 0 .. 1:
      side = i
      inputs[i] = openInput(files[i])
      formats[i] = source.get(
          if files[i] == "-": dfYaml else: formatOf(names[i]))
      streams[i] = events(inputs[i], formats[i])
      discard streams[i].next() # yamlStartStream
    readNext(0)
    readNext(1)
  except YamlStreamError, YamlParserError, YamlConstructionError:
    return max(2, failed(inputs[side].name, getCurrentException()))
  if patch or mergePatch:
    let output = newStream()
    var count = 0
    try:
      while not docs[0].isNil and not docs[1].isNil:
        if not semanticEquals(docs[0], docs[1]): result = 1
        let made =
          if patch: toJsonPatch(diff(docs[0], docs[1]))
          else: createMergePatch(docs[0], docs[1])
        # tsAll keeps every node's own tag, so "1" stays a string
        output.collect(represent(made, SerializationOptions(tagStyle: tsAll)))
        inc count
        release()
        readNext(0)
        readNext(1)
      if not docs[0].isNil or not docs[1].isNil:
        let
          old = count + ord(not docs[0].isNil) + remaining(0)
          new = count + ord(not docs[1].isNil) + remaining(1)
        stderr.writeLine("the files have " & $old & " and " & $new &
            " documents; a patch needs the same number")
        return 2
    except YamlStreamError, YamlParserError, YamlConstructionError:
      return max(2, failed(inputs[side].name, getCurrentException()))
    let yamlStyle = toolConfigFor(
        if files[1] == "-": getCurrentDir() / "-" else: files[1]).format
    try:
      stdout.write(output, target.get(formats[1]), yamlStyle)
    except YamlPresenterJsonError, YamlPresenterCborError, YamlStreamError:
      return max(2, failed("<output>", getCurrentException()))
    return
  let color = case colorMode
    of cmAuto: isatty(stdout)
    of cmAlways: true
    of cmNever: false
  var
    printedHeading = false
    numbered = false # either file has more than one document
    i = 0
  try:
    numbered = streams[0].peek().kind == yamlStartDoc or
        streams[1].peek().kind == yamlStartDoc
    while not docs[0].isNil or not docs[1].isNil:
      let changes =
        if docs[0].isNil: @[DiffChange(kind: dkAdded, newNode: docs[1])]
        elif docs[1].isNil: @[DiffChange(kind: dkRemoved, oldNode: docs[0])]
        else: diff(docs[0], docs[1])
      if changes.len > 0:
        result = 1
        if quiet: break
        if gitDriver and not printedHeading:
          let heading = "semantic diff " & positional[0]
          stdout.writeLine(if color: "\e[1m" & heading & "\e[0m" else: heading)
          printedHeading = true
        for change in changes:
          stdout.writeLine(change.diffLine(i, numbered, asJsonPath, color))
      release()
      readNext(0)
      readNext(1)
      inc i
  except YamlStreamError, YamlParserError, YamlConstructionError:
    return max(2, failed(inputs[side].name, getCurrentException()))
  if gitDriver: result = 0

proc configCommand(args: seq[string]): int =
  var
    dir = ""
    configPath = ""
    print, force = false
  for kind, key, val in options(args):
    case kind
    of cmdArgument:
      if dir.len > 0: fail("config")
      dir = key
    of cmdLongOption, cmdShortOption:
      case key
      of "config":
        if val.len == 0: fail("config")
        configPath = val
      of "print": print = true
      of "force", "f": force = true
      else: fail("config")
    of cmdEnd: discard
  if dir.len == 0: dir = getCurrentDir()
  if not dirExists(dir): raise newException(OSError, dir & ": no such directory")
  if configPath.len == 0: configPath = findToolConfig(dir)
  let
    config =
      if configPath.len > 0: loadToolConfig(configPath)
      else: defaultToolConfig()
    source = if configPath.len > 0: absolutePath(configPath) else: "the defaults"
    content = "# the config in effect for\n#   " & absolutePath(dir) &
        "\n# from\n#   " & source & "\n" & $config
  if print:
    stdout.write(content)
    return 0
  let target = dir / toolConfigFileNames[1]
  if fileExists(dir / toolConfigFileNames[0]):
    stderr.writeLine(dir / toolConfigFileNames[0] & " exists, and a " &
        "directory cannot have both .yaml and .yaml.yaml; remove it or use " &
        "--print")
    return 1
  if fileExists(target) and not force:
    stderr.writeLine(target & " exists; use --force to replace it")
    return 1
  writeFile(target, content)

proc lspCommand(args: seq[string]): int =
  for arg in args:
    if arg != "--stdio" and not arg.startsWith("--clientProcessId"):
      fail("lsp")
  serve(newFileStream(stdin), stdout)

proc indexCommand(args: seq[string]): int =
  var
    files: seq[string]
    mode = none(IndexMode)
    format = none(IndexFormat)
    location = none(IndexLocation)
    print, drop = false
  for kind, key, val in options(args):
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "mode":
        try: mode = some(parseEnum[IndexMode](val))
        except ValueError: fail("index")
      of "format":
        try: format = some(parseEnum[IndexFormat](val))
        except ValueError: fail("index")
      of "location":
        try: location = some(parseEnum[IndexLocation](val))
        except ValueError: fail("index")
      of "print": print = true
      of "drop": drop = true
      else: fail("index")
    of cmdEnd: discard
  if files.len == 0 or (print and drop) or mode == some(imOff):
    fail("index")
  for file in files:
    let dataFormat = formatOf(file)
    if not dataFormat.indexable:
      stderr.writeLine(file & ": only YAML and JSON files are indexed")
      result = 1
      continue
    var settings = indexSettingsFor(file)
    if mode.isSome: settings.mode = mode.get()
    elif settings.mode == imOff: settings.mode = imAll
    if format.isSome: settings.format = format.get()
    if location.isSome: settings.location = location.get()
    let indexPath = indexFile(file, settings)
    if drop:
      if dropIndex(file, settings): stdout.writeLine(indexPath)
      continue
    let
      content = readText(file, randomAccess = true).content
      json = dataFormat != dfYaml
      old = readIndex(indexPath, settings.format)
      current = old.isSome and old.get().mode == settings.mode and
          old.get().json == json and
          old.get().source.hash == fingerprint(content).hash
    var index: YamlIndex
    if current: index = old.get()
    else:
      try:
        let spans = sourceSpans(content, json)
        index = buildIndex(content, spans, settings.mode, json,
            modificationTime(file))
        # a recent index keeps its paths, looked up in the new content
        if settings.mode == imRecent and old.isSome:
          for lookup in old.get().lookups:
            index.record(content, spans, lookup.path, lookup.used,
                settings.recentLimit)
      except YamlParserError, YamlStreamError, YamlSpanError:
        result = max(result, failed(file, getCurrentException()))
        continue
    index.source.mtime = modificationTime(file)
    if print:
      stdout.write(blockOnlyDumper().dump(index))
    elif index.writeIndex(indexPath, settings.format):
      stdout.writeLine(indexPath)
    else:
      stderr.writeLine(indexPath & ": cannot write the index")
      result = 2

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
  let command = args[0]
  var rest: seq[string]
  try: rest = takeMemoryOptions(args[1 .. ^1])
  except UsageError as e:
    stderr.writeLine(e.msg)
    return 2
  if command in ["-h", "--help"]: return helpCommand(@[])
  if usageOf(command).len > 0 and command != "help" and
      rest.wantsHelp:
    return helpCommand(@[command])
  try:
    case command
    of "lint":
      yamllint.run(rest, lmLint, lintUsage, toolConfigs = true,
          openInput = randomInput)
    of "validate":
      yamllint.run(rest, lmValidate, validateUsage, toolConfigs = true,
          openInput = randomInput)
    of "format": formatCommand(rest)
    of "convert", "as", "to": convertCommand(command, rest)
    of "query": queryCommand(rest)
    of "patch": patchCommand(rest)
    of "merge": mergeCommand(rest)
    of "canonical", "jcs": canonicalCommand(rest)
    of "diff": diffCommand(rest)
    of "expand": yamlexpand.run(rest, stdin, stdout, randomInput)
    of "config": configCommand(rest)
    of "index": indexCommand(rest)
    of "lsp": lspCommand(rest)
    of "help": helpCommand(rest)
    else:
      if command.startsWith("$"): queryCommand(command & rest)
      else:
        stderr.writeLine("unknown command: " & command & "\n\n" & overview)
        2
  except UsageError as e:
    stderr.writeLine(e.msg)
    2
  except ToolConfigError as e:
    stderr.writeLine("config error: " & e.msg)
    2
  except YamlMemoryLimitError as e:
    stderr.writeLine(e.describe & ". Raise memory.limit or use --memory-limit")
    3
  except IOError, OSError:
    stderr.writeLine(getCurrentExceptionMsg())
    2
  finally:
    # sources whose reading an error abandoned, and their spool files
    for src in opened: src.close()
    opened.setLen(0)

when isMainModule:
  quit(run(commandLineParams()))
