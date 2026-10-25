#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===================
## Module yaml/toolconfig
## ===================
##
## The configuration shared by the ``yaml`` command line tool and its
## language server: one file, named ``.yaml`` or ``.yaml.yaml``, configures
## linting, validation and formatting for the files in its directory and
## below. Every section and key may be omitted:
##
## .. code-block:: yaml
##   lint:              # a LintConfig, see yaml/lint
##     rules:
##       line-length: {max: 100}
##       truthy: {level: off}
##   validate:
##     schema: true     # validate against declared JSON Schemas (default)
##     remote-schemas: true  # may use http(s): schemas (default)
##     schema-cache: user    # where downloaded schemas are kept: project,
##                           # user (default), system or off
##   format:
##     style: default   # default, minimal, explanatory, json, json-lines
##                      # or block-only
##     indentation: 2
##     max-line-length: 80  # 0 for no limit
##     comments: keep   # or drop
##     comment-indentation: node  # or source: the column in the input
##     comment-gap: 2   # spaces between content and a comment after it
##     comment-blank-lines: keep  # or drop: blank lines next to comments
##   index:
##     mode: off        # off (default), recent or all
##     format: cbor     # cbor (default) or yaml
##     location: user   # beside, project or user (default)
##     recent-limit: 256  # paths a recent index keeps
##   memory:
##     limit: auto      # auto (half the host memory), unlimited or a size
##                      # like 64MiB
##     source: auto     # auto, memory, mmap, seek or stream
##     mmap: auto       # or off: never map files
##     map-window: auto # size of a mapped window (64MiB)
##     page-cache: auto # cached pages of a seekable file
##     spool: auto      # or off: read streams that need random access
##                      # into memory instead of a temporary file
##     spool-dir: auto  # directory of spooled streams
##
## ``remote-schemas: false`` keeps schemas from the network out of the
## validation of the files the config applies to, so that opening a file
## does not reveal it to the server its schema reference names. The ``yaml``
## tool never accesses the network anyway; the language server then does
## not ask the editor to download ``http:`` and ``https:`` schemas, and
## reports them as unavailable.
##
## ``schema-cache`` chooses the cache of downloaded schemas that is
## written; all of them are read (see `schemacache <schemacache.html>`_).
## A ``project`` cache is the directory ``.yaml-schemas`` next to the
## config file. Cached schemas are used with ``remote-schemas: false``
## too: that keeps schemas from being downloaded, not from being used.
##
## The comment keys are described at ``CommentOptions`` of
## `yaml/presenter <presenter.html>`_. The ``minimal``, ``json`` and
## ``json-lines`` styles have no room for comments.
##
## The ``index`` section configures the index of node locations that lets
## ``yaml query`` read a node from its slice of a file instead of parsing
## all of it (see `nodeindex <nodeindex.html>`_). A ``project`` index lives
## in the directory ``.yaml-index`` next to the config file.
##
## The ``memory`` section sets the memory budget of the ``yaml`` tool and
## how it reads files (see `memory <memory.html>`_ and `source
## <source.html>`_): huge files are read through a window of memory, and a
## command that would exceed the limit fails with exit code 3 instead.
##
## A legacy ``.nimyaml-lint.yaml`` holds only what the ``lint`` section
## holds; it is still found, as a config with defaults for the other
## sections.

import std/[options, os, strutils]
when defined(nimPreviewSlimSystem):
  import std/syncio
import annotations, presenter, dumping, loading, lint, nodeindex, schemacache,
    memory, source
export options, lint, SchemaCacheLocation, IndexMode, IndexFormat,
    IndexLocation, IndexSettings, TierChoice, Switch, SourcePolicy

