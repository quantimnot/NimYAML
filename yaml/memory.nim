#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/memory
## ==================
##
## A memory budget for processing input of any size on hosts with little
## memory. A `MemoryBudget` is charged where memory grows with the input:
## the lexer's buffer, buffered events, constructed nodes and in-memory
## sources. Exceeding its limit raises `YamlMemoryLimitError` before the
## memory is allocated, so that a command fails with a clear message instead
## of being killed by the host.
##
## A ``nil`` budget is unlimited; every API that takes a budget defaults to
## it. The module has no dependencies on an operating system, so that it
## builds for microcontrollers (``--os:any``); `hostMemory` then reports
## ``-1`` and `autoLimit` falls back to the compile-time default
## ``-d:yamlMemoryLimit=BYTES``.

import std/strutils
when defined(linux):
  when defined(nimPreviewSlimSystem):
    import std/syncio

type
  MemoryBudget* = ref object
    ## The memory that processing may use. ``used`` is what is reserved
    ## now, ``peak`` the most that was reserved at once.
    limit*: int ## bytes; ``int.high`` is unlimited
    used*, peak*: int

  YamlMemoryLimitError* = object of ValueError
    ## Raised when a reservation would exceed the limit of a budget.
    operation*: string ## what needed the memory, e.g. "reading line 12"
    needed*: int       ## the bytes that would have been reserved in total
    limit*: int

const
  yamlMemoryLimit* {.intdefine.} = 0
    ## the limit `autoLimit` falls back to when the host memory is unknown;
    ## 0 for none (unlimited)

proc newMemoryBudget*(limit = int.high): MemoryBudget =
  MemoryBudget(limit: limit)

proc formatSize*(bytes: int): string =
  ## ``bytes`` in the largest binary unit it reaches, with at most one
  ## decimal: ``64 MiB``, ``1.5 GiB``, ``512 B``.
  if bytes == int.high: return "unlimited"
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  var
    unit = 0
    scaled = float(bytes)
  while scaled >= 1024 and unit < units.high:
    scaled /= 1024
    inc unit
  if unit == 0: return $bytes & " B"
  var text = formatFloat(scaled, ffDecimal, 1)
  if text.endsWith(".0"): text.setLen(text.len - 2)
  text & " " & units[unit]

proc describe*(e: ref YamlMemoryLimitError): string =
  ## The message of ``e``: what needed how much memory, and the limit.
  "memory limit exceeded: " & e.operation & " needs ~" &
      formatSize(e.needed) & " (limit " & formatSize(e.limit) & ")"

proc reserve*(b: MemoryBudget, bytes: int, operation: string)
    {.raises: [YamlMemoryLimitError].} =
  ## Reserves ``bytes`` for ``operation``. Raises `YamlMemoryLimitError`,
  ## and reserves nothing, if that exceeds the limit. A ``nil`` budget
  ## reserves nothing and never raises.
  if b.isNil or bytes <= 0: return
  let needed = if bytes > int.high - b.used: int.high else: b.used + bytes
  if needed > b.limit:
    let e = (ref YamlMemoryLimitError)(operation: operation, needed: needed,
        limit: b.limit)
    e.msg = e.describe
    raise e
  b.used = needed
  if needed > b.peak: b.peak = needed

proc release*(b: MemoryBudget, bytes: int) {.raises: [].} =
  ## Returns ``bytes`` reserved before.
  if b.isNil or bytes <= 0: return
  b.used = max(0, b.used - bytes)

proc available*(b: MemoryBudget): int {.raises: [].} =
  ## The bytes that may still be reserved.
  if b.isNil or b.limit == int.high: int.high else: max(0, b.limit - b.used)

