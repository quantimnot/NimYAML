#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, osproc, strutils, times, unittest]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../yaml/[toolconfig, dumping, presenter, memory, source]

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
      discard parseToolConfig("index: {recent-limit: 0}\n")
    expect ToolConfigError:
      discard parseToolConfig("index: {mode: sometimes}\n")
    expect ToolConfigError:
      discard parseToolConfig("format: {style: fancy}\n")
    expect ToolConfigError:
      discard parseToolConfig("format: {comment-gap: 0}\n")
    expect ToolConfigError:
      discard parseToolConfig("format: {comments: maybe}\n")

  test "comment keys":
    check parseToolConfig("").format.dumper.presentation.comments ==
        CommentOptions(keep: true)
    let options = parseToolConfig("format: {comments: drop, " &
        "comment-indentation: source, comment-gap: 1, " &
        "comment-blank-lines: drop}\n").format.dumper.presentation.comments
    check options == CommentOptions(keep: false, indentation: ciSource, gap: 1,
        blankLines: false)

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

  test "resolved, and $ as a config file":
    let defaults = defaultToolConfig().resolved
    check defaults.lint.rules.len == builtinRuleIds().len
    check defaults.lint.rules["line-length"] ==
        RuleConfig(level: some(levelWarning), max: some(defaultMaxLineLength))
    check defaults.validate.schema == some(true)
    check defaults.validate.remoteSchemas == some(true)
    check defaults.validate.schemaCache == some(sclUser)
    check defaultToolConfig().remoteSchemas
    check defaults.format.style == some(fsDefault)
    check defaults.format.indentation == some(2)
    check defaults.format.maxLineLength == some(80)
    check defaults.index.mode == some(imOff)
    check defaults.index.format == some(ifCbor)
    check defaults.index.location == some(ilUser)
    check defaults.index.recentLimit == some(256)
    check parseToolConfig($defaultToolConfig()) == defaults
    let c = parseToolConfig("lint: {rules: {truthy: {level: off}, " &
        "line-length: {max: 90}}}\n" &
        "validate: {schema: false, remote-schemas: false, " &
        "schema-cache: project}\n" &
        "format: {style: json, max-line-length: 0, comment-gap: 3}\n" &
        "index: {mode: recent, format: yaml, location: project, " &
        "recent-limit: 9}\n")
    let r = c.resolved
    check r.lint.rules["truthy"].level == some(levelOff)
    check r.lint.rules["line-length"] ==
        RuleConfig(level: some(levelWarning), max: some(90))
    check r.validate.schema == some(false)
    check r.validate.remoteSchemas == some(false)
    check not c.remoteSchemas
    check c.schemaCache == sclProject
    check r.format.style == some(fsJson)
    check r.format.maxLineLength == some(0)
    check r.format.commentGap == some(3)
    check c.indexSettings("dir") == IndexSettings(mode: imRecent,
        format: ifYaml, location: ilProject, recentLimit: 9, configDir: "dir")
    check r.format.dumper.presentation == c.format.dumper.presentation
    check parseToolConfig($c) == r
    check "  max-line-length: 0  # 0 for no limit\n" in $c