type
  FormatStyle* = enum
    fsDefault = "default", fsMinimal = "minimal",
    fsExplanatory = "explanatory", fsJson = "json", fsJsonLines = "json-lines", fsBlockOnly = "block-only"

  Keeping* = enum
    kKeep = "keep", kDrop = "drop"

  ValidateConfig* {.sparse.} = object
    schema*: Option[bool] ## none: validate
    remoteSchemas* {.yamlKey: "remote-schemas".}: Option[bool]
      ## none: allowed
    schemaCache* {.yamlKey: "schema-cache".}: Option[SchemaCacheLocation]
      ## none: user

  FormatConfig* {.sparse.} = object
    style*: Option[FormatStyle]
    indentation*: Option[int]
    maxLineLength* {.yamlKey: "max-line-length".}: Option[int]
      ## 0: no limit
    comments*: Option[Keeping] ## none: keep
    commentIndentation* {.yamlKey: "comment-indentation".}:
      Option[CommentIndentation]
    commentGap* {.yamlKey: "comment-gap".}: Option[int]
    commentBlankLines* {.yamlKey: "comment-blank-lines".}: Option[Keeping]

  IndexConfig* {.sparse.} = object
    mode*: Option[IndexMode]         ## none: off
    format*: Option[IndexFormat]     ## none: cbor
    location*: Option[IndexLocation] ## none: user
    recentLimit* {.yamlKey: "recent-limit".}: Option[int]
      ## none: 256

  MemoryConfig* {.sparse.} = object
    limit*: Option[string]           ## auto, unlimited or a size; none: auto
    source*: Option[TierChoice]      ## none: auto
    mmap*: Option[Switch]            ## none: auto
    mapWindow* {.yamlKey: "map-window".}: Option[string]
      ## auto or a size; none: auto
    pageCache* {.yamlKey: "page-cache".}: Option[string]
      ## auto or a size; none: auto
    spool*: Option[Switch]           ## none: auto
    spoolDir* {.yamlKey: "spool-dir".}: Option[string]
      ## auto or a directory; none: auto

  ToolConfig* = object
    lint* {.defaultVal: defaultConfig().}: LintConfig
    validate* {.defaultVal: ValidateConfig().}: ValidateConfig
    format* {.defaultVal: FormatConfig().}: FormatConfig
    index* {.defaultVal: IndexConfig().}: IndexConfig
    memory* {.defaultVal: MemoryConfig().}: MemoryConfig

  ToolConfigError* = object of ValueError

const
  toolConfigFileNames* = [".yaml", ".yaml.yaml"]
    ## the names of a config file, in the order they are looked for

proc defaultToolConfig*(): ToolConfig = ToolConfig()

proc validateSchemas*(config: ToolConfig): bool =
  ## Whether documents are validated against the schemas they declare.
  config.validate.schema.get(true)

proc remoteSchemas*(config: ToolConfig): bool =
  ## Whether schemas from the network (``http:``, ``https:``) may be used.
  config.validate.remoteSchemas.get(true)

proc schemaCache*(config: ToolConfig): SchemaCacheLocation =
  ## The cache downloaded schemas are written to.
  config.validate.schemaCache.get(sclUser)

proc indexSettings*(config: ToolConfig, configDir = ""): IndexSettings =
  ## How files that ``config`` applies to are indexed; ``configDir`` is the
  ## directory of the config file, where a ``project`` index lives.
  IndexSettings(mode: config.index.mode.get(imOff),
      format: config.index.format.get(ifCbor),
      location: config.index.location.get(ilUser),
      recentLimit: config.index.recentLimit.get(defaultRecentLimit),
      configDir: configDir)

proc sizeOrAuto(value: Option[string]): int =
  ## The size of ``value``; 0 for none or ``auto``.
  if value.isNone or value.get() == "auto": 0 else: parseSize(value.get())

proc memoryLimit*(config: ToolConfig): int =
  ## The memory limit, in bytes: the configured size, or `autoLimit` for
  ## ``auto``.
  let limit = config.memory.limit.get("auto")
  if limit == "auto": autoLimit() else: parseSize(limit)

proc sourcePolicy*(config: ToolConfig): SourcePolicy =
  ## How the files that ``config`` applies to are read.
  let m = config.memory
  SourcePolicy(choice: m.source.get(tcAuto), mmap: m.mmap.get(swAuto),
      mapWindow: m.mapWindow.sizeOrAuto, pageCache: m.pageCache.sizeOrAuto,
      spool: m.spool.get(swAuto),
      spoolDir: if m.spoolDir.get("auto") == "auto": "" else: m.spoolDir.get())

proc dumper*(style: FormatStyle): Dumper =
  ## The `Dumper` preset of ``style``.
  case style
  of fsDefault: Dumper()
  of fsMinimal: minimalDumper()
  of fsExplanatory: explanatoryDumper()
  of fsJson: jsonDumper()
  of fsJsonLines: jsonLinesDumper()
  of fsBlockOnly: blockOnlyDumper()

