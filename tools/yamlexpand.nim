#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## yamlexpand: makes YAML that uses NimYAML's ``%GLOBAL`` directive portable.
##
## Usage: ``yamlexpand [--modeline] [FILE]``
##
## Writes FILE (or standard input) to standard output with every global
## directive expanded into the documents that inherit it, so that YAML
## processors that do not know ``%GLOBAL`` read every document the same way
## NimYAML does (see `yaml/portable <../yaml/portable.html>`_). With
## ``--modeline``, ``%SCHEMA`` directives are written as
## ``# yaml-language-server: $schema=`` comments instead, so that the output
## contains no NimYAML directive at all.
##
## Exit code: 0 on success, 1 if the input is not valid YAML, 2 for usage and
## I/O errors.

import std/[os, parseopt]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[parser, stream, portable]

const usage = "usage: yamlexpand [--modeline] [FILE]"

proc run*(args: seq[string], input: File, output: File): int =
  var
    options = ExpandOptions()
    files: seq[string]
    p = initOptParser(args)
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: files.add(key)
    of cmdLongOption, cmdShortOption:
      if key == "modeline" and val.len == 0: options.schemas = soModeline
      else:
        stderr.writeLine(usage)
        return 2
    of cmdEnd: discard
  if files.len > 1:
    stderr.writeLine(usage)
    return 2
  var source: string
  try:
    source = if files.len == 1: readFile(files[0]) else: input.readAll()
  except IOError as e:
    stderr.writeLine(e.msg)
    return 2
  try:
    output.write(expandDirectives(source, options))
  except YamlParserError as e:
    let name = if files.len == 1: files[0] else: "<stdin>"
    stderr.writeLine(name & ":" & $e.mark.line & ":" & $e.mark.column & ": " &
        e.msg)
    return 1
  except YamlStreamError as e:
    stderr.writeLine(e.msg)
    return 1

when isMainModule:
  quit(run(commandLineParams(), stdin, stdout))