suite "yaml":
  test "help":
    check cli().exitCode == 2
    let overview = cli("help")
    check overview.exitCode == 0
    check "convert" in overview.output and "lsp" in overview.output
    check cli("--help") == overview
    check cli("help", "format").output.startsWith("usage: yaml format")
    check cli("format", "--help").output.startsWith("usage: yaml format")
    let configHelp = cli("help", "config").output
    check configHelp.startsWith("usage: yaml config")
    check "Configuration:" in configHelp
    check cli("config", "--help").output == configHelp
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

  test "format keeps comments":
    writeFile(dir / "comment.yaml",
        "# head\n\na:   1 # why\nb:\n    # lead\n    - x\n")
    check cli("format", "comment.yaml") ==
        ("# head\n\na: 1  # why\nb:\n  # lead\n  - x\n", 0)
    check cli("format", "--comment-gap:1", "--comment-blank-lines:drop",
        "--comment-indentation:source", "comment.yaml") ==
        ("# head\na: 1 # why\nb:\n  # lead\n  - x\n", 0)
    # without its comment, the sequence fits in a line
    check cli("format", "--drop-comments", "comment.yaml") ==
        ("a: 1\nb: [x]\n", 0)
    check cli("format", "--comment-gap:0", "comment.yaml").exitCode == 2
    check cli("format", "--comment-indentation:far", "comment.yaml").exitCode == 2
    # a # in a scalar is no comment
    check cli(@["format", "--style:json"], input = "a:   'b # c'\n") ==
        ("{\n  \"a\": \"b # c\"\n}\n", 0)

  test "format refuses to drop comments where the style has no room":
    let refused = cli("format", "--style:json", "comment.yaml")
    check refused.exitCode == 1
    check "the json style cannot keep" in refused.output
    check cli("format", "--style:json", "--drop-comments", "comment.yaml") ==
        ("{\n  \"a\": 1,\n  \"b\": [\n    \"x\"\n  ]\n}\n", 0)

  test "format --check and --write":
    writeFile(dir / "w.yaml", "a:   1\n")
    writeFile(dir / "ok.yaml", "a: 1\n")
    check cli("format", "--check", "w.yaml", "ok.yaml") == ("w.yaml\n", 1)
    check cli("format", "--write", "w.yaml", "ok.yaml") == ("", 0)
    check readFile(dir / "w.yaml") == "a: 1\n"
    check cli("format", "--check", "w.yaml", "ok.yaml") == ("", 0)

  test "format -i and --in-place":
    writeFile(dir / "i.yaml", "a:   1\n")
    check cli("format", "-i", "i.yaml") == ("", 0)
    check readFile(dir / "i.yaml") == "a: 1\n"
    writeFile(dir / "i.yaml", "a:   [1,   2]\n")
    check cli("format", "--in-place", "i.yaml", "ok.yaml") == ("", 0)
    check readFile(dir / "i.yaml") == "a: [1, 2]\n"
    check cli("format", "-i").exitCode == 2
    check cli("format", "-i", "--check", "i.yaml").exitCode == 2

  test "assignment":
    writeFile(dir / "s.yaml",
        "# s\na: 1  # one\nb: [x, {c: 2}]\n---\nb: []\n")
    # only the selected nodes change
    check cli("$.a = 3", "s.yaml") ==
        ("# s\na: 3  # one\nb: [x, {c: 2}]\n---\nb: []\n", 0)
    check cli(@["$.b[1].c={d: [1, 2]}"], input = "b: [x, {c: 2}]\n") ==
        ("b: [x, {c: {d: [1, 2]}}]\n", 0)
    # what follows the content of a node stays, like a comment at its end
    check cli(@["$.b = [p, {q: 1}]"], input = "b:\n  - x  # x\nc: 1\n") ==
        ("b:\n  - p\n  - q: 1  # x\nc: 1\n", 0)
    check cli(@["$..c = [1]"], input = "- c: 1\n- c: 2\n") ==
        ("- c: [1]\n- c: [1]\n", 0)
    # = in filters and strings does not assign
    check cli(@["$[?@.k == 'a=b'].v = 0"],
        input = "- {k: a=b, v: 1}\n- {k: c, v: 2}\n") ==
        ("- {k: a=b, v: 0}\n- {k: c, v: 2}\n", 0)
    # with --to or several inputs, as by convert
    check cli(@["query", "--to:json", "$ = {a: 1}"], input = "x\n") ==
        ("{\n  \"a\": 1\n}\n", 0)
    check cli("$.b = 1", "s.yaml", "a.yaml").output.startsWith("a: 1\nb: 1\n")
    # an edit that the text cannot take
    let broken = cli(@["$.a = 2"], input = "a: {k: &x 1}\nb: *x\n")
    check broken.exitCode == 1
    check broken.output.startsWith("<stdin>: cannot assign in place: ")
    check cli("$.a = [", "s.yaml").exitCode == 2
    check cli("query", "--paths", "$.a = 3", "s.yaml").exitCode == 2

  test "assignment -i and --in-place":
    writeFile(dir / "t.yaml", "a: 1\nb: 2\n")
    writeFile(dir / "t.json", "{\"a\": 1}\n")
    writeFile(dir / "u.yaml", "b:   2\n")
    check cli("$.a = 5", "-i", "t.yaml", "t.json", "u.yaml") == ("", 0)
    check readFile(dir / "t.yaml") == "a: 5\nb: 2\n"
    check readFile(dir / "t.json") == "{\"a\": 5}\n"
    # a file without a selected node is left alone
    check readFile(dir / "u.yaml") == "b:   2\n"
    check cli("query", "--in-place", "$.b = x", "t.yaml") == ("", 0)
    check readFile(dir / "t.yaml") == "a: 5\nb: x\n"
    writeFile(dir / "t.jsonc", "{\n  // c\n  \"a\": [1],\n}\n")
    writeFile(dir / "t.jsonl", "{\"a\": 1}\n\n{\"b\": 2}\n{\"a\": 3}\n")
    check cli("$.a = {x: y}", "-i", "t.jsonc", "t.jsonl") == ("", 0)
    check readFile(dir / "t.jsonc") ==
        "{\n  // c\n  \"a\": {\"x\": \"y\"},\n}\n"
    check readFile(dir / "t.jsonl") ==
        "{\"a\": {\"x\": \"y\"}}\n\n{\"b\": 2}\n{\"a\": {\"x\": \"y\"}}\n"
    check execCmd(quoteShell(bin) & " as cbor " & quoteShell(dir / "t.yaml") &
        " > " & quoteShell(dir / "t.cbor")) == 0
    check cli("$.a = 6", "-i", "t.cbor") == ("", 0)
    check cli("as", "yaml", "t.cbor") == ("a: 6\nb: x\n", 0)
    check cli(@["$.a = 1", "-i"], input = "a: 2\n").exitCode == 2
    check cli("$.a", "-i", "t.yaml").exitCode == 2

  test "format and lint read the config":
    let project = tmp / "project"
    createDir(project)
    defer: removeDir(project)
    writeFile(project / ".yaml", "format: {indentation: 4}\n" &
        "lint: {rules: {truthy: {level: error}}}\n")
    writeFile(project / "t.yaml", "k: yes\nm:\n  p: 1\n  q: 2\n")
    check cli(@["format", "t.yaml"], workingDir = project) ==
        ("k: yes\nm:\n    p: 1\n    q: 2\n", 0)
    writeFile(project / "c.yaml", "k: 1 # c\n")
    writeFile(project / "drop.yaml", "format: {comments: drop}\n")
    check cli(@["format", "--config:drop.yaml", "c.yaml"],
        workingDir = project) == ("k: 1\n", 0)
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

  test "patch with a JSON Patch":
    writeFile(dir / "doc.yaml", "name: app\nport: \"80\"\ntags: [a, b]\n")
    writeFile(dir / "ops.yaml",
        "- {op: add, path: /tags/-, value: c}\n" &
        "- {op: replace, path: /name, value: svc}\n")
    check cli("patch", "ops.yaml", "doc.yaml", "--to:json").output ==
        "{\n  \"name\": \"svc\",\n  \"port\": \"80\",\n  \"tags\": [\n" &
        "    \"a\",\n    \"b\",\n    \"c\"\n  ]\n}\n"
    # quoted scalars that look like numbers stay strings in YAML too
    check "port: \"80\"" in cli("patch", "ops.yaml", "doc.yaml").output

  test "patch with a JSON Merge Patch (keeping member order)":
    writeFile(dir / "merge.json", "{\"port\": null, \"debug\": true}")
    check cli(@["patch", "merge.json", "--to:jsonl"],
        input = "{name: app, port: 80}") ==
        ("{\"name\": \"app\", \"debug\": true}\n", 0)
    # --merge reads a sequence as a merge patch, which replaces the document
    check cli(@["patch", "--merge", "ops.yaml", "--to:jsonl"], input = "a: 1"
        ).output.startsWith("[{")

  test "patch errors name the patch file":
    writeFile(dir / "bad.yaml", "[{op: frob, path: /a}]\n")
    let bad = cli(@["patch", "bad.yaml"], input = "")
    check bad.exitCode == 1
    check bad.output.startsWith("bad.yaml: operation 0: ")
    check cli(@["patch", "missing.yaml"], input = "").exitCode == 2

  test "patch -i is all or nothing":
    writeFile(dir / "p1.yaml", "a: 1\n")
    writeFile(dir / "p2.yaml", "b: 1\n")
    writeFile(dir / "test.yaml", "[{op: test, path: /a, value: 1}, " &
        "{op: add, path: /c, value: 2}]")
    let failed = cli("patch", "-i", "test.yaml", "p1.yaml", "p2.yaml")
    check failed.exitCode == 1
    check failed.output.startsWith("p2.yaml: operation 0: ")
    check readFile(dir / "p1.yaml") == "a: 1\n"
    check cli("patch", "-i", "test.yaml", "p1.yaml") == ("", 0)
    check readFile(dir / "p1.yaml") == "a: 1\nc: 2\n"
    check cli("patch", "-i", "test.yaml").exitCode == 2

  test "merge":
    check cli(@["merge"], input = "base: &b {x: 1, y: 2}\n" &
        "d: {<<: *b, y: 3}\n").output == "base:\n  x: 1\n  y: 2\nd:\n  x: 1\n  y: 3\n"
    let invalid = cli(@["merge"], input = "{<<: 1}")
    check invalid.exitCode == 1
    check invalid.output.startsWith("<stdin>:1:2: ")

  test "canonical":
    check cli(@["canonical"], input = "{b: 1.0e+3, a: [true, ~, \"x\"]}\n" &
        "--- 1e21\n") == ("{\"a\":[true,null,\"x\"],\"b\":1000}\n1e+21\n", 0)
    check cli(@["jcs"], input = "{1: x}").exitCode == 1

  test "diff":
    writeFile(dir / "old.yaml", "server:\n  host: a  # the host\n" &
        "  port: 80\ntags: [x, y]\ndebug: true\n")
    writeFile(dir / "new.json", "{\"tags\": [\"x\", \"z\", \"y\"], " &
        "\"server\": {\"port\": 8080, \"host\": \"a\"}, \"note\": \"a\\nb\"}")
    check cli("diff", "old.yaml", "new.json") == ("~ /server/port: 80 -> 8080\n" &
        "+ /tags/1: z\n- /debug: true\n+ /note: \"a\\nb\"\n", 1)
    check cli("diff", "--paths:path", "old.yaml", "new.json").output.startsWith(
        "~ $.server.port: 80 -> 8080\n")
    check cli("diff", "--color:always", "old.yaml", "new.json").output.startsWith(
        "\e[33m~ /server/port: 80 -> 8080\e[0m\n")
    # formatting, comments and key order make no difference
    check cli(@["diff", "old.yaml", "-"], input = "{debug: true, " &
        "tags: [x, 'y'], server: {port: 80, host: a}}") == ("", 0)
    check cli("diff", "-q", "old.yaml", "new.json") == ("", 1)
    check cli("diff", "old.yaml").exitCode == 2
    check cli(@["diff", "old.yaml", "-"], input = "a: [").exitCode == 2

  test "diff of several documents":
    writeFile(dir / "docs.yaml", "a: 1\n--- [1, 2]\n")
    check cli(@["diff", "docs.yaml", "-"], input = "a: 2\n--- [1, 2]\n--- x\n") ==
        ("~ #1 /a: 1 -> 2\n+ #3: x\n", 1)

  test "diff --patch and --merge-patch":
    let patch = cli("diff", "--patch", "old.yaml", "new.json", "--to:yaml")
    check patch.exitCode == 1
    check patch.output.startsWith("- op: add\n  path: /note\n")
    writeFile(dir / "made.yaml", patch.output)
    let patched = cli("patch", "made.yaml", "old.yaml", "--to:json")
    writeFile(dir / "patched.json", patched.output)
    check cli("diff", "patched.json", "new.json") == ("", 0)
    check cli("diff", "--merge-patch", "old.yaml", "new.json", "--to:jsonl") ==
        ("{\"debug\": null, \"note\": \"a\\nb\", \"server\": {\"port\": 8080}, " &
         "\"tags\": [\"x\", \"z\", \"y\"]}\n", 1)
    check cli("diff", "--patch", "docs.yaml", "old.yaml").exitCode == 2
    check cli("diff", "--to:json", "old.yaml", "new.json").exitCode == 2

  test "diff as a git diff driver":
    # PATH OLD-FILE OLD-HEX OLD-MODE NEW-FILE NEW-HEX NEW-MODE; git's
    # temporary files need not have the extension of PATH
    copyFile(dir / "new.json", dir / "tmp-new")
    check cli("diff", "conf.json", "old.yaml", "1111", "100644", "tmp-new",
        "2222", "100644") == ("semantic diff conf.json\n" &
        "~ /server/port: 80 -> 8080\n+ /tags/1: z\n- /debug: true\n" &
        "+ /note: \"a\\nb\"\n", 0)

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

