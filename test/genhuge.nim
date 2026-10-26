#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Generators of huge YAML inputs for the constrained-run tests, written in
## chunks so that generating them takes little memory.

import std/strutils
when defined(nimPreviewSlimSystem):
  import std/syncio

proc genManyDocs*(path: string, bytes: int) =
  ## Many small documents with comments, anchors, merge keys and a
  ## ``%GLOBAL`` directive.
  let f = open(path, fmWrite)
  defer: f.close()
  f.write("%GLOBAL TAG !e! tag:example.com,2000:\n")
  var written, i = 0
  while written < bytes:
    let doc = "--- # document " & $i & "\n" &
        "base: &b {k: " & $i & ", name: \"item " & $i & "\"}\n" &
        "item:\n  <<: *b\n  tags: [a, b, c]  # tags\n" &
        "  text: |\n    line one of " & $i & "\n    line two\n"
    f.write(doc)
    written += doc.len
    inc i

proc genHugeDoc*(path: string, bytes: int) =
  ## One document: a sequence of many mappings, with comments.
  let f = open(path, fmWrite)
  defer: f.close()
  f.write("# one huge document\nitems:\n")
  var written, i = 0
  while written < bytes:
    let item = "  - k: " & $i & "  # key " & $i & "\n    name: item " & $i &
        "\n    tags: [x, y]\n"
    f.write(item)
    written += item.len
    inc i

proc genSmall*(path: string) =
  ## A tiny input, for the baseline of a command.
  writeFile(path, "--- # small\nbase: &b {k: 1, name: \"item\"}\n" &
      "item:\n  <<: *b\n  tags: [a]\n")
