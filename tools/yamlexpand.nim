#!/usr/bin/env nim r -d:release -d:lto --hints:off --warnings:off --processing:off
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
import ../yaml/[parser, stream, portable, source, memory]
import std/streams

const usage = "usage: yamlexpand [--modeline] [FILE]"

proc run*(args: seq[string], input: File, output: File,
    openInput: proc (file: string): YamlSource = nil): int =
  ## Expands the file named in ``args``, or ``input``, into ``output``.
  ## ``openInput`` opens the input ("" for ``input``) within a memory
  ## budget; without it, it is opened without one. Exit code 3 if the input
  ## exceeds the budget.
  var
    options = ExpandOptions()
    files: seq[string]
    p = initOptParser(args)
  # the parser of an empty command line reads the process's own instead
  if args.len > 0:
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
  var src: YamlSource
  try:
    let file = if files.len == 1: files[0] else: ""
    src =
      if not openInput.isNil: openInput(file)
      elif file.len == 0: openSource(input, "<stdin>", randomAccess = true)
      else: openSource(file)
  except IOError, OSError:
    stderr.writeLine(getCurrentExceptionMsg())
    return 2
  defer: src.close()
  let target = newFileStream(output)
  try:
    expandDirectives(src, target, options)
    target.flush()
  except YamlMemoryLimitError as e:
    stderr.writeLine(src.name & ": " & e.describe &
        ". Raise memory.limit or use --memory-limit")
    return 3
  except IOError, OSError:
    stderr.writeLine(getCurrentExceptionMsg())
    return 2
  except YamlParserError as e:
    let limit = memoryLimitError(e)
    if not limit.isNil:
      stderr.writeLine(src.name & ": " & limit.describe &
          ". Raise memory.limit or use --memory-limit")
      return 3
    let name = if files.len == 1: files[0] else: "<stdin>"
    stderr.writeLine(name & ":" & $e.mark.line & ":" & $e.mark.column & ": " &
        e.msg)
    return 1
  except YamlStreamError as e:
    let limit = memoryLimitError(e)
    if not limit.isNil:
      stderr.writeLine(src.name & ": " & limit.describe &
          ". Raise memory.limit or use --memory-limit")
      return 3
    stderr.writeLine(e.msg)
    return 1

when isMainModule:
  quit(run(commandLineParams(), stdin, stdout))