suite "yaml index":
  let indexed = tmp / "indexed"
  createDir(indexed)
  writeFile(indexed / ".yaml", "index: {mode: all, location: beside}\n")
  let data = indexed / "data.yaml"
  let index = indexed / ".data.yaml.index.cbor"

  # File times are kept with less precision than an index has on some
  # systems, so files are given whole seconds to be put back exactly.
  let pinned = fromUnix(1_700_000_000)

  test "query builds the index, then reads nodes through it":
    writeFile(data, "a:\n  b: [1, {c: deep}]\n  s: &s hello\nt: *s\n")
    setLastModificationTime(data, pinned)
    check cli(@["$.a.b[1].c", "data.yaml"], workingDir = indexed) ==
        ("deep\n", 0)
    check fileExists(index)
    # a query that is not singular parses
    check cli(@["$.a.b[*]", "data.yaml"], workingDir = indexed) ==
        ("1\n...\nc: deep\n", 0)
    # bytes outside the node change, so that the file does not parse, but
    # size and time stay: only a read through the index still finds nodes
    writeFile(data, "a:\n  b: [1; {c: deep}]\n  s: &s hello\nt: *s\n")
    setLastModificationTime(data, pinned)
    check cli(@["$.a.b[1].c", "data.yaml"], workingDir = indexed) ==
        ("deep\n", 0)
    check cli(@["$.t", "data.yaml"], workingDir = indexed) == ("hello\n", 0)
    check cli(@["query", "--paths", "$['t']", "data.yaml"],
        workingDir = indexed) == ("$['t']\n", 0)
    check cli(@["$.a.b[*]", "data.yaml"], workingDir = indexed).exitCode == 1

  test "an edit by anything else makes the index stale":
    writeFile(data, "a: 1\n")
    setLastModificationTime(data, pinned)
    check cli(@["$.a", "data.yaml"], workingDir = indexed) == ("1\n", 0)
    writeFile(data, "a: 2\n") # same size and time: the hash tells
    setLastModificationTime(data, pinned + initDuration(seconds = 1))
    check cli(@["$.a", "data.yaml"], workingDir = indexed) == ("2\n", 0)

  test "writing in place refreshes the index":
    writeFile(data, "a: 1\nb: 2\n")
    check cli(@["$.a = 333", "-i", "data.yaml"], workingDir = indexed) ==
        ("", 0)
    # the index written with the file matches its content, so only its time
    # is updated by the next lookup
    setLastModificationTime(data, pinned)
    check cli(@["$.a", "data.yaml"], workingDir = indexed) == ("333\n", 0)
    writeFile(data, "a: 333\nb: [\n")
    setLastModificationTime(data, pinned)
    check cli(@["$.a", "data.yaml"], workingDir = indexed) == ("333\n", 0)

  test "index, --print and --drop":
    writeFile(data, "a: [1, 2]\n")
    check cli(@["index", "data.yaml"], workingDir = indexed) ==
        (expandFilename(indexed) / ".data.yaml.index.cbor\n", 0)
    let printed = cli(@["index", "--print", "data.yaml"], workingDir = indexed)
    check printed.exitCode == 0
    check "path: \"$['a'][1]\"" in printed.output
    check cli(@["index", "--mode:recent", "--format:yaml", "data.yaml"],
        workingDir = indexed).exitCode == 0
    check fileExists(indexed / ".data.yaml.index.yaml")
    check cli(@["index", "--drop", "--format:yaml", "data.yaml"],
        workingDir = indexed).exitCode == 0
    check not fileExists(indexed / ".data.yaml.index.yaml")
    check cli(@["index", "--drop", "data.yaml"], workingDir = indexed) ==
        (expandFilename(indexed) / ".data.yaml.index.cbor\n", 0)
    check not fileExists(index)

  test "usage errors":
    check cli("index").exitCode == 2
    check cli("index", "--mode:off", "x.yaml").exitCode == 2
    check cli("index", "--mode:sometimes", "x.yaml").exitCode == 2
    check cli("index", "--print", "--drop", "x.yaml").exitCode == 2
    writeFile(indexed / "x.cbor", "\x01")
    check cli(@["index", "x.cbor"], workingDir = indexed).exitCode == 1

