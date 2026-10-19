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
## Without ``--config``, each file is linted with the ``.nimyaml-lint.yaml``
## found by walking up from its directory, or the defaults. Documents that
## declare a JSON Schema (``%SCHEMA``, ``%GLOBAL SCHEMA``, a
## ``yaml-language-server`` modeline or a ``$schema`` key) are also validated
## against it, unless ``--no-schema`` is given; schemas are read from
## ``file:`` URIs only, relative references resolve against the file's own
## location. Prints one line per diagnostic. Exit code: 0 without error
## diagnostics, 1 with, 2 for usage, I/O or config errors.

import std/[os, parseopt]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[lint, jsonschema, schemavalidation]

const usage = "usage: yamllint [--config:FILE] [--no-schema] FILE..."

proc configFor(file: string): LintConfig =
  let path = findLintConfig(parentDir(absolutePath(file)))
  if path.len == 0: defaultConfig() else: loadLintConfig(path)

proc run*(args: seq[string]): int =
  var
    configPath = ""
    files: seq[string]
    validate = true
    p = initOptParser(args)
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
  if files.len == 0:
    stderr.writeLine(usage)
    return 2
  # one registry for all files, so that a schema shared by several files is
  # read once
  let registry = newSchemaRegistry(fileSchemaLoader())
  try:
    let explicit =
      if configPath.len > 0: some(loadLintConfig(configPath))
      else: none(LintConfig)
    for file in files:
      let
        config = if explicit.isSome: explicit.get() else: configFor(file)
        source = readFile(file)
        uri = fileUri(file)
      var diagnostics = lint(source, config, uri)
      if validate: diagnostics.add(validateDocuments(source, registry, uri))
      for d in diagnostics:
        stdout.writeLine(file & ":" & $d)
        if d.severity == severityError: result = 1
  except LintConfigError as e:
    stderr.writeLine("config error: " & e.msg)
    return 2
  except IOError as e:
    stderr.writeLine(e.msg)
    return 2

when isMainModule:
  quit(run(commandLineParams()))
