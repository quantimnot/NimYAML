#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests portable output (yaml/portable, tools/yamlexpand and the presenter's
# directive options). The property that matters: a YAML 1.2 processor that
# does not know NimYAML's directives - played by NimYAML with
# directiveExtensions off, which then treats them as reserved directives -
# reads the expanded output as the same events (tags included) that NimYAML
# reads from the original.

import std/[os, streams, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import "../yaml/data", "../yaml/parser", "../yaml/stream", "../yaml/presenter",
    "../yaml/portable", "../tools/yamlexpand"

proc events(source: string, extensions: bool): seq[Event] =
  for e in initYamlParser(directiveExtensions = extensions).parse(source):
    result.add(e)

proc tagsOf(events: seq[Event]): seq[string] =
  for e in events:
    case e.kind
    of yamlScalar: result.add($e.scalarProperties.tag)
    of yamlStartMap: result.add($e.mapProperties.tag)
    of yamlStartSeq: result.add($e.seqProperties.tag)
    else: discard

proc unknownDirectives(source: string): int =
  ## How many directives a standard YAML 1.2 processor would ignore.
  for e in events(source, extensions = false):
    if e.kind == yamlStartDoc and not e.directives.isNil:
      for i in e.directives.issues:
        if i.kind == diUnknownDirective: inc(result)

proc roundTrips(original, expanded: string): bool =
  ## Whether a processor without the extensions reads ``expanded`` as
  ## NimYAML reads ``original``.
  let
    nimyaml = events(original, extensions = true)
    standard = events(expanded, extensions = false)
  result = nimyaml == standard and nimyaml.tagsOf == standard.tagsOf
  var nimVersions, standardVersions: seq[string]
  for e in nimyaml:
    if e.kind == yamlStartDoc: nimVersions.add(e.version)
  for e in standard:
    if e.kind == yamlStartDoc: standardVersions.add(e.version)
  result = result and nimVersions == standardVersions

suite "expandDirectives":
  test "global TAG in every document, %GLOBAL lines removed":
    let source = """# tags for everything
%GLOBAL TAG !e! tag:example.com,2000:
--- !e!a 1
...
--- !e!b 2
...
--- !e!c 3
"""
    let expanded = expandDirectives(source)
    check expanded == """# tags for everything
%TAG !e! tag:example.com,2000:
--- !e!a 1
...
%TAG !e! tag:example.com,2000:
--- !e!b 2
...
%TAG !e! tag:example.com,2000:
--- !e!c 3
"""
    check roundTrips(source, expanded)
    check unknownDirectives(expanded) == 0
    # without expansion, the standard reading differs (it fails)
    expect YamlStreamError:
      discard events(source, extensions = false)

  test "`...` is added before a document that gains directives":
    let source = "%GLOBAL YAML 1.1\n--- a\n--- b\n"
    let expanded = expandDirectives(source)
    check expanded == "%YAML 1.1\n--- a\n...\n%YAML 1.1\n--- b\n"
    check roundTrips(source, expanded)

  test "`---` is added after directives of a bare document":
    let source = "%GLOBAL TAG !e! tag:e:\n--- !e!a 1\n...\n!e!b 2\n"
    let expanded = expandDirectives(source)
    check expanded ==
        "%TAG !e! tag:e:\n--- !e!a 1\n...\n%TAG !e! tag:e:\n---\n!e!b 2\n"
    check roundTrips(source, expanded)

  test "overridden globals are not written":
    let source = """%GLOBAL TAG !e! tag:global:
%GLOBAL YAML 1.1
%TAG !e! tag:first:
--- !e!a 1
...
%TAG !e! tag:second:
%YAML 1.2
--- !e!b 2
...
--- !e!c 3
"""
    let expanded = expandDirectives(source)
    # the first document's own %TAG !e! overrides the global one there
    check expanded == """%YAML 1.1
%TAG !e! tag:first:
--- !e!a 1
...
%TAG !e! tag:second:
%YAML 1.2
--- !e!b 2
...
%TAG !e! tag:global:
%YAML 1.1
--- !e!c 3
"""
    check roundTrips(source, expanded)

  test "global SCHEMA as %SCHEMA, or as modeline":
    let source = """%GLOBAL SCHEMA schemas/service.json
--- {name: a}
...
%SCHEMA schemas/special.json
--- {name: b}
"""
    let directives = expandDirectives(source)
    check directives == """%SCHEMA schemas/service.json
--- {name: a}
...
%SCHEMA schemas/special.json
--- {name: b}
"""
    check roundTrips(source, directives)
    check unknownDirectives(directives) == 2 # %SCHEMA is still NimYAML's
    let modelines = expandDirectives(source, ExpandOptions(schemas: soModeline))
    check modelines == """# yaml-language-server: $schema=schemas/service.json
--- {name: a}
...
# yaml-language-server: $schema=schemas/special.json
--- {name: b}
"""
    check roundTrips(source, modelines)
    check unknownDirectives(modelines) == 0

  test "several schemas stay on one %SCHEMA line, even for modelines":
    proc schemasOf(source: string): seq[seq[string]] =
      for e in events(source, extensions = true):
        if e.kind == yamlStartDoc: result.add(e.directives.schemas)
    let source = "%GLOBAL SCHEMA https://x.example/a https://x.example/b\n" &
        "--- 1\n...\n--- 2\n"
    let expected = "%SCHEMA https://x.example/a https://x.example/b\n" &
        "--- 1\n...\n%SCHEMA https://x.example/a https://x.example/b\n--- 2\n"
    check expandDirectives(source) == expected
    # a modeline names one schema
    check expandDirectives(source, ExpandOptions(schemas: soModeline)) ==
        expected
    check schemasOf(expected) == schemasOf(source)
    const own = "%SCHEMA https://x.example/a https://x.example/b\n--- 1\n"
    check expandDirectives(own, ExpandOptions(schemas: soModeline)) == own

  test "comments, styles and line breaks are kept":
    let source = "%GLOBAL TAG !e! tag:e: # the e handle\r\n" &
        "--- # first\r\n- !e!a  'quoted'   # comment\r\n...\r\n" &
        "--- |\r\n  literal\r\n"
    let expanded = expandDirectives(source)
    check expanded == "%TAG !e! tag:e:\r\n" &
        "--- # first\r\n- !e!a  'quoted'   # comment\r\n...\r\n" &
        "%TAG !e! tag:e:\r\n--- |\r\n  literal\r\n"
    check roundTrips(source, expanded)

  test "input without globals is unchanged":
    for source in ["a: 1\n", "%YAML 1.2\n--- a\n...\n%TAG !e! x:\n--- !e!b c\n",
        "--- a\n--- b\n"]:
      check expandDirectives(source) == source

  test "invalid YAML raises":
    expect YamlParserError:
      discard expandDirectives("a: [\n")

suite "presenter directive options":
  test "ovDocument and schemaDirective":
    let source = "%GLOBAL YAML 1.1\n%GLOBAL SCHEMA https://x.example/s\n" &
        "%GLOBAL TAG !e! tag:e:\n--- !e!a 1\n...\n--- !e!b 2\n"
    var output = newStringStream()
    present(initYamlParser().parse(source), output, PresentationOptions(
        outputVersion: ovDocument, schemaDirective: sdModeline,
        newlines: nlLF))
    let text = output.data
    check text.count("%YAML 1.1") == 2
    check text.count("# yaml-language-server: $schema=https://x.example/s") == 2
    check text.count("%TAG !e! tag:e:") == 2
    check "%GLOBAL" notin text
    check roundTrips(source, text)
    output = newStringStream()
    present(initYamlParser().parse(source), output, PresentationOptions(
        schemaDirective: sdDirective, newlines: nlLF))
    check output.data.count("%SCHEMA https://x.example/s") == 2

  test "several schemas are written as one %SCHEMA, also for sdModeline":
    let source = "%GLOBAL SCHEMA https://x.example/s https://x.example/t\n" &
        "--- 1\n...\n--- 2\n"
    for style in [sdDirective, sdModeline]:
      var output = newStringStream()
      present(initYamlParser().parse(source), output, PresentationOptions(
          schemaDirective: style, newlines: nlLF))
      check output.data.count(
          "%SCHEMA https://x.example/s https://x.example/t\n") == 2
      check "yaml-language-server" notin output.data

suite "yamlexpand":
  let dir = getTempDir() / "nimyaml-tportable"
  createDir(dir)

  proc expand(args: seq[string], stdinText = ""): tuple[code: int, output: string] =
    let
      inPath = dir / "stdin"
      outPath = dir / "stdout"
    writeFile(inPath, stdinText)
    var input = open(inPath)
    var output = open(outPath, fmWrite)
    result.code = run(args, input, output)
    input.close()
    output.close()
    result.output = readFile(outPath)

  test "file and stdin":
    writeFile(dir / "a.yaml", "%GLOBAL TAG !e! tag:e:\n--- !e!a 1\n--- !e!b 2\n")
    check expand(@[dir / "a.yaml"]) == (0,
        "%TAG !e! tag:e:\n--- !e!a 1\n...\n%TAG !e! tag:e:\n--- !e!b 2\n")
    check expand(@[], "%GLOBAL YAML 1.2\n--- a\n").output ==
        "%YAML 1.2\n--- a\n"

  test "--modeline":
    check expand(@["--modeline"], "%SCHEMA s.json\n--- a\n").output ==
        "# yaml-language-server: $schema=s.json\n--- a\n"

  test "errors":
    check expand(@[], "a: [\n").code == 1
    check expand(@["--bogus"]).code == 2
    check expand(@[dir / "missing.yaml"]).code == 2

  removeDir(dir)