suite "yaml config":
  createDir(tmp / "config" / "sub")
  let project = expandFilename(tmp / "config")

  test "defaults, --print":
    let printed = cli(@["config", "--print"], workingDir = project / "sub")
    check printed.exitCode == 0
    check printed.output.startsWith("# the config in effect for\n#   " &
        project / "sub" & "\n# from\n#   the defaults\n")
    check parseToolConfig(printed.output) == defaultToolConfig().resolved
    check not fileExists(project / "sub" / ".yaml.yaml")

  test "the nearest config, written to DIR/.yaml.yaml":
    writeFile(project / ".yaml", "format: {indentation: 4}\n")
    check cli(@["config", "sub"], workingDir = project) == ("", 0)
    let written = readFile(project / "sub" / ".yaml.yaml")
    check written.startsWith("# the config in effect for\n#   " &
        project / "sub" & "\n# from\n#   " & project / ".yaml\n")
    check parseToolConfig(written).format.indentation == some(4)
    check parseToolConfig(written) ==
        loadToolConfig(project / ".yaml").resolved

  test "an existing file is replaced only with --force":
    writeFile(project / "sub" / ".yaml.yaml", "format: {indentation: 3}\n")
    let refused = cli(@["config", "sub"], workingDir = project)
    check refused.exitCode == 1
    check "use --force" in refused.output
    check readFile(project / "sub" / ".yaml.yaml") ==
        "format: {indentation: 3}\n"
    check cli(@["config", "--force", "sub"], workingDir = project) == ("", 0)
    check loadToolConfig(project / "sub" / ".yaml.yaml").format.indentation ==
        some(3)
    check "comment-gap: 2" in readFile(project / "sub" / ".yaml.yaml")

  test "--config:FILE; never next to a .yaml":
    writeFile(project / "other.yaml", "validate: {schema: false}\n")
    check cli(@["config", "--config:" & (project / "other.yaml"), "--print"],
        workingDir = project).output.contains("  schema: false")
    let refused = cli(@["config", "--force"], workingDir = project)
    check refused.exitCode == 1
    check "cannot have both" in refused.output
    check not fileExists(project / ".yaml.yaml")

  test "usage and config errors":
    check cli("config", "a", "b").exitCode == 2
    check cli("config", "--frob").exitCode == 2
    check cli("config", "--print", "nope").exitCode == 2
    writeFile(project / "bad.yaml", "nope: 1\n")
    check cli(@["config", "--print", "--config:bad.yaml"],
        workingDir = project).exitCode == 2

