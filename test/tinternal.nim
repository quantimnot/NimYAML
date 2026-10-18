#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, osproc, strutils, unittest
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]

const repoRoot = currentSourcePath.parentDir.parentDir

suite "Internal assertions":
  test "failing yAssert outside of an exception handler reports and quits":
    # construct expects the stream to be positioned before yamlStartDoc; a
    # stream starting with yamlStartStream trips a yAssert. This crashed with
    # SIGSEGV because yAssert dereferenced the (nil) current exception.
    let dir = getTempDir() / "nimyaml_tinternal"
    createDir(dir)
    defer: removeDir(dir)
    let src = dir / "trip.nim"
    writeFile(src, """
import "$1/yaml"
import "$1/yaml/parser"
var s = initYamlParser().parse("a: b\n")
var target: string
construct(s, target)
""" % [repoRoot])
    let (output, exitCode) = execCmdEx(quoteShellCommand([
        getCurrentCompilerExe(), "c", "-r", "--hints:off", "--warnings:off",
        "--nimcache:" & dir / "cache", "-o:" & dir / "trip", src]))
    check "assertion failed!" in output
    check "Please report this bug" in output
    check "SIGSEGV" notin output
    check exitCode == 1
