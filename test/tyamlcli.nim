#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, osproc, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml/[toolconfig, dumping, presenter]

let
  root = currentSourcePath.parentDir.parentDir
  tmp = getTempDir() / ("yamlcli-test-" & $getCurrentProcessId())
  bin = tmp / "yaml"
  dir = tmp / "files"

createDir(dir)
let (compileOutput, compileCode) = execCmdEx("nim c --hints:off -o:" &
    quoteShell(bin) & " " & quoteShell(root / "tools" / "yamlcli.nim"))
doAssert compileCode == 0, compileOutput

proc cli(args: seq[string], input = "", workingDir = dir):
    tuple[output: string, exitCode: int] =
  var cmd = quoteShell(bin)
  for arg in args: cmd.add(" " & quoteShell(arg))
  cmd.add(" 2>&1")
  execCmdEx(cmd, input = input, workingDir = workingDir)

proc cli(args: varargs[string]): tuple[output: string, exitCode: int] =
  cli(@args)

writeFile(dir / "a.yaml", "a: 1\nb: [x, 2]\n---\nc: {d: true, e: ~}\n")
writeFile(dir / "b.jsonc", "{\"a\": 1, // c\n \"b\": [1, 2,],}\n")
writeFile(dir / "c.jsonl", "{\"a\": 1}\n\n{\"a\": [2]}\n")

suite "toolconfig":
  test "defaults":
    let c = parseToolConfig("# nothing\n")
    check c.validateSchemas
    check c.lint.rules.len == 0
    check c.format.dumper.presentation.indentationStep == 2

  test "all sections":
    let c = parseToolConfig("lint:\n  rules:\n    truthy: {level: off}\n" &
        "validate: {schema: false}\n" &
        "format: {style: json, indentation: 4, max-line-length: 0}\n")
    check c.lint.rules["truthy"].level == some(levelOff)
    check not c.validateSchemas
    let options = c.format.dumper.presentation
    check options.indentationStep == 4
    check options.maxLineLength.isNone
    check options.quoting == jsonDumper().presentation.quoting

  test "invalid configs":
    expect ToolConfigError: discard parseToolConfig("nope: 1\n")
    expect ToolConfigError:
      discard parseToolConfig("lint: {rules: {nope: {}}}\n")
    expect ToolConfigError:
      discard parseToolConfig("format: {indentation: 0}\n")
    expect ToolConfigError:
      discard parseToolConfig("format: {style: fancy}\n")

  test "found by walking up; .yaml before the legacy file":
    let base = tmp / "walk"
    createDir(base / "x" / "y")
    defer: removeDir(base)
    check findToolConfig(base / "x" / "y") notin [base / ".yaml",
        base / "x" / ".yaml"]
    writeFile(base / ".nimyaml-lint.yaml", "rules: {truthy: {level: off}}\n")
    check findToolConfig(base / "x" / "y") == base / ".nimyaml-lint.yaml"
    check toolConfigFor(base / "x" / "y" / "f.yaml").lint.rules["truthy"].level ==
        some(levelOff)
    writeFile(base / ".yaml.yaml", "")
    check findToolConfig(base / "x" / "y") == base / ".yaml.yaml"
    writeFile(base / "x" / ".yaml", "")
    check findToolConfig(base / "x" / "y") == base / "x" / ".yaml"
    writeFile(base / "x" / ".yaml.yaml", "")
    expect ToolConfigError: discard findToolConfig(base / "x" / "y")

