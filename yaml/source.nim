#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/source
## ==================
##
## Input of any size, read in the best way the host supports. A
## `YamlSource` has one of four tiers:
##
## * ``memory``: the whole input in a string. The fastest, and the default
##   for input that fits easily into the memory budget.
## * ``mmap``: a window of the file mapped into memory, moved as reading
##   proceeds. The window is charged to the budget; the operating system
##   pages the file in and out.
## * ``seek``: a file read at offsets, with a small cache of pages for
##   small reads.
## * ``stream``: input that can only be read forward: a pipe, standard
##   input, or a callback without offsets.
##
## `openSource` chooses the tier of a file from its size, the memory budget
## and a `SourcePolicy`, which can also force a tier. A command that needs
## random access to a stream gets the stream spooled to a temporary file
## (or, without a budget or with ``spool: off``, read into memory, which the
## budget is charged for).
##
## On hosts without files (``--os:any``), sources are strings or callbacks
## (`openSource` with a `ReadProc`), so that firmware can read input from
## flash, an SD card or a network transport.
##
## `newSourceStream` gives a forward `Stream` of a source, which the parser
## reads; its lexer keeps only a sliding window of it.

import std/streams
import memory
const hasFiles = defined(posix) or defined(windows)
when hasFiles:
  import std/[memfiles, os]
  when defined(nimPreviewSlimSystem):
    import std/syncio
  when defined(posix):
    import std/posix

type
  SourceTier* = enum
    ## How a source is read; see the module documentation.
    stInMemory = "memory", stMapped = "mmap", stSeekable = "seek",
    stSequential = "stream"

  TierChoice* = enum
    ## A tier to force, or ``auto`` to let `openSource` choose.
    tcAuto = "auto", tcMemory = "memory", tcMmap = "mmap", tcSeek = "seek",
    tcStream = "stream"

  Switch* = enum
    swAuto = "auto", swOn = "on", swOff = "off"

  SourcePolicy* = object
    ## How `openSource` reads files.
    choice*: TierChoice ## the tier; ``tcAuto`` chooses by size and budget
    mmap*: Switch       ## ``swOff`` never maps files (forced ``mmap``
                        ## becomes ``seek``)
    mapWindow*: int     ## bytes of a mapped window; 0 for 64 MiB. At most
                        ## an eighth of the limit (so that several sources
                        ## and their parsers fit), at least two pages.
    pageCache*: int     ## bytes of cached pages of a seekable file; 0 for
                        ## an eighth of the limit, at most 1 MiB
    spool*: Switch      ## whether a stream that needs random access is
                        ## spooled to a temporary file; ``swOff`` reads it
                        ## into memory instead
    spoolDir*: string   ## the directory of spooled streams; "" for the
                        ## temporary directory

  ReadProc* = proc (offset: int64, dest: var openArray[char]): int
      {.closure, gcsafe, raises: [IOError].}
    ## Reads up to ``dest.len`` bytes at ``offset`` into ``dest`` and
    ## returns their number; 0 at the end of the input. A callback of a
    ## sequential source is always called with the next offset.

  YamlSourceError* = object of IOError
    ## Raised for a read a source cannot do, like reading a stream
    ## backwards.

  Page = object
    index: int64
    data: string
    lastUse: int

  YamlSource* = ref object
    ## Input, read by tier; see the module documentation.
    tier*: SourceTier
    size*: int64   ## bytes, fixed when opened; -1 if unknown (a stream)
    name*: string
    budget*: MemoryBudget
    random: bool
    charged: int
    content: string     # stInMemory
    reader: ReadProc    # callback sources
    pos: int64          # next offset of a sequential source
    ended: bool         # a sequential source has been read to its end
    pages: seq[Page]    # cache of a seekable file
    pageLimit, tick: int
    when hasFiles:
      file: File
      ownsFile: bool
      mem: MemFile
      mapped: bool
      initial: pointer  # the mapping made by memfiles.open, at offset 0
      initialLen: int
      winPtr: pointer
      winOffset: int64
      winLen, window: int
      spoolPath: string

const
  pageSize = 4096
  copyChunk = 65536
  defaultWindow = 64 shl 20

proc limitOf(budget: MemoryBudget): int =
  if budget.isNil: int.high else: budget.limit

