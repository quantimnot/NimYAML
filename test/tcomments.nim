#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[algorithm, os, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import ../yaml/[data, parser, presenter, stream]

proc collected(input: string): seq[Comment] =
  let s = initYamlParser(keepComments = true).parse(input)
  for e in s: discard
  s.comments

proc fed(input: string, chunkSize: int): seq[Comment] =
  let fp = newYamlFeedParser(initYamlParser(keepComments = true))
  var pos = 0
  while true:
    for e in fp.events: discard
    if fp.finished: break
    if pos >= input.len: fp.finish()
    else:
      let last = min(pos + chunkSize, input.len) - 1
      fp.feed(input.toOpenArray(pos, last))
      pos = last + 1
  fp.comments

proc events(input: string): seq[Event] =
  for e in initYamlParser().parse(input):
    var e = e
    # the parser gives block scalars the tag ?, other non-plain scalars !
    if e.kind == yamlScalar and e.scalarProperties.tag == yTagExclamationMark:
      e.scalarProperties.tag = yTagQuestionMark
    result.add(e)

proc contents(comments: seq[Comment]): seq[string] =
  for c in comments: result.add(c.content.strip(leading = false))

proc suiteInputs(): seq[string] =
  ## the valid inputs of the yaml-test-suite
  let root = currentSourcePath.parentDir / "yaml-test-suite"
  for path in walkDirRec(root):
    if path.extractFilename == "in.yaml" and "/.git/" notin path and
        not fileExists(path.parentDir / "error"):
      result.add(path)
  result.sort()

proc keeping(indentation = ciNode): PresentationOptions =
  PresentationOptions(comments: CommentOptions(keep: true,
      indentation: indentation))

proc formatted(input: string, options = keeping()): string =
  result = transform(input, options)
  # formatting is stable
  check transform(result, options) == result

suite "Comments: parser":
  test "collects comments with their position":
    let comments = collected("%YAML 1.2 # dir\n--- # start\n# own\n" &
        "a: 1 #t\nb: |  # header\n  text #no\n  # content\n# own\n" &
        "\"c # no\": '#'\n#\n")
    check comments == @[
      Comment(startPos: Mark(line: 1, column: 11), content: " dir", trailing: true),
      Comment(startPos: Mark(line: 2, column: 5), content: " start", trailing: true),
      Comment(startPos: Mark(line: 3, column: 1), content: " own"),
      Comment(startPos: Mark(line: 4, column: 6), content: "t", trailing: true),
      Comment(startPos: Mark(line: 5, column: 7), content: " header", trailing: true),
      Comment(startPos: Mark(line: 8, column: 1), content: " own"),
      Comment(startPos: Mark(line: 10, column: 1), content: "")]

  test "collects nothing unless asked":
    let s = initYamlParser().parse("a: 1 # c\n")
    for e in s: discard
    check s.comments.len == 0

  test "keeps CR out of the content":
    check collected("a: 1 # c\r\n# d\r\n").contents == @[" c", " d"]

  test "feeding in chunks yields the same comments":
    let inputs = suiteInputs()
    check inputs.len > 300
    for path in inputs:
      let input = readFile(path)
      let expected = collected(input)
      for size in [1, 2, 7, max(input.len, 1)]:
        if fed(input, size) != expected:
          checkpoint(path & " [chunk " & $size & "]")
          fail()