proc parseSize*(text: string): int {.raises: [ValueError].} =
  ## Parses a size: plain bytes (``123``), binary units (``64KiB``,
  ## ``16MiB``, ``1GiB``, ``2TiB``), decimal units (``5kB``, ``10MB``,
  ## ``1GB``, ``1TB``), or ``unlimited``.
  let t = text.strip()
  if t == "unlimited": return int.high
  var i = 0
  while i < t.len and t[i] in Digits: inc i
  if i == 0: raise newException(ValueError, "not a size: " & text)
  let number = parseBiggestInt(t[0 ..< i])
  let factor = case t[i .. ^1].strip().toLowerAscii()
    of "", "b": 1
    of "kib", "k": 1 shl 10
    of "mib", "m": 1 shl 20
    of "gib", "g": 1 shl 30
    of "tib", "t": 1 shl 40
    of "kb": 1000
    of "mb": 1_000_000
    of "gb": 1_000_000_000
    of "tb": 1_000_000_000_000
    else: raise newException(ValueError, "unknown unit in size: " & text)
  if number > int.high div factor:
    raise newException(ValueError, "size too large: " & text)
  int(number) * factor

proc memoryLimitError*(e: ref Exception): ref YamlMemoryLimitError =
  ## The `YamlMemoryLimitError` that is ``e`` or one of its ``parent``s
  ## (errors are wrapped as they pass through the lexer, parser and
  ## streams); ``nil`` if there is none.
  var current = e
  while not current.isNil:
    if current of YamlMemoryLimitError:
      return (ref YamlMemoryLimitError)(current)
    current = current.parent
  nil

# host memory

when defined(macosx):
  proc sysctlbyname(name: cstring, oldp: pointer, oldlenp: ptr csize_t,
      newp: pointer, newlen: csize_t): cint
      {.importc, header: "<sys/sysctl.h>".}
elif defined(windows):
  type MemoryStatusEx {.importc: "MEMORYSTATUSEX", header: "<windows.h>".} = object
    dwLength: uint32
    ullAvailPhys: uint64
  proc globalMemoryStatusEx(status: ptr MemoryStatusEx): int32
      {.importc: "GlobalMemoryStatusEx", header: "<windows.h>", stdcall.}

when defined(linux):
  proc readNumber(path: string): int =
    ## The number a /sys or /proc file starts with; -1 if there is none.
    try:
      let text = readFile(path).strip()
      if text.len == 0 or text == "max": return -1
      result = parseInt(text.splitWhitespace()[0])
    except CatchableError: result = -1

  proc memAvailable(): int =
    try:
      for line in readFile("/proc/meminfo").splitLines():
        if line.startsWith("MemAvailable:"):
          return parseInt(line.splitWhitespace()[1]) * 1024
    except CatchableError: discard
    -1

proc hostMemory*(): int =
  ## The memory this process can use on its host, in bytes: the memory
  ## limit of its Linux control group, else the available memory (Linux
  ## and Windows) or the physical memory (macOS). -1 if it is unknown.
  when defined(linux):
    var limits: seq[int]
    for path in ["/sys/fs/cgroup/memory.max",
        "/sys/fs/cgroup/memory/memory.limit_in_bytes"]:
      let n = readNumber(path)
      # cgroup v1 reports an absurdly large number for no limit
      if n > 0 and n < (1 shl 60): limits.add(n)
    let available = memAvailable()
    if available > 0: limits.add(available)
    result = if limits.len > 0: min(limits) else: -1
  elif defined(macosx):
    var
      size: uint64
      length = csize_t(sizeof(size))
    if sysctlbyname("hw.memsize", addr size, addr length, nil, 0) == 0:
      result = int(size)
    else: result = -1
  elif defined(windows):
    var status = MemoryStatusEx(dwLength: uint32(sizeof(MemoryStatusEx)))
    if globalMemoryStatusEx(addr status) != 0: result = int(status.ullAvailPhys)
    else: result = -1
  else: result = -1

proc autoLimit*(): int =
  ## The limit ``auto`` stands for: half of `hostMemory`, else the
  ## compile-time default ``yamlMemoryLimit``, else unlimited.
  let host = hostMemory()
  if host > 0: host div 2
  elif yamlMemoryLimit > 0: yamlMemoryLimit
  else: int.high