suite "yaml":
  test "help":
    check cli().exitCode == 2
    let overview = cli("help")
    check overview.exitCode == 0
    check "convert" in overview.output and "lsp" in overview.output
    check cli("--help") == overview
    check cli("help", "format").output.startsWith("usage: yaml format")
    check cli("format", "--help").output.startsWith("usage: yaml format")
    check cli("help", "config").output.startsWith("Configuration:")
    check cli("help", "nope").exitCode == 2
    let unknown = cli("frob")
    check unknown.exitCode == 2
    check unknown.output.startsWith("unknown command: frob")

  test "convert to json: one value per document, core schema types":
    check cli("convert", "json", "a.yaml") == ("{\n  \"a\": 1,\n" &
        "  \"b\": [\n    \"x\",\n    2\n  ]\n}\n" &
        "{\n  \"c\": {\n    \"d\": true,\n    \"e\": null\n  }\n}\n", 0)

  test "as / to jsonl, from several formats":
    check cli("as", "jsonl", "a.yaml", "b.jsonc", "c.jsonl") == (
        "{\"a\": 1, \"b\": [\"x\", 2]}\n" &
        "{\"c\": {\"d\": true, \"e\": null}}\n" &
        "{\"a\": 1, \"b\": [1, 2]}\n" &
        "{\"a\": 1}\n" &
        "{\"a\": [2]}\n", 0)
    check cli("to", "jsonl", "a.yaml") == cli("as", "jsonl", "a.yaml")

  test "to yaml, from standard input and with --from":
    check cli(@["to", "yaml"], input = "{\"a\": [1, 2]}") ==
        ("a: [1, 2]\n", 0)
    check cli(@["to", "json", "--from:jsonl"],
        input = "{\"a\": 1}\n{\"b\": 2}\n").output ==
        "{\n  \"a\": 1\n}\n{\n  \"b\": 2\n}\n"

  test "cbor round trip":
    # through a file, since execCmdEx reads the output line by line
    check execCmd(quoteShell(bin) & " to cbor " & quoteShell(dir / "a.yaml") &
        " > " & quoteShell(dir / "a.cbor")) == 0
    check cli("to", "json", "a.cbor") == cli("to", "json", "a.yaml")

  test "conversion errors":
    let r = cli(@["to", "json"], input = "a: [\n")
    check r.exitCode == 1
    check r.output.startsWith("<stdin>:2:1: ")
    check cli("to", "xml", "a.yaml").exitCode == 2
    check cli("to").exitCode == 2
    check cli("to", "json", "missing.yaml").exitCode == 2
    check cli(@["to", "json"], input = "a: .inf\n").exitCode == 1

  test "query":
    check cli("$..a", "a.yaml", "c.jsonl") == ("1\n...\n1\n...\n[2]\n", 0)
    check cli("query", "--paths", "$.b[*]", "a.yaml") ==
        ("$['b'][0]\n$['b'][1]\n", 0)
    check cli("query", "--to:jsonl", "$.c", "a.yaml") ==
        ("{\"d\": true, \"e\": null}\n", 0)
    check cli(@["$.a"], input = "a: x\n") == ("x\n", 0)
    let invalid = cli("$[", "a.yaml")
    check invalid.exitCode == 2
    check invalid.output.startsWith("invalid JSONPath: ")
    check cli("query").exitCode == 2

  test "format":
    writeFile(dir / "f.yaml", "a:   1\nb:\n    - x\n    - {y: 2}\n")
    check cli("format", "f.yaml") == ("a: 1\nb:\n  - x\n  - y: 2\n", 0)
    check cli(@["format"], input = "[1,   2]\n") == ("[1, 2]\n", 0)
    check cli("format", "--style:json", "--indent:4", "f.yaml").output ==
        "{\n    \"a\": 1,\n    \"b\": [\n        \"x\",\n        {\n" &
        "            \"y\": 2\n        }\n    ]\n}\n"
    check cli("format", "--style:fancy", "f.yaml").exitCode == 2
    check cli("format", "--indent:0", "f.yaml").exitCode == 2
    check cli("format", "f.yaml", "a.yaml").exitCode == 2
    check cli("format", "--write").exitCode == 2

  test "format refuses to drop comments":
    writeFile(dir / "comment.yaml", "a:   1 # why\n")
    let refused = cli("format", "comment.yaml")
    check refused.exitCode == 1
    check "has comments" in refused.output
    check cli("format", "--drop-comments", "comment.yaml") == ("a: 1\n", 0)
    # a # in a scalar is no comment
    check cli(@["format"], input = "a:   'b # c'\n") == ("a: \"b # c\"\n", 0)

  test "format --check and --write":
    writeFile(dir / "w.yaml", "a:   1\n")
    writeFile(dir / "ok.yaml", "a: 1\n")
    check cli("format", "--check", "w.yaml", "ok.yaml") == ("w.yaml\n", 1)
    check cli("format", "--write", "w.yaml", "ok.yaml") == ("", 0)
    check readFile(dir / "w.yaml") == "a: 1\n"
    check cli("format", "--check", "w.yaml", "ok.yaml") == ("", 0)

  test "format and lint read the config":
    let project = tmp / "project"
    createDir(project)
    defer: removeDir(project)
    writeFile(project / ".yaml", "format: {indentation: 4}\n" &
        "lint: {rules: {truthy: {level: error}}}\n")
    writeFile(project / "t.yaml", "k: yes\nm:\n  p: 1\n  q: 2\n")
    check cli(@["format", "t.yaml"], workingDir = project) ==
        ("k: yes\nm:\n    p: 1\n    q: 2\n", 0)
    check cli(@["lint", "t.yaml"], workingDir = project) == ("t.yaml:1:4: " &
        "error: \"yes\" is a boolean in YAML 1.1; quote it or use " &
        "true/false [truthy]\n", 1)
    # standard input gets the config of the current directory
    check cli(@["lint"], input = "k: yes\n", workingDir = project).output ==
        "<stdin>:1:4: error: \"yes\" is a boolean in YAML 1.1; quote it " &
        "or use true/false [truthy]\n"
    writeFile(project / ".yaml.yaml", "")
    let both = cli(@["lint", "t.yaml"], workingDir = project)
    check both.exitCode == 2
    check "both .yaml and .yaml.yaml exist" in both.output

  test "lint --config takes a .yaml config":
    writeFile(tmp / "strict.yaml", "lint: {rules: {trailing-spaces: " &
        "{level: error}}}\n")
    check cli(@["lint", "--config:" & tmp / "strict.yaml"],
        input = "a: 1 \n") ==
        ("<stdin>:1:5: error: trailing whitespace [trailing-spaces]\n", 1)
    writeFile(tmp / "invalid.yaml", "rules: {}\n")
    check cli("lint", "--config:" & tmp / "invalid.yaml", "a.yaml").exitCode == 2

  test "validate: only spec violations":
    check cli(@["validate"], input = "k: yes \n") == ("", 0)
    check cli(@["validate"], input = "a: 1\na: 2\n") == ("<stdin>:2:1: " &
        "error: duplicate mapping key \"a\" [duplicate-key]\n", 1)
    check cli(@["validate"], input = "a: [\n").exitCode == 1

  test "validate.schema in the config":
    let project = tmp / "schema"
    createDir(project)
    defer: removeDir(project)
    writeFile(project / "port.schema.yaml", "{type: object, properties: " &
        "{port: {type: integer}}}\n")
    writeFile(project / "service.yaml",
        "%SCHEMA port.schema.yaml\n---\nport: http\n")
    let invalid = cli(@["validate", "service.yaml"], workingDir = project)
    check invalid.exitCode == 1
    check "[schema-validation]" in invalid.output
    writeFile(project / ".yaml", "validate: {schema: false}\n")
    check cli(@["validate", "service.yaml"], workingDir = project) == ("", 0)

  test "expand":
    check cli(@["expand"], input = "%GLOBAL YAML 1.2\n--- a\n--- b\n") ==
        ("%YAML 1.2\n--- a\n...\n%YAML 1.2\n--- b\n", 0)

  test "lsp":
    let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," &
        "\"params\":{}}"
    let exitMsg = "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"
    let r = cli(@["lsp", "--stdio"], input = "Content-Length: " & $body.len &
        "\r\n\r\n" & body & "Content-Length: " & $exitMsg.len & "\r\n\r\n" &
        exitMsg)
    check r.output.startsWith("Content-Length: ")
    check "\"serverInfo\":{\"name\":\"yamllsp\"}" in r.output
    check cli("lsp", "--socket=8080").exitCode == 2

removeDir(tmp)
