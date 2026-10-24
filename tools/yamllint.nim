#!/usr/bin/env nim r -d:release -d:lto --hints:off --warnings:off --processing:off
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamllint: lints YAML files with NimYAML's lint engine.
##
## Usage: ``yamllint [--config:FILE] [--no-schema] FILE...``
##
## Without ``--config``, each file is linted with the ``lint`` section of the
## ``.yaml`` or ``.yaml.yaml`` config (see `yaml/toolconfig
## <../yaml/toolconfig.html>`_), or the ``.nimyaml-lint.yaml``, found by
## walking up from its directory, or the defaults. Documents that
## declare a JSON Schema (``%SCHEMA``, ``%GLOBAL SCHEMA``, a
## ``yaml-language-server`` modeline or a ``$schema`` key) are also validated
## against it, unless ``--no-schema`` is given; schemas are read from
## ``file:`` URIs only, relative references resolve against the file's own
## location. Prints one line per diagnostic. Exit code: 0 without error
## diagnostics, 1 with, 2 for usage, I/O or config errors.

import std/[os, parseopt]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[lint, jsonschema, schemavalidation, toolconfig]

type
  LintMode* = enum
    lmLint     ## all rules
    lmValidate ## only the rules that find violations of the YAML spec

const
  usage = "usage: yamllint [--config:FILE] [--no-schema] FILE..."
  styleRules = ["complex-key", "unused-anchor", "truthy", "trailing-spaces",
      "line-length", "tabs", "final-newline", "schema-source"]
    ## the rules `lmValidate` turns off

proc restrict(config: LintConfig, mode: LintMode): LintConfig =
  result = config
  if mode == lmValidate:
    for id in styleRules:
      result.rules[id] = RuleConfig(level: some(levelOff))

proc run*(args: seq[string], mode = lmLint, usage = usage,
    toolConfigs = false, input = stdin): int =
  ## Lints or validates the files named in ``args`` and prints their
  ## diagnostics. With ``toolConfigs``, ``--config`` names a ``.yaml``
  ## config (see `yaml/toolconfig`) instead of a lint config, and without
  ## files ``input`` is read, with the config found from the current
  ## directory.
  var
    configPath = ""
    files: seq[string]
    validate = true
    p = initOptParser(args)
  # the parser of an empty command line reads the process's own instead
  if args.len > 0:
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument: files.add(key)
      of cmdLongOption, cmdShortOption:
        if key == "config" and val.len > 0: configPath = val
        elif key == "no-schema" and val.len == 0: validate = false
        else:
          stderr.writeLine(usage)
          return 2
      of cmdEnd: discard
  if files.len == 0 and not toolConfigs:
    stderr.writeLine(usage)
    return 2
  # one registry for all files, so that a schema shared by several files is
  # read once
  let registry = newSchemaRegistry(fileSchemaLoader())
  try:
    let explicit =
      if configPath.len == 0: none(ToolConfig)
      elif toolConfigs: some(loadToolConfig(configPath))
      else: some(ToolConfig(lint: loadLintConfig(configPath)))
    proc check(name, source, uri: string, config: ToolConfig): int =
      var diagnostics = lint(source, config.lint.restrict(mode), uri)
      if validate and config.validateSchemas:
        diagnostics.add(validateDocuments(source, registry, uri))
      for d in diagnostics:
        stdout.writeLine(name & ":" & $d)
        if d.severity == severityError: result = 1
    if files.len == 0:
      let config =
        if explicit.isSome: explicit.get()
        else: toolConfigFor(getCurrentDir() / "-")
      result = check("<stdin>", input.readAll(), fileUri(getCurrentDir() / "-"),
          config)
    for file in files:
      let config = if explicit.isSome: explicit.get() else: toolConfigFor(file)
      result = max(result, check(file, readFile(file), fileUri(file), config))
  except LintConfigError, ToolConfigError:
    stderr.writeLine("config error: " & getCurrentExceptionMsg())
    return 2
  except IOError as e:
    stderr.writeLine(e.msg)
    return 2

when isMainModule:
  quit(run(commandLineParams()))