suite "Comments: transform":
  test "dropped unless kept":
    check transform("a: 1 # c\n") == "a: 1\n"

  test "after content, before nodes and at the end of collections":
    check formatted("# head\n\na:   1 # one\nb:\n    # lead\n    - x\n" &
        "    # end of b\n# before c\nc: 2\n") ==
        "# head\n\na: 1  # one\nb:\n  # lead\n  - x\n  # end of b\n" &
        "# before c\nc: 2\n"

  test "a comment line ends the collections it is indented into":
    let input = "a:\n    b:\n        c: 1\n        # in b\n    # in a\n" &
        "# at the root\n"
    check formatted(input) == "a:\n  b:\n    c: 1\n    # in b\n  # in a\n" &
        "# at the root\n"
    # a sequence that is not indented in its mapping ends with the mapping
    check formatted("a:\n- x\n# after a\nb: 1\n") == "a: [x]\n# after a\nb: 1\n"

  test "comment lines keep their order":
    check formatted("a:\n  - k: 1\n    # second level\n  # first level\n" &
        "  #   indented more\n") ==
        "a:\n  - k: 1\n    # second level\n  # first level\n" &
        "  #   indented more\n"

  test "a collection holding a comment is written in block style":
    check formatted("a: [1, # one\n  2]\nb: {k: v}  # flow\n") ==
        "a:\n  - 1  # one\n  - 2\nb: {k: v}  # flow\n"
    check formatted("a: {\n  # inside\n  k: v\n}\n") == "a:\n  # inside\n  k: v\n"

  test "a comment before a value stays between it and its key":
    check formatted("key:    # Comment\n        # lines\n  value\n") ==
        "key:  # Comment\n  # lines\n  value\n"

  test "a comment after a key or empty value":
    check formatted("a: # c\n  b\nc: # d\n") == "a: b  # c\nc: \"\"  # d\n"

  test "block scalars":
    let long = repeat("word ", 10) & "end"
    check formatted("k: | # header\n  " & long & "\n  " & long & "\n# after\n") ==
        "k: |  # header\n  " & long & "\n  " & long & "\n# after\n"
    # a comment line after a block scalar does not become its content
    check formatted("a:\n    b: |\n        " & long & "\n        " & long &
        "\n      # after b\n", keeping(ciSource)) ==
        "a:\n  b: |\n    " & long & "\n    " & long & "\n  # after b\n"

  test "a multi-line flow scalar takes the comment after it":
    check formatted("a: \"x\n  y\" # c\nb: 1\n") == "a: x y  # c\nb: 1\n"

  test "documents and directives":
    check formatted("%YAML 1.2 # version\n--- # start\na: 1\n# end\n...\n" &
        "# between\n--- !!str # tagged\nb\n# last\n") ==
        "# version\n---  # start\na: 1\n# end\n...\n# between\n" &
        "--- !!str  # tagged\nb\n# last\n"

  test "comment indentation":
    let input = "a:\n  b: 1\n#  c: 2\n      # deeper\n  d: 3\n"
    check formatted(input) == "a:\n  b: 1\n  #  c: 2\n  # deeper\n  d: 3\n"
    check formatted(input, keeping(ciSource)) ==
        "a:\n  b: 1\n#  c: 2\n  # deeper\n  d: 3\n"

  test "gap and blank lines":
    var options = keeping()
    options.comments.gap = 1
    options.comments.blankLines = false
    check formatted("# a\n\n\nk: v   # b\n\n# c\n", options) == "# a\nk: v # b\n# c\n"
    # several blank lines become one, and none is written at the end
    check formatted("# a\n\n\nk: v\n\n# c\n\n") == "# a\n\nk: v\n\n# c\n"

  test "comments are dropped where the output has no room":
    var options = keeping()
    options.newlines = nlNone
    check not options.keepsComments
    check transform("a: 1 # c\n", options) == transform("a: 1\n", options)
    options = keeping()
    options.quoting = sqJson
    check not options.keepsComments

  test "yaml-test-suite: data and comments are kept, output is stable":
    let inputs = suiteInputs()
    check inputs.len > 300
    for indentation in CommentIndentation:
      for step in [2, 4]:
        var
          keep = keeping(indentation)
          drop = PresentationOptions()
        keep.indentationStep = step
        drop.indentationStep = step
        for path in inputs:
          let input = readFile(path)
          var plain: string
          try:
            plain = transform(input, drop)
            # presenter problems unrelated to comments are tested elsewhere
            if transform(plain, drop) != plain: continue
          except CatchableError: continue
          let
            name = path.parentDir.relativePath(currentSourcePath.parentDir) &
                " [" & $indentation & ", " & $step & "]"
            once = transform(input, keep)
          if events(once) != events(plain):
            checkpoint(name & ": data changed")
            fail()
          elif collected(once).contents != collected(input).contents:
            checkpoint(name & ": comments changed")
            fail()
          elif transform(once, keep) != once:
            checkpoint(name & ": not stable")
            fail()