proc charge(src: YamlSource, bytes: int, operation: string) =
  src.budget.reserve(bytes, operation)
  src.charged += bytes

proc randomAccess*(src: YamlSource): bool =
  ## Whether `read` accepts any offset.
  src.random

proc clipped(src: YamlSource, offset: int64, len: int): int =
  if offset < 0: return 0
  if src.size < 0: return len
  int(max(0'i64, min(int64(len), src.size - offset)))

# tiers

when hasFiles:
  proc mapAlignment(): int =
    when defined(windows): 65536
    else: int(sysconf(SC_PAGESIZE))

  proc readFileAt(f: File, offset: int64, dest: var openArray[char]): int =
    if dest.len == 0: return 0
    f.setFilePos(offset)
    var done = 0
    while done < dest.len:
      let n = f.readBuffer(addr dest[done], dest.len - done)
      if n <= 0: break
      done += n
    done

  proc moveWindow(src: YamlSource, offset: int64) {.raises: [IOError].} =
    ## Maps the window that holds ``offset``.
    let
      align = mapAlignment()
      start = offset - offset mod align
      len = int(min(int64(src.window), src.size - start))
    if not src.winPtr.isNil and src.winPtr != src.initial:
      try: src.mem.unmapMem(src.winPtr, src.winLen)
      except OSError as e: raise newException(IOError, e.msg)
    if start == 0 and len <= src.initialLen:
      src.winPtr = src.initial
      src.winLen = src.initialLen
    else:
      try: src.winPtr = src.mem.mapMem(fmRead, len, int(start))
      except OSError as e:
        src.winPtr = nil
        raise newException(IOError, src.name & ": cannot map: " & e.msg)
      src.winLen = len
    src.winOffset = start

  proc readMapped(src: YamlSource, offset: int64, dest: var openArray[char]) =
    var done = 0
    while done < dest.len:
      let at = offset + done
      if src.winPtr.isNil or at < src.winOffset or
          at >= src.winOffset + src.winLen:
        src.moveWindow(at)
      let
        inWindow = int(at - src.winOffset)
        n = min(dest.len - done, src.winLen - inWindow)
      copyMem(addr dest[done],
          cast[pointer](cast[uint](src.winPtr) + uint(inWindow)), n)
      done += n

proc readPage(src: YamlSource, index: int64): int {.raises: [IOError].} =
  ## The slot of the cached page ``index``, read if it is not cached; -1 if
  ## the budget has no room for a page and none is cached.
  inc src.tick
  for i, p in src.pages:
    if p.index == index:
      src.pages[i].lastUse = src.tick
      return i
  var slot = -1
  if src.pages.len * pageSize < src.pageLimit or src.pages.len == 0:
    try:
      src.charge(pageSize, "caching a page of " & src.name)
      src.pages.add(Page(data: newString(pageSize)))
      slot = src.pages.high
    except YamlMemoryLimitError:
      if src.pages.len == 0: return -1
  if slot < 0:
    slot = 0
    for i, p in src.pages:
      if p.lastUse < src.pages[slot].lastUse: slot = i
  src.pages[slot].index = index
  src.pages[slot].lastUse = src.tick
  let offset = index * pageSize
  var n = 0
  when hasFiles:
    if src.reader.isNil:
      n = readFileAt(src.file, offset, src.pages[slot].data.toOpenArray(0, pageSize - 1))
  if not src.reader.isNil:
    while n < pageSize:
      let got = src.reader(offset + n,
          src.pages[slot].data.toOpenArray(n, pageSize - 1))
      if got <= 0: break
      n += got
  src.pages[slot].data.setLen(n)
  src.pages[slot].data.setLen(pageSize)
  slot

proc readDirect(src: YamlSource, offset: int64, dest: var openArray[char]): int =
  when hasFiles:
    if src.reader.isNil: return readFileAt(src.file, offset, dest)
  var done = 0
  while done < dest.len:
    let n = src.reader(offset + done, dest.toOpenArray(done, dest.high))
    if n <= 0: break
    done += n
  done

proc read*(src: YamlSource, offset: int64, dest: var openArray[char]): int
    {.raises: [IOError].} =
  ## Reads up to ``dest.len`` bytes at ``offset`` into ``dest`` and returns
  ## their number, which is smaller only at the end of the input. A
  ## sequential source reads only at the offset after the previous read,
  ## and raises `YamlSourceError` for any other.
  let n = src.clipped(offset, dest.len)
  if n == 0: return 0
  case src.tier
  of stInMemory:
    copyMem(addr dest[0], addr src.content[int(offset)], n)
    result = n
  of stMapped:
    when hasFiles:
      src.readMapped(offset, dest.toOpenArray(0, n - 1))
      result = n
  of stSeekable:
    if n >= pageSize: return src.readDirect(offset, dest.toOpenArray(0, n - 1))
    var done = 0
    while done < n:
      let
        at = offset + done
        slot = src.readPage(at div pageSize)
      if slot < 0: return done + src.readDirect(at, dest.toOpenArray(done, n - 1))
      let
        inPage = int(at mod pageSize)
        count = min(n - done, pageSize - inPage)
      copyMem(addr dest[done], addr src.pages[slot].data[inPage], count)
      done += count
    result = done
  of stSequential:
    if offset != src.pos:
      raise newException(YamlSourceError, src.name &
          ": cannot read at offset " & $offset & " of a stream at offset " &
          $src.pos)
    if src.ended: return 0
    when hasFiles:
      if src.reader.isNil:
        var done = 0
        while done < n:
          let got = src.file.readBuffer(addr dest[done], n - done)
          if got <= 0: break
          done += got
        result = done
    if not src.reader.isNil:
      result = src.reader(offset, dest.toOpenArray(0, n - 1))
    if result <= 0:
      src.ended = true
      result = 0
    src.pos += result

proc slice*(src: YamlSource, first, last: int64): string {.raises: [IOError].} =
  ## The bytes from ``first`` to ``last``, both included; shorter at the
  ## end of the input.
  if last < first: return ""
  result = newString(int(last - first + 1))
  result.setLen(src.read(first, result.toOpenArray(0, result.high)))

proc readAll*(src: YamlSource, operation: string): string
    {.raises: [IOError, YamlMemoryLimitError].} =
  ## The whole input, for callers that need it as one string. Raises
  ## `YamlMemoryLimitError` if it does not fit into the budget next to what
  ## is reserved already; the string is not kept reserved.
  if src.tier == stInMemory:
    src.budget.reserve(src.content.len, operation)
    src.budget.release(src.content.len)
    return src.content
  var reserved = 0
  try:
    var offset = if src.tier == stSequential: src.pos else: 0
    while true:
      let want = if src.size >= 0: int(min(int64(copyChunk), src.size - offset))
                 else: copyChunk
      if want <= 0: break
      src.budget.reserve(want, operation)
      reserved += want
      let old = result.len
      result.setLen(old + want)
      let n = src.read(offset, result.toOpenArray(old, old + want - 1))
      result.setLen(old + n)
      offset += n
      if n == 0: break
  finally:
    src.budget.release(reserved)

# opening

proc sourceOf*(content: string, name = "<string>",
    budget: MemoryBudget = nil): YamlSource {.raises: [YamlMemoryLimitError].} =
  ## A source of ``content``, which is charged to ``budget``.
  result = YamlSource(tier: stInMemory, size: content.len, name: name,
      budget: budget, random: true)
  result.charge(content.len, "holding " & name)
  result.content = content

proc openSource*(read: ReadProc, size = -1'i64, name = "<callback>",
    budget: MemoryBudget = nil, randomAccess = false): YamlSource =
  ## A source that reads with ``read``: a random access one if
  ## ``randomAccess`` (``read`` gets any offset), else a sequential one.
  ## ``size`` is the size of the input, -1 if it is unknown.
  YamlSource(tier: if randomAccess: stSeekable else: stSequential,
      size: size, name: name, budget: budget, reader: read,
      random: randomAccess, pageLimit: 16 * pageSize)

proc inMemory(src: YamlSource, operation: string) =
  ## Reads the rest of a sequential source into memory.
  var content = ""
  var offset = src.pos
  while true:
    src.charge(copyChunk, operation)
    let old = content.len
    content.setLen(old + copyChunk)
    let n = src.read(offset, content.toOpenArray(old, old + copyChunk - 1))
    content.setLen(old + n)
    offset += n
    if n == 0: break
  src.budget.release(src.charged - content.len)
  src.charged = content.len
  src.content = move content
  src.tier = stInMemory
  src.size = src.content.len
  src.random = true

when hasFiles:
  proc closeFiles(src: YamlSource) =
    if src.mapped:
      if not src.winPtr.isNil and src.winPtr != src.initial:
        try: src.mem.unmapMem(src.winPtr, src.winLen)
        except OSError: discard
      try: src.mem.close()
      except OSError: discard
      src.mapped = false
    if src.ownsFile and not src.file.isNil:
      src.file.close()
      src.file = nil
    if src.spoolPath.len > 0:
      try: removeFile(src.spoolPath)
      except OSError: discard
      src.spoolPath = ""

  proc windowSize(policy: SourcePolicy, budget: MemoryBudget): int =
    let align = mapAlignment()
    result = if policy.mapWindow > 0: policy.mapWindow else: defaultWindow
    let limit = limitOf(budget)
    if limit != int.high: result = min(result, limit div 8)
    result = max(result, 2 * align)
    result = (result + align - 1) div align * align

  proc openTier(path, name: string, tier: SourceTier, size: int64,
      budget: MemoryBudget, policy: SourcePolicy): YamlSource =
    result = YamlSource(tier: tier, size: size, name: name, budget: budget,
        random: tier != stSequential)
    case tier
    of stInMemory:
      result.charge(int(size), "reading " & name & " into memory")
      result.content = readFile(path)
      result.content.setLen(int(size))
    of stMapped:
      result.window = windowSize(policy, budget)
      let first = int(min(int64(result.window), size))
      result.charge(result.window, "mapping a window of " & name)
      try:
        result.mem = memfiles.open(path, fmRead, mappedSize = first,
            allowRemap = true)
      except OSError as e:
        result.budget.release(result.charged)
        raise newException(IOError, name & ": cannot map: " & e.msg)
      result.mapped = true
      result.initial = result.mem.mem
      result.initialLen = first
    of stSeekable, stSequential:
      result.file = syncio.open(path, fmRead)
      result.ownsFile = true
      let limit = limitOf(budget)
      result.pageLimit =
        if policy.pageCache > 0: policy.pageCache
        elif limit == int.high: 1 shl 20
        else: max(pageSize, min(limit div 8, 1 shl 20))

  proc spoolName(dir: string): string =
    var n {.global.} = 0
    inc n
    (if dir.len > 0: dir else: getTempDir()) /
        ("yaml-spool-" & $getCurrentProcessId() & "-" & $n)

  proc openSource*(path: string, budget: MemoryBudget = nil,
      policy = SourcePolicy(), randomAccess = false): YamlSource

  proc spooled(src: YamlSource, policy: SourcePolicy): YamlSource =
    ## A random access source with the rest of the sequential ``src``:
    ## spooled to a file, or read into memory without a budget or with
    ## spooling off. Closes ``src`` if it was spooled.
    let operation = "reading " & src.name &
        " into memory (needs random access; it is a stream)"
    if src.budget.isNil or policy.spool == swOff:
      src.inMemory(operation & (if policy.spool == swOff:
          " and memory.spool is off" else: ""))
      return src
    let path = spoolName(policy.spoolDir)
    var f: File
    if not syncio.open(f, path, fmWrite):
      src.inMemory(operation & " and cannot be spooled to " & path)
      return src
    try:
      var buf = newString(copyChunk)
      while true:
        let n = src.read(src.pos, buf.toOpenArray(0, buf.high))
        if n == 0: break
        if f.writeBuffer(addr buf[0], n) != n:
          raise newException(IOError, path & ": cannot spool " & src.name)
    finally:
      f.close()
    var inner = policy
    inner.choice = tcAuto
    result = openSource(path, src.budget, inner)
    result.name = src.name
    result.spoolPath = path
    src.closeFiles()

  proc openSource*(path: string, budget: MemoryBudget = nil,
      policy = SourcePolicy(), randomAccess = false): YamlSource =
    ## A source of the file ``path``, of the tier ``policy`` forces or,
    ## with ``tcAuto``: memory if it takes at most a quarter of the limit of
    ## ``budget`` (always without a budget), else mapped (unless
    ## ``policy.mmap`` is off), else seekable. A forced tier is charged like
    ## any other: forced memory for a file that does not fit raises
    ## `YamlMemoryLimitError`. With ``randomAccess``, a forced stream is
    ## spooled like a pipe (see `openSource` of a ``File``).
    let size = getFileSize(path)
    let limit = limitOf(budget)
    var tier = case policy.choice
      of tcAuto:
        if size <= limit div 4: stInMemory
        elif policy.mmap != swOff: stMapped
        else: stSeekable
      of tcMemory: stInMemory
      of tcMmap: (if policy.mmap == swOff: stSeekable else: stMapped)
      of tcSeek: stSeekable
      of tcStream: stSequential
    # an empty file cannot be mapped, and is all there in memory anyway
    if size == 0 and tier == stMapped: tier = stInMemory
    result = openTier(path, path, tier, size, budget, policy)
    if randomAccess and tier == stSequential:
      result = result.spooled(policy)

  proc openSource*(f: File, name: string, budget: MemoryBudget = nil,
      policy = SourcePolicy(), randomAccess = false): YamlSource =
    ## A sequential source of the open file ``f``, like standard input or
    ## a pipe, which is not closed with the source. With ``randomAccess``,
    ## the stream is spooled to a temporary file (in ``policy.spoolDir``),
    ## which the source then reads; without a budget or with
    ## ``policy.spool`` off, it is read into memory instead, which raises
    ## `YamlMemoryLimitError` if it does not fit. Forced memory reads it
    ## into memory too.
    result = YamlSource(tier: stSequential, size: -1, name: name,
        budget: budget, file: f)
    if policy.choice == tcMemory:
      result.inMemory("reading " & name & " into memory")
    elif randomAccess:
      result = result.spooled(policy)

proc close*(src: YamlSource) =
  ## Releases what ``src`` holds: memory, mapping, file and spool file.
  src.budget.release(src.charged)
  src.charged = 0
  src.content = ""
  src.pages = @[]
  when hasFiles: src.closeFiles()

# streams

type SourceStream = ref object of StreamObj
  src: YamlSource
  pos: int64

proc ssReadData(s: Stream, buffer: pointer, bufLen: int): int =
  let ss = SourceStream(s)
  if bufLen <= 0: return 0
  {.cast(tags: []).}:
    result = ss.src.read(ss.pos,
        cast[ptr UncheckedArray[char]](buffer).toOpenArray(0, bufLen - 1))
  ss.pos += result

proc ssReadDataStr(s: Stream, buffer: var string, slice: Slice[int]): int =
  let ss = SourceStream(s)
  if slice.b < slice.a: return 0
  {.cast(tags: []).}:
    result = ss.src.read(ss.pos, buffer.toOpenArray(slice.a, slice.b))
  ss.pos += result

proc ssAtEnd(s: Stream): bool =
  let ss = SourceStream(s)
  if ss.src.size >= 0: ss.pos >= ss.src.size
  else: ss.src.ended

proc ssGetPosition(s: Stream): int = int(SourceStream(s).pos)

proc ssSetPosition(s: Stream, pos: int) =
  let ss = SourceStream(s)
  if not ss.src.random and pos != ss.pos:
    raise newException(YamlSourceError, ss.src.name &
        ": cannot seek in a stream")
  ss.pos = pos

proc newSourceStream*(src: YamlSource, offset = 0'i64): Stream
    {.raises: [IOError].} =
  ## A forward `Stream` of ``src`` from ``offset`` on. Several streams of a
  ## random access source may be read at once; a sequential source has
  ## one position, from which it skips forward to ``offset``, and raises
  ## `YamlSourceError` for an ``offset`` behind it.
  if not src.random:
    if offset < src.pos:
      raise newException(YamlSourceError, src.name &
          ": a stream can only be read from offset " & $src.pos & " on")
    var skip = newString(min(int64(copyChunk), offset - src.pos))
    while src.pos < offset:
      let want = int(min(int64(skip.len), offset - src.pos))
      if src.read(src.pos, skip.toOpenArray(0, want - 1)) == 0: break
  SourceStream(src: src, pos: offset, readDataImpl: ssReadData,
      readDataStrImpl: ssReadDataStr, atEndImpl: ssAtEnd,
      getPositionImpl: ssGetPosition, setPositionImpl: ssSetPosition)
