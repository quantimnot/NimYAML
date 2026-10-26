#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml/[memory, source]
import std/[os, osproc, streams, strutils, unittest]
when defined(posix):
  import std/posix
proc setFileSize(path: string, size: int) =
  when defined(posix):
    discard truncate(path.cstring, Off(size))
when defined(nimPreviewSlimSystem):
  import std/syncio

let tmp = getTempDir() / ("yaml-source-test-" & $getCurrentProcessId())
createDir(tmp)

proc sample(): string =
  ## 300 KiB of CRLF lines with a 3-byte UTF-8 character at offset 4095,
  ## across the boundary of a 4 KiB page.
  var line = 0
  while result.len < 300 * 1024:
    result.add("key" & $line & ": value " & $line & "\r\n")
    inc line
  result[4094] = 'x'
  result[4095 .. 4097] = "\xE2\x82\xAC" # euro sign

let
  content = sample()
  path = tmp / "sample.yaml"
  emptyPath = tmp / "empty.yaml"
writeFile(path, content)
writeFile(emptyPath, "")

proc policy(choice: TierChoice): SourcePolicy =
  SourcePolicy(choice: choice, mapWindow: 4096, pageCache: 8192)

proc pipeFrom(file: string): tuple[p: Process, f: File] =
  ## A pipe that delivers the content of ``file``.
  result.p = startProcess("/bin/cat", args = [file], options = {})
  if not open(result.f, result.p.outputHandle, fmRead):
    raise newException(IOError, "cannot open the pipe")

suite "source tiers":
  for choice in [tcMemory, tcMmap, tcSeek, tcStream]:
    test "read all, " & $choice:
      let b = newMemoryBudget(1 shl 20)
      let src = openSource(path, b, policy(choice))
      check src.size == content.len
      check src.readAll("test") == content
      src.close()
      check b.used == 0

    test "stream from an offset, " & $choice:
      let src = openSource(path, nil, policy(choice))
      let s = newSourceStream(src, 1000)
      check s.readAll() == content[1000 .. ^1]
      src.close()

    test "empty file, " & $choice:
      let src = openSource(emptyPath, nil, policy(choice))
      check src.size == 0
      check src.readAll("test") == ""
      check newSourceStream(src).readAll() == ""
      src.close()

  for choice in [tcMemory, tcMmap, tcSeek]:
    test "random access, " & $choice:
      let src = openSource(path, nil, policy(choice))
      check src.randomAccess
      var buf = newString(4)
      check src.read(4094, buf.toOpenArray(0, 3)) == 4
      check buf == content[4094 .. 4097]
      check src.slice(10, 19) == content[10 .. 19]
      check src.slice(content.len - 3, content.len + 10) == content[^3 .. ^1]
      # backwards, and across windows and pages
      check src.slice(200_000, 250_000) == content[200_000 .. 250_000]
      check src.slice(5, 70_000) == content[5 .. 70_000]
      src.close()

  test "sequential reads only forward":
    let src = openSource(path, nil, policy(tcStream))
    check src.tier == stSequential
    check not src.randomAccess
    var buf = newString(10)
    check src.read(0, buf.toOpenArray(0, 9)) == 10
    check src.read(10, buf.toOpenArray(0, 9)) == 10
    check buf == content[10 .. 19]
    expect YamlSourceError: discard src.read(0, buf.toOpenArray(0, 9))
    src.close()

  test "mapped and seekable stay within their window and cache":
    for choice in [tcMmap, tcSeek]:
      let b = newMemoryBudget(1 shl 20)
      let src = openSource(path, b, policy(choice))
      discard newSourceStream(src).readAll()
      discard src.slice(200_000, 210_000)
      discard src.slice(3, 300)
      check b.peak <= 128 * 1024
      src.close()
      check b.used == 0

  test "size is fixed when opened":
    let grow = tmp / "grow.yaml"
    writeFile(grow, "a: 1\n")
    for choice in [tcMmap, tcSeek, tcStream]:
      let src = openSource(grow, nil, policy(choice))
      let f = open(grow, fmAppend)
      f.write("b: 2\n")
      f.close()
      check newSourceStream(src).readAll().startsWith("a: 1\n")
      check src.size == 5 or choice == tcStream
      src.close()
      writeFile(grow, "a: 1\n")

