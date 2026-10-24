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
##   format:
##     style: default   # default, minimal, explanatory, json, json-lines
##                      # or block-only
##     indentation: 2
##     max-line-length: 80  # 0 for no limit
##     comments: keep   # or drop
##     comment-indentation: node  # or source: the column in the input
##     comment-gap: 2   # spaces between content and a comment after it
##     comment-blank-lines: keep  # or drop: blank lines next to comments
##
## The comment keys are described at ``CommentOptions`` of
## `yaml/presenter <presenter.html>`_. The ``minimal``, ``json`` and
## ``json-lines`` styles have no room for comments.
##
## A legacy ``.nimyaml-lint.yaml`` holds only what the ``lint`` section
## holds; it is still found, as a config with defaults for the other
## sections.

import std/[options, os, strutils]
when defined(nimPreviewSlimSystem):
  import std/syncio
import annotations, presenter, dumping, loading, lint
export options, lint

type
  FormatStyle* = enum
    fsDefault = "default", fsMinimal = "minimal",
    fsExplanatory = "explanatory", fsJson = "json", fsJsonLines = "json-lines", fsBlockOnly = "block-only"

  Keeping* = enum
    kKeep = "keep", kDrop = "drop"

  ValidateConfig* {.sparse.} = object
    schema*: Option[bool] ## none: validate

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

  ToolConfig* = object
    lint* {.defaultVal: defaultConfig().}: LintConfig
    validate* {.defaultVal: ValidateConfig().}: ValidateConfig
    format* {.defaultVal: FormatConfig().}: FormatConfig

  ToolConfigError* = object of ValueError

const
  toolConfigFileNames* = [".yaml", ".yaml.yaml"]
    ## the names of a config file, in the order they are looked for

proc defaultToolConfig*(): ToolConfig = ToolConfig()

proc validateSchemas*(config: ToolConfig): bool =
  ## Whether documents are validated against the schemas they declare.
  config.validate.schema.get(true)

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
