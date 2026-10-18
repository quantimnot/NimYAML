#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamllint: lints YAML files with NimYAML's lint engine.
##
## Usage: ``yamllint [--config:FILE] FILE...``
##
## Without ``--config``, each file is linted with the ``.nimyaml-lint.yaml``
## found by walking up from its directory, or the defaults. Prints one line
## per diagnostic. Exit code: 0 without error diagnostics, 1 with, 2 for
## usage, I/O or config errors.

import std/[os, parseopt]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/lint

const usage = "usage: yamllint [--config:FILE] FILE..."

proc configFor(file: string): LintConfig =
  let path = findLintConfig(parentDir(absolutePath(file)))
  if path.len == 0: defaultConfig() else: loadLintConfig(path)

proc run*(args: seq[string]): int =
  var
    configPath = ""
    files: seq[string]
    p = initOptParser(args)
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      if key == "config" and val.len > 0: configPath = val
      else:
        stderr.writeLine(usage)
        return 2
    of cmdEnd: discard
  if files.len == 0:
    stderr.writeLine(usage)
    return 2
  try:
    let explicit =
      if configPath.len > 0: some(loadLintConfig(configPath))
      else: none(LintConfig)
    for file in files:
      let config = if explicit.isSome: explicit.get() else: configFor(file)
      for d in lint(readFile(file), config):
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
