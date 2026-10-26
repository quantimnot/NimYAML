#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## The yaml tool on huge generated inputs within a small memory limit: the
## output must equal that of an unlimited run, and the peak resident memory
## must stay within the limit plus the tool's baseline. The size of the
## inputs is YAML_HUGE_MB megabytes (default 64).

import std/[os, osproc, sequtils, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import genhuge

const
  MiB = 1 shl 20
  limit = 1 * MiB
  slack = 4 * MiB # allocator and runtime overhead on top of the limit

let
  root = currentSourcePath.parentDir.parentDir
  tmp = getTempDir() / ("yaml-constrained-" & $getCurrentProcessId())
  bin = tmp / "yaml"
  megabytes = parseInt(getEnv("YAML_HUGE_MB", "64"))

createDir(tmp)
block:
  let (output, code) = execCmdEx("nim c -d:release --hints:off -o:" &
      quoteShell(bin) & " " & quoteShell(root / "tools" / "yamlcli.nim"))
  if code != 0: quit(output)

let
  many = tmp / "many.yaml"
  huge = tmp / "huge.yaml"
  small = tmp / "small.yaml"
genManyDocs(many, megabytes * MiB)
genHugeDoc(huge, megabytes * MiB)
genSmall(small)
let patchFile = tmp / "patch.yaml"
writeFile(patchFile, "[{op: add, path: /extra, value: 1}]\n")

type Run = tuple[code, rss: int, errors: string]

proc run(args: seq[string], output: string): Run =
  ## Runs the yaml tool with ``args``, its output written to ``output``,
  ## and measures its peak resident memory.
  let errors = output & ".err"
  let timing = when defined(macosx): "-l" else: "-v"
  result.code = execCmd("/usr/bin/time " & timing & " " & quoteShell(bin) &
      " " & args.mapIt(quoteShell(it)).join(" ") & " > " &
      quoteShell(output) & " 2> " & quoteShell(errors))
  for line in readFile(errors).splitLines:
    let text = line.strip()
    when defined(macosx):
      if text.endsWith("maximum resident set size"):
        result.rss = parseInt(text.splitWhitespace()[0])
        continue
    else:
      if text.startsWith("Maximum resident set size (kbytes):"):
        result.rss = parseInt(text.split(':')[1].strip()) * 1024
        continue
    if text.len > 0 and not text[0].isDigit and "\t" notin line:
      result.errors.add(line & "\n")

proc baseline(args: seq[string]): Run =
  ## The command ``args`` on the small input instead of the huge ones: its
  ## memory without input.
  run(args.mapIt(if it in [many, huge]: small else: it) & @[small],
      tmp / "baseline.out")

proc sameFiles(a, b: string): bool =
  getFileSize(a) == getFileSize(b) and readFile(a) == readFile(b)

proc within(args: seq[string], input: string): string =
  ## ``args`` on ``input`` within the limit, by every tier that reads it
  ## piece by piece: the same output as without a limit, and a peak
  ## resident memory within the limit and the baseline of the command.
  ## Returns what went wrong, if anything.
  let
    expected = run(args & @["--memory-limit=unlimited", input],
        tmp / "expected.out")
    baseline = baseline(args)
  for tier in ["mmap", "seek", "stream"]:
    let r = run(args & @["--memory-limit=" & $limit, "--source=" & tier,
        input], tmp / "limited.out")
    let bound = baseline.rss + limit + slack
    if r.code != expected.code or
        not sameFiles(tmp / "expected.out", tmp / "limited.out") or
        r.rss > bound:
      result.add(args.join(" ") & " --source=" & tier & ": exit " &
          $r.code & " (expected " & $expected.code & "), peak " &
          $(r.rss div 1024) & " KiB (bound " & $(bound div 1024) &
          " KiB, baseline " & $(baseline.rss div 1024) & " KiB)\n" & r.errors)

proc exceeds(args: seq[string], input: string, tier = "seek"): string =
  ## ``args`` on ``input`` exceeds the limit: exit code 3, without growing
  ## past the limit first. Returns what went wrong, if anything.
  let baseline = baseline(args)
  let r = run(args & @["--memory-limit=" & $limit, "--source=" & tier,
      input], tmp / "limited.out")
  let bound = baseline.rss + limit + slack
  if r.code != 3 or "memory limit exceeded" notin r.errors or r.rss > bound:
    result = args.join(" ") & ": exit " & $r.code & ", peak " &
        $(r.rss div 1024) & " KiB (bound " & $(bound div 1024) & " KiB)\n" &
        r.errors

template expectNothing(problems: string) =
  let p = problems
  if p.len > 0: echo p
  check p.len == 0

suite "many documents":
  for args in [@["convert", "json"], @["convert", "cbor"],
      @["convert", "jsonl"], @["merge"], @["format"],
      @["format", "--drop-comments"], @["lint"], @["validate"], @["expand"],
      @["query", "$.item.k"], @["query", "--paths", "$..name"],
      @["canonical"], @["patch", patchFile], @["diff", many],
      @["query", "$.item.k = 0"], @["query", "--to:json", "$.item.k = 0"]]:
    test args.join(" "):
      expectNothing within(args, many)

  test "index --mode:recent exceeds the limit":
    # an index has a record of each of the many documents
    expectNothing exceeds(@["index", "--mode:recent", "--location:beside"],
        many)

  test "index --mode:all exceeds the limit":
    expectNothing exceeds(@["index", "--mode:all", "--location:beside"], many)

  test "forced memory exceeds the limit":
    expectNothing exceeds(@["convert", "json"], many, "memory")

suite "one huge document":
  for args in [@["convert", "json"], @["convert", "yaml"],
      @["format", "--drop-comments"], @["query", "$.items[*].k"],
      @["query", "--paths", "$.items[?@.k > 5].name"]]:
    test args.join(" "):
      expectNothing within(args, huge)

  test "convert cbor exceeds the limit":
    expectNothing exceeds(@["convert", "cbor"], huge)

  test "format with comments exceeds the limit":
    expectNothing exceeds(@["format"], huge)

  for args in [@["canonical"], @["merge"], @["patch", patchFile],
      @["diff", huge], @["query", "$.items[0].k = 0"]]:
    test args.join(" ") & " exceeds the limit":
      expectNothing exceeds(args, huge)

  for args in [@["lint"], @["validate"]]:
    test args.join(" ") & " exceeds the limit":
      expectNothing exceeds(args, huge)

removeDir(tmp)