proc dumper*(config: FormatConfig): Dumper =
  ## The `Dumper` of ``style`` with ``indentation``, ``max-line-length`` and
  ## the comment keys applied. Its `transform` keeps comments unless
  ## ``comments`` is ``drop``.
  result = dumper(config.style.get(fsDefault))
  if config.indentation.isSome:
    result.presentation.indentationStep = config.indentation.get()
  if config.maxLineLength.isSome:
    let length = config.maxLineLength.get()
    result.presentation.maxLineLength =
      if length == 0: none(int) else: some(length)
  result.presentation.comments = CommentOptions(
    keep: config.comments.get(kKeep) == kKeep,
    indentation: config.commentIndentation.get(ciNode),
    gap: config.commentGap.get(2),
    blankLines: config.commentBlankLines.get(kKeep) == kKeep)

proc resolved*(config: ToolConfig): ToolConfig =
  ## ``config`` with every key set: the configured value or the default
  ## that applies to it, so that dumping it shows the config in effect.
  result.lint = config.lint.resolved
  result.validate.schema = some(config.validateSchemas)
  result.validate.remoteSchemas = some(config.remoteSchemas)
  result.validate.schemaCache = some(config.schemaCache)
  let
    format = config.format
    style = format.style.get(fsDefault)
    presentation = format.dumper.presentation
  result.format = FormatConfig(
    style: some(style),
    indentation: some(presentation.indentationStep),
    maxLineLength: some(presentation.maxLineLength.get(0)),
    comments: some(format.comments.get(kKeep)),
    commentIndentation: some(presentation.comments.indentation),
    commentGap: some(presentation.comments.gap),
    commentBlankLines: some(format.commentBlankLines.get(kKeep)))
  let index = config.indexSettings
  result.index = IndexConfig(mode: some(index.mode),
      format: some(index.format), location: some(index.location),
      recentLimit: some(index.recentLimit))
  let m = config.memory
  result.memory = MemoryConfig(limit: some(m.limit.get("auto")),
      source: some(m.source.get(tcAuto)), mmap: some(m.mmap.get(swAuto)),
      mapWindow: some(m.mapWindow.get("auto")),
      pageCache: some(m.pageCache.get("auto")),
      spool: some(m.spool.get(swAuto)), spoolDir: some(m.spoolDir.get("auto")))

proc `$`*(config: ToolConfig): string =
  ## The content of a config file that `parseToolConfig` reads as
  ## ``config.resolved``: every key, the lint rules in their builtin order,
  ## with comments naming the alternatives.
  let c = config.resolved
  result = "lint:\n  rules:  # level: off, info, warning or error\n"
  for r in builtinRules():
    let rule = c.lint.rules[r.id]
    result.add("    " & r.id & ": {level: " & $rule.level.get())
    if rule.max.isSome: result.add(", max: " & $rule.max.get())
    result.add("}\n")
  result.add("validate:\n  schema: " & $c.validate.schema.get() &
      "  # validate against declared JSON Schemas\n" &
      "  remote-schemas: " & $c.validate.remoteSchemas.get() &
      "  # may use http(s): schemas\n" &
      "  schema-cache: " & $c.validate.schemaCache.get() &
      "  # project, user, system or off\n")
  let f = c.format
  result.add("format:\n" &
      "  style: " & $f.style.get() & "  # default, minimal, explanatory, " &
      "json, json-lines or block-only\n" &
      "  indentation: " & $f.indentation.get() & "\n" &
      "  max-line-length: " & $f.maxLineLength.get() & "  # 0 for no limit\n" &
      "  comments: " & $f.comments.get() & "  # keep or drop\n" &
      "  comment-indentation: " & $f.commentIndentation.get() &
      "  # node or source\n" &
      "  comment-gap: " & $f.commentGap.get() & "\n" &
      "  comment-blank-lines: " & $f.commentBlankLines.get() &
      "  # keep or drop\n")
  let i = c.index
  result.add("index:\n" &
      "  mode: " & $i.mode.get() & "  # off, recent or all\n" &
      "  format: " & $i.format.get() & "  # cbor or yaml\n" &
      "  location: " & $i.location.get() & "  # beside, project or user\n" &
      "  recent-limit: " & $i.recentLimit.get() & "\n")
  let
    m = c.memory
    host = hostMemory()
  result.add("memory:\n" &
      "  limit: " & m.limit.get() & "  # auto, unlimited or a size; " &
      "detected host memory: " &
      (if host > 0: formatSize(host) else: "unknown") & ", auto: " &
      formatSize(autoLimit()) & "\n" &
      "  source: " & $m.source.get() & "  # auto, memory, mmap, seek or stream\n" &
      "  mmap: " & $m.mmap.get() & "  # auto or off\n" &
      "  map-window: " & m.mapWindow.get() & "\n" &
      "  page-cache: " & m.pageCache.get() & "\n" &
      "  spool: " & $m.spool.get() & "  # auto or off\n" &
      "  spool-dir: " & m.spoolDir.get() & "\n")