suite "memory config":
  test "the memory section":
    let c = parseToolConfig(
        "memory: {limit: 64KiB, source: seek, mmap: off, spool: off}\n")
    check c.memoryLimit == 65536
    let policy = c.sourcePolicy
    check policy.choice == tcSeek
    check policy.mmap == swOff
    check policy.spool == swOff

  test "defaults":
    let c = defaultToolConfig()
    check c.memoryLimit == autoLimit()
    check c.sourcePolicy.choice == tcAuto

  test "invalid sizes":
    expect ToolConfigError: discard parseToolConfig("memory: {limit: lots}\n")
    expect ToolConfigError:
      discard parseToolConfig("memory: {map-window: 1XB}\n")

  test "yaml config prints it":
    let printed = cli("config", "--print").output
    check "memory:" in printed
    check "  limit: auto" in printed
    check "detected" in printed

suite "memory cli":
  let big = dir / "big.yaml"
  var text = ""
  for i in 0 ..< 2000: text.add("key" & $i & ": value " & $i & "\n")
  writeFile(big, text)

  test "exceeding the limit is exit code 3":
    let (output, code) = cli("convert", "json", "--memory-limit=1KiB", big)
    check code == 3
    check "memory limit exceeded" in output

  test "--source and --verbose":
    let (output, code) = cli("convert", "json", "--source=seek", "--verbose",
        big)
    check code == 0
    check "big.yaml: tier seek" in output

  test "a stream that needs random access, without spooling":
    let project = dir / "nospool"
    createDir(project)
    writeFile(project / ".yaml", "memory: {limit: 4KiB, spool: off}\n")
    let (output, code) = cli(@["query", "$.key1 = 2"], input = text,
        workingDir = project)
    check code == 3
    check "needs random access" in output

  test "inputs are streamed, not read whole":
    var json = "["
    for i in 0 ..< 6000:
      json.add("{\"id\": " & $i & ", \"name\": \"item " & $i & "\"}" &
          (if i < 5999: "," else: "") & " // " & $i & "\n")
    json.add("]\n")
    writeFile(dir / "big.jsonc", json)
    var lines = ""
    for i in 0 ..< 6000:
      lines.add("{\"id\": " & $i & ", \"name\": \"item " & $i & "\"}\n")
    writeFile(dir / "big.jsonl", lines)
    let huge = dir / "huge.yaml"
    var yaml = ""
    for i in 0 ..< 12000: yaml.add("key" & $i & ": value " & $i & "\n")
    writeFile(huge, yaml)
    check execCmd(quoteShell(bin) & " to cbor " & quoteShell(huge) & " > " &
        quoteShell(dir / "big.cbor")) == 0
    for file in [huge, dir / "big.jsonc", dir / "big.jsonl", dir / "big.cbor"]:
      check getFileSize(file) > 128 * 1024
      let (output, code) = cli("as", "jsonl", "--memory-limit=128KiB",
          "--source=seek", file)
      check code == 0
      let same = output == cli("as", "jsonl", file).output
      check same
      if code != 0: echo output[0 ..< min(output.len, 300)]

  test "format within the limit":
    var text = ""
    for i in 0 ..< 3000:
      text.add("# item " & $i & "\n---\nid:   " & $i & "  # the id\n" &
          "tags: [a,   b]\n")
    let file = dir / "fmt.yaml"
    writeFile(file, text)
    check getFileSize(file) > 128 * 1024
    let expected = cli("format", file)
    check expected.exitCode == 0
    let limited = cli("format", "--memory-limit=128KiB", "--source=seek", file)
    check limited.exitCode == 0
    let same = limited.output == expected.output
    check same
    check cli("format", "--check", "--memory-limit=128KiB", file) ==
        (file & "\n", 1)
    check cli("format", "-i", "--memory-limit=128KiB", file) == ("", 0)
    let written = readFile(file) == expected.output
    check written
    check cli("format", "--check", "--memory-limit=128KiB", file) == ("", 0)

  test "lint, validate, expand and query within the limit":
    var text = "%GLOBAL TAG !e! tag:example.com,2000:\n"
    for i in 0 ..< 4000:
      text.add("--- # doc " & $i & "\nid: " & $i & "\nname: item " & $i &
          "\n")
    let file = dir / "many.yaml"
    writeFile(file, text)
    check getFileSize(file) > 128 * 1024
    for args in [@["lint"], @["validate"], @["expand"], @["query", "$.id"],
        @["query", "--paths", "$..name"]]:
      let expected = cli(args & @[file])
      let limited = cli(args & @["--memory-limit=128KiB", file])
      check limited.exitCode == expected.exitCode
      let same = limited.output == expected.output
      check same
      if not same: echo args, ": ", limited.output[0 ..< min(300, limited.output.len)]

  test "every tier reads every format":
    let expected = cli("as", "jsonl", "a.yaml", "b.jsonc", "c.jsonl")
    for tier in ["memory", "mmap", "seek", "stream"]:
      check cli("as", "jsonl", "--source=" & tier, "a.yaml", "b.jsonc",
          "c.jsonl") == expected

  test "documents before an error are written":
    writeFile(dir / "third.yaml", "a: 1\n---\nb: 2\n---\nc: [\n")
    let (output, code) = cli("as", "jsonl", "third.yaml")
    check code == 1
    check output.startsWith("{\"a\": 1}\n{\"b\": 2}\nthird.yaml:")

  test "in place: an error leaves every file as it was":
    writeFile(dir / "m1.yaml", "a: &x {b: 1}\nc: {<<: *x}\n")
    writeFile(dir / "m2.yaml", "a: [\n")
    check cli("merge", "-i", "m1.yaml", "m2.yaml").exitCode == 1
    check readFile(dir / "m1.yaml") == "a: &x {b: 1}\nc: {<<: *x}\n"
    var temps = 0
    for f in walkDir(dir):
      if "yaml-tmp" in f.path: inc temps
    check temps == 0
    check cli("merge", "-i", "m1.yaml") == ("", 0)
    check readFile(dir / "m1.yaml") == "a: {b: 1}\nc: {b: 1}\n"

  test "an unclosed block comment":
    writeFile(dir / "u.jsonc", "[1,\n  2 /* three\n]")
    check cli("as", "json", "u.jsonc") ==
        ("u.jsonc:2:5: block comment is not closed\n", 1)

  test "usage":
    check cli("convert", "json", "--memory-limit=lots", big).exitCode == 2
    check cli("convert", "json", "--source=nope", big).exitCode == 2
    check "3 if the memory limit is exceeded" in cli("help").output

removeDir(tmp)