suite "source tier choice":
  test "auto":
    let small = tmp / "small.yaml"
    writeFile(small, "a: 1\n")
    var src = openSource(small, newMemoryBudget(1 shl 20))
    check src.tier == stInMemory
    src.close()
    src = openSource(path, newMemoryBudget(256 * 1024))
    check src.tier == stMapped
    src.close()
    src = openSource(path, newMemoryBudget(256 * 1024),
        SourcePolicy(mmap: swOff))
    check src.tier == stSeekable
    src.close()
    # no budget: everything fits in memory, as before
    src = openSource(path)
    check src.tier == stInMemory
    src.close()

  test "forced memory does not override the limit":
    expect YamlMemoryLimitError:
      discard openSource(path, newMemoryBudget(64 * 1024), policy(tcMemory))

  test "pipe":
    let (p, f) = pipeFrom(path)
    let src = openSource(f, "<pipe>")
    check src.tier == stSequential
    check newSourceStream(src).readAll() == content
    src.close()
    p.close()

  test "pipe with random access spools":
    let (p, f) = pipeFrom(path)
    let src = openSource(f, "<pipe>", newMemoryBudget(256 * 1024),
        randomAccess = true)
    check src.tier in {stMapped, stSeekable}
    check src.randomAccess
    check src.slice(4094, 4097) == content[4094 .. 4097]
    src.close()
    p.close()

  test "pipe with random access and no spooling":
    let (p, f) = pipeFrom(path)
    try:
      discard openSource(f, "<pipe>", newMemoryBudget(256 * 1024),
          SourcePolicy(spool: swOff), randomAccess = true)
      check false
    except YamlMemoryLimitError as e:
      check "needs random access" in e.operation
    p.close()

  test "forced stream spools when random access is needed":
    let src = openSource(path, nil, policy(tcStream), randomAccess = true)
    check src.randomAccess
    check src.slice(10, 19) == content[10 .. 19]
    src.close()

proc stringReader(data: string): ReadProc =
  ## Reads ``data`` at any offset.
  result = proc (offset: int64, dest: var openArray[char]): int =
    result = max(0, min(dest.len, data.len - int(offset)))
    for i in 0 ..< result: dest[i] = data[int(offset) + i]

proc forwardReader(data: string): ReadProc =
  ## Reads ``data`` front to back, ignoring offsets.
  var pos = 0
  result = proc (offset: int64, dest: var openArray[char]): int =
    result = min(dest.len, data.len - pos)
    for i in 0 ..< result: dest[i] = data[pos + i]
    pos += result

suite "callback source":
  test "random access":
    let src = openSource(stringReader(content), int64(content.len),
        randomAccess = true)
    check src.randomAccess
    check src.slice(4094, 4097) == content[4094 .. 4097]
    check newSourceStream(src).readAll() == content
    src.close()

  test "sequential":
    let data = "a: 1\nb: 2\n"
    let src = openSource(forwardReader(data))
    check src.tier == stSequential
    check newSourceStream(src).readAll() == data

suite "string source":
  test "charges its content":
    let b = newMemoryBudget(1000)
    let src = sourceOf("a: 1\n", "<s>", b)
    check src.tier == stInMemory
    check b.used == 5
    check newSourceStream(src, 3).readAll() == "1\n"
    src.close()
    check b.used == 0

suite "review findings":
  test "a named pipe is read as a stream":
    when defined(posix):
      let fifo = tmp / "fifo"
      discard execShellCmd("mkfifo " & quoteShell(fifo))
      let writer = startProcess("/bin/sh", args = ["-c",
          "sleep 0.2; printf 'a: [1]\\n' > " & quoteShell(fifo)], options = {})
      let src = openSource(fifo, newMemoryBudget(1 shl 20))
      check src.tier == stSequential
      check newSourceStream(src).readAll() == "a: [1]\n"
      src.close()
      discard writer.waitForExit()
      writer.close()

  test "auto reads by seeking when an mmap window does not fit":
    # the window has a floor of two pages, more than an eighth of 64 KiB
    let src = openSource(path, newMemoryBudget(64 * 1024))
    check src.tier == stSeekable
    check newSourceStream(src).readAll() == content
    src.close()

  test "a file that shrinks while it is read":
    for choice in [tcMmap, tcSeek]:
      let shrinking = tmp / "shrinking.yaml"
      writeFile(shrinking, content)
      let src = openSource(shrinking, newMemoryBudget(1 shl 20),
          SourcePolicy(choice: choice, mapWindow: 4096, pageCache: 8192))
      let f = open(shrinking, fmReadWrite)
      f.setFilePos(0)
      setFileSize(shrinking, 1000)
      f.close()
      expect IOError: discard newSourceStream(src).readAll()
      src.close()

  test "a small pipe fits a small limit without spooling":
    let small = tmp / "five.yaml"
    writeFile(small, "a: 1\n")
    let (p, f) = pipeFrom(small)
    let src = openSource(f, "<pipe>", newMemoryBudget(32 * 1024),
        SourcePolicy(spool: swOff), randomAccess = true)
    check src.readAll("test") == "a: 1\n"
    src.close()
    p.close()

  test "spool files are private and removed":
    when defined(posix):
      let (p, f) = pipeFrom(path)
      let spoolDir = tmp / "spool"
      createDir(spoolDir)
      let src = openSource(f, "<pipe>", newMemoryBudget(256 * 1024),
          SourcePolicy(spoolDir: spoolDir), randomAccess = true)
      var spools: seq[string]
      for file in walkDir(spoolDir): spools.add(file.path)
      check spools.len == 1
      check getFilePermissions(spools[0]) == {fpUserRead, fpUserWrite}
      src.close()
      p.close()
      spools.setLen(0)
      for file in walkDir(spoolDir): spools.add(file.path)
      check spools.len == 0

removeDir(tmp)