proc isBlank(content: string): bool =
  for line in content.splitLines:
    let text = line.strip()
    if text.len > 0 and text[0] != '#': return false
  true

proc parseToolConfig*(content: string): ToolConfig =
  ## Parses the content of a ``.yaml`` config file. Blank or comment-only
  ## content yields `defaultToolConfig`. Raises `ToolConfigError` if the
  ## content is invalid.
  if content.isBlank: return defaultToolConfig()
  try:
    load(content, result)
  except YamlLoadingError as e:
    raise newException(ToolConfigError,
        $e.mark.line & ":" & $e.mark.column & ": " & e.msg)
  try:
    checkLintConfig(result.lint)
  except LintConfigError as e:
    raise newException(ToolConfigError, "lint: " & e.msg)
  if result.format.indentation.isSome and
      result.format.indentation.get() notin 1 .. 9:
    raise newException(ToolConfigError,
        "format: indentation must be between 1 and 9")
  if result.format.maxLineLength.isSome and
      result.format.maxLineLength.get() < 0:
    raise newException(ToolConfigError,
        "format: max-line-length must not be negative")
  if result.format.commentGap.isSome and result.format.commentGap.get() < 1:
    raise newException(ToolConfigError,
        "format: comment-gap must be at least 1")
  if result.index.recentLimit.isSome and result.index.recentLimit.get() < 1:
    raise newException(ToolConfigError,
        "index: recent-limit must be at least 1")
  let m = result.memory
  for (key, value, auto) in [("limit", m.limit, true),
      ("map-window", m.mapWindow, true), ("page-cache", m.pageCache, true)]:
    if value.isSome and not (auto and value.get() == "auto"):
      try:
        if parseSize(value.get()) <= 0:
          raise newException(ValueError, "must be positive")
      except ValueError as e:
        raise newException(ToolConfigError, "memory: " & key & ": " & e.msg)

proc loadToolConfig*(path: string): ToolConfig =
  ## Loads the config file at ``path``: a legacy lint config if it is named
  ## ``.nimyaml-lint.yaml``, else a ``.yaml`` config. Raises
  ## `ToolConfigError`, with a message starting with ``path``, if it cannot
  ## be read or is invalid.
  if path.extractFilename() == configFileName:
    try:
      return ToolConfig(lint: loadLintConfig(path))
    except LintConfigError as e:
      raise newException(ToolConfigError, e.msg)
  var content: string
  try:
    content = readFile(path)
  except IOError as e:
    raise newException(ToolConfigError, path & ": " & e.msg)
  try:
    result = parseToolConfig(content)
  except ToolConfigError as e:
    raise newException(ToolConfigError, path & ": " & e.msg)

proc isToolConfigFile*(path: string): bool =
  ## Whether ``path`` names a config file `findToolConfig` looks for.
  let name = path.extractFilename()
  name in toolConfigFileNames or name == configFileName

proc findToolConfig*(dir: string): string =
  ## The path of the config file in ``dir`` or its nearest ancestor that has
  ## one; "" if there is none. In each directory, ``.yaml`` and
  ## ``.yaml.yaml`` are looked for before the legacy ``.nimyaml-lint.yaml``.
  ## Raises `ToolConfigError` if a directory has both ``.yaml`` and
  ## ``.yaml.yaml``, since it is unclear which one is meant.
  var current = absolutePath(dir)
  while true:
    var found = ""
    for name in toolConfigFileNames:
      let path = current / name
      if fileExists(path):
        if found.len > 0:
          raise newException(ToolConfigError, current &
              ": both .yaml and .yaml.yaml exist; keep one of them")
        found = path
    if found.len > 0: return found
    let legacy = current / configFileName
    if fileExists(legacy): return legacy
    let parent = current.parentDir()
    if parent.len == 0 or parent == current: return ""
    current = parent

proc toolConfigFor*(file: string): ToolConfig =
  ## The config of ``file``: the one `findToolConfig` finds from its
  ## directory, or the defaults.
  let path = findToolConfig(parentDir(absolutePath(file)))
  if path.len == 0: defaultToolConfig() else: loadToolConfig(path)

proc indexSettingsFor*(file: string): IndexSettings =
  ## How ``file`` is indexed, by the config that applies to it.
  let path = findToolConfig(parentDir(absolutePath(file)))
  if path.len == 0: defaultToolConfig().indexSettings
  else: loadToolConfig(path).indexSettings(path.parentDir)
