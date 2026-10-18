#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[os, osproc, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]

let
  root = currentSourcePath.parentDir.parentDir
  tmp = getTempDir() / ("yamllint-test-" & $getCurrentProcessId())
  bin = tmp / "yamllint"
  dir = tmp / "files"

createDir(dir)
let (compileOutput, compileCode) = execCmdEx("nim c --hints:off -o:" &
    quoteShell(bin) & " " & quoteShell(root / "tools" / "yamllint.nim"))
doAssert compileCode == 0, compileOutput

writeFile(dir / "ok.yaml", "a: 1\n")
writeFile(dir / "warn.yaml", "a: 1 \n")
writeFile(dir / "bad.yaml", "a: 1\na: 2\n")

proc yamllint(args: varargs[string]): tuple[output: string, exitCode: int] =
  var cmd = quoteShell(bin)
  for arg in args: cmd.add(" " & quoteShell(arg))
  execCmdEx(cmd)

suite "yamllint":
  test "clean file":
    check yamllint(dir / "ok.yaml") == ("", 0)

  test "warnings only: exit code 0":
    check yamllint(dir / "warn.yaml") == (dir / "warn.yaml" &
        ":1:5: warning: trailing whitespace [trailing-spaces]\n", 0)

  test "errors: exit code 1, all files reported":
    check yamllint(dir / "bad.yaml", dir / "warn.yaml") == (dir / "bad.yaml" &
        ":2:1: error: duplicate mapping key \"a\" [duplicate-key]\n" &
        dir / "warn.yaml" &
        ":1:5: warning: trailing whitespace [trailing-spaces]\n", 1)

  test "usage and I/O errors: exit code 2":
    check yamllint().exitCode == 2
    check yamllint("--bogus", dir / "ok.yaml").exitCode == 2
    check yamllint(dir / "missing.yaml").exitCode == 2

  test "--config":
    writeFile(tmp / "strict.yaml", "rules:\n  trailing-spaces: {level: error}\n")
    check yamllint("--config:" & tmp / "strict.yaml", dir / "warn.yaml") ==
        (dir / "warn.yaml" &
        ":1:5: error: trailing whitespace [trailing-spaces]\n", 1)

  test "invalid config: exit code 2":
    writeFile(tmp / "invalid.yaml", "rules:\n  nope: {}\n")
    let r = yamllint("--config:" & tmp / "invalid.yaml", dir / "ok.yaml")
    check r.exitCode == 2
    check "unknown rule: nope" in r.output

  test "config found by walking up from the file":
    writeFile(tmp / ".nimyaml-lint.yaml", "rules:\n  duplicate-key: {level: off}\n")
    defer: removeFile(tmp / ".nimyaml-lint.yaml")
    check yamllint(dir / "bad.yaml") == ("", 0)

removeDir(tmp)
