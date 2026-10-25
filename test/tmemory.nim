#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml/memory
import unittest, strutils

suite "memory sizes":
  test "parseSize":
    check parseSize("123") == 123
    check parseSize("64KiB") == 65536
    check parseSize("16MiB") == 16 shl 20
    check parseSize("1GiB") == 1 shl 30
    check parseSize("2TiB") == 2 shl 40
    check parseSize("10MB") == 10_000_000
    check parseSize("5kB") == 5000
    check parseSize(" 4 KiB ") == 4096
    check parseSize("unlimited") == int.high
    expect ValueError: discard parseSize("12XB")
    expect ValueError: discard parseSize("-1")
    expect ValueError: discard parseSize("")
    expect ValueError: discard parseSize("KiB")

  test "formatSize":
    check formatSize(64 shl 20) == "64 MiB"
    check formatSize(512) == "512 B"
    check formatSize(1536 shl 20) == "1.5 GiB"
    check formatSize(4096) == "4 KiB"
    check formatSize(int.high) == "unlimited"

suite "memory budget":
  test "reserve and release":
    let b = newMemoryBudget(1000)
    b.reserve(600, "a")
    check b.used == 600
    b.reserve(400, "b")
    check b.used == 1000
    b.release(700)
    check b.used == 300
    check b.peak == 1000
    check b.available == 700

  test "reserve past the limit":
    let b = newMemoryBudget(1000)
    b.reserve(900, "first")
    try:
      b.reserve(200, "reading line 3")
      check false
    except YamlMemoryLimitError as e:
      check e.needed == 1100
      check e.limit == 1000
      check e.operation == "reading line 3"
      check "reading line 3" in e.describe
      check "limit" in e.describe
    check b.used == 900

  test "nil budget":
    let b: MemoryBudget = nil
    b.reserve(int.high div 2, "x")
    b.release(10)
    check b.available == int.high

  test "error in the parent chain":
    let inner = (ref YamlMemoryLimitError)(msg: "m", operation: "op",
        needed: 2, limit: 1)
    let outer = (ref ValueError)(msg: "outer",
        parent: (ref IOError)(msg: "mid", parent: inner))
    check memoryLimitError(outer) == inner
    check memoryLimitError((ref ValueError)(msg: "no")).isNil

suite "host memory":
  test "detected":
    when defined(macosx) or defined(linux) or defined(windows):
      check hostMemory() > 0
      check autoLimit() == hostMemory() div 2
    else:
      check hostMemory() == -1
