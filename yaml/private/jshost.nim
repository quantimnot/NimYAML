#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Files, standard streams and the environment on the JavaScript backend,
## from a host the embedder installs.
##
## The library and its tools read configs, schemas and inputs, and write
## outputs and caches, through ``std/os`` and ``std/syncio``. Compiled to
## JavaScript, most of that is missing: there is no ``File``, ``stdout``
## or ``fileExists``, and ``readFile`` and ``getCurrentDir`` work only
## under ``-d:nodejs``, by calling Node's ``require("fs")`` and
## ``process``, which a browser worker has neither of. A build that probes
## for its runtime would also tie the compiled code to the runtimes it
## knows. So the compiled code names no runtime at all: it asks a *host*,
## a plain JavaScript object that the embedder installs before the first
## call (`installHost`), the way the Rei runtime takes its host
## (``install(host)``) rather than detecting one.
##
## The host is synchronous, since everything above it is: a parse does not
## wait. Each method deals in bytes (``Uint8Array``), since a Nim string
## is bytes and an input may be CBOR rather than text:
##
## ============================  ============================================
## ``read(path)``                the file's bytes, or ``null`` if it is not
##                               a readable file
## ``write(path, bytes)``        replaces the file; ``false`` on failure
## ``stat(path)``                ``"file"``, ``"dir"`` or ``null``
## ``mkdir(path)``               creates the directory and its parents;
##                               ``false`` on failure
## ``mtime(path)``               when the file was last modified, in
##                               milliseconds since 1970, or ``null``
## ``remove(path)``              removes a file; ``false`` on failure
## ``rename(from, to)``          ``false`` on failure
## ``cwd()``                     the working directory, absolute
## ``env(name)``                 a variable, or ``undefined``
## ``stdin()``                   all of standard input
## ``output(fd, bytes)``         writes to standard output (1) or error (2)
## ``isatty(fd)``                whether the stream is a terminal
## ``isLink(path)``              optional: whether it is a symbolic link
## ``realpath(path)``            optional: the path with links resolved
## ``mode(path)``                optional: the permission bits, or ``null``
## ``chmod(path, mode)``         optional: sets the permission bits
## ``size(path)``                optional: the file's size, or ``null``
## ``readAt(path, offset, n)``   optional: up to ``n`` bytes of the file
##                               from ``offset``, or ``null``
## ============================  ============================================
##
## Ready-made hosts are in ``js/hosts/``: one over an in-memory map of
## files, which the language server's worker uses, and one over
## ``node:fs``, for Node, Bun and Deno.
##
## This module stands in for ``std/os`` and ``std/syncio`` together: a
## module imports it instead of them on JavaScript, and gets ``std/os``'s
## path procs unchanged and the procs above built on the host, under the
## same names and with the same errors (``IOError`` for a file that cannot
## be read, ``OSError`` for one that cannot be created or moved), so that
## the code using them is the same on every backend. A ``File`` reads the
## whole file when opened and writes it whole when flushed or closed;
## standard output and error are written at once.
##
## Rejected: ``-d:nodejs``, which works only in Node; the ``fs`` API of a
## specific runtime behind a ``when``, which the browser does not have; an
## asynchronous host, which would make every parse a promise.

when not defined(js):
  {.error: "yaml/private/jshost is the host of the JavaScript backend".}

import std/[jsffi, os, streams, strutils, times]
export os except getCurrentDir, absolutePath, getEnv, existsEnv, getTempDir,
    fileExists, dirExists, createDir, removeFile, moveFile, getFileSize,
    getLastModificationTime, getCurrentProcessId, isAbsolute, normalizedPath,
    normalizePath, relativePath, getCacheDir

var host: JsObject

proc installHost*(h: JsObject) =
  ## Installs the host every file and stream operation uses. Must be called
  ## before the first one.
  host = h

proc hostOrFail(): JsObject {.gcsafe.} =
  # A JavaScript realm has one thread, so the host is safe to share; the
  # cast says so to the effect system, which sees a global of ref type.
  {.cast(gcsafe).}:
    if host.isNil or host.isUndefined:
      raise newException(Defect, "no host installed (call installHost)")
    host

# Bytes cross the boundary as a ``Uint8Array``; a Nim string on JavaScript
# is an array of byte values.

proc fromBytes(bytes: JsObject): string =
  {.emit: [result, " = Array.from(", bytes, ");"].}

proc toBytes(s: string): JsObject =
  {.emit: [result, " = Uint8Array.from(", s, ");"].}

proc jsText(s: string): cstring = cstring(s)
  # UTF-8 bytes to a JavaScript string (paths and names)

# the file system

proc readFile*(path: string): string {.raises: [IOError].} =
  var bytes: JsObject
  {.cast(raises: []).}: bytes = hostOrFail().read(jsText(path))
  if bytes.isNil or bytes.isUndefined:
    raise newException(IOError, "cannot open: " & path)
  fromBytes(bytes)

proc writeFile*(path, content: string) {.raises: [IOError].} =
  var ok: bool
  {.cast(raises: []).}:
    ok = hostOrFail().write(jsText(path), toBytes(content)).to(bool)
  if not ok: raise newException(IOError, "cannot write: " & path)

proc kindOf(path: string): cstring =
  {.cast(raises: []).}:
    let kind = hostOrFail().stat(jsText(path))
    if kind.isNil or kind.isUndefined: cstring"" else: kind.to(cstring)

proc fileExists*(path: string): bool = kindOf(path) == "file"
proc dirExists*(path: string): bool = kindOf(path) == "dir"

proc hostHas(name: cstring): bool =
  {.cast(raises: []).}:
    let h = hostOrFail()
    var has = false
    {.emit: [has, " = typeof ", h, "[", name, "] === 'function';"].}
    has

# Reading a file in ranges is optional too (``size``, ``readAt``): with
# it, a file too large to hold in memory is read by seeking, as natively;
# without it, every file is read whole.

proc hostCanSeek*(): bool =
  ## Whether the host reads files in ranges.
  hostHas("size") and hostHas("readAt")

proc getFileSize*(path: string): BiggestInt {.raises: [IOError].} =
  if hostCanSeek():
    var size: JsObject
    {.cast(raises: []).}: size = hostOrFail().size(jsText(path))
    if size.isNil or size.isUndefined:
      raise newException(IOError, "cannot open: " & path)
    return BiggestInt(size.to(float))
  readFile(path).len

proc readAt*(path: string, offset: int64, dest: var openArray[char]): int
    {.raises: [IOError].} =
  ## Reads up to ``dest.len`` bytes of the file at ``offset`` into ``dest``
  ## and returns their number; needs `hostCanSeek`.
  var bytes: JsObject
  {.cast(raises: []).}:
    bytes = hostOrFail().readAt(jsText(path), float(offset), dest.len)
  if bytes.isNil or bytes.isUndefined:
    raise newException(IOError, "cannot read: " & path)
  let got = fromBytes(bytes)
  for i in 0 ..< got.len: dest[i] = got[i]
  got.len

# Links and permissions are optional methods of a host (``isLink``,
# ``realpath``, ``mode``, ``chmod``; see the table above): a host over a
# real file system has them, so that writing a file in place keeps its link
# and its mode, as natively; a host without them has neither, a path names
# its file, and replacing a file keeps nothing of it but its name.

proc symlinkExists*(path: string): bool =
  if not hostHas("isLink"): return false
  {.cast(raises: []).}: hostOrFail().isLink(jsText(path)).to(bool)

proc expandFilename*(path: string): string =
  if hostHas("realpath"):
    {.cast(raises: []).}:
      let real = hostOrFail().realpath(jsText(path))
      if not real.isNil and not real.isUndefined: return $real.to(cstring)
  absolutePath(path)

const permissionBits = [(fpUserRead, 0o400), (fpUserWrite, 0o200),
    (fpUserExec, 0o100), (fpGroupRead, 0o40), (fpGroupWrite, 0o20),
    (fpGroupExec, 0o10), (fpOthersRead, 0o4), (fpOthersWrite, 0o2),
    (fpOthersExec, 0o1)]

proc getFilePermissions*(path: string): set[FilePermission] =
  if not hostHas("mode"): return {}
  var mode: JsObject
  {.cast(raises: []).}: mode = hostOrFail().mode(jsText(path))
  if mode.isNil or mode.isUndefined: return {}
  let bits = mode.to(int)
  for (permission, bit) in permissionBits:
    if (bits and bit) != 0: result.incl(permission)

proc setFilePermissions*(path: string, permissions: set[FilePermission]) =
  if not hostHas("chmod"): return
  var bits = 0
  for (permission, bit) in permissionBits:
    if permission in permissions: bits = bits or bit
  {.cast(raises: []).}: discard hostOrFail().chmod(jsText(path), bits)

proc getLastModificationTime*(path: string): Time {.raises: [OSError].} =
  var millis: JsObject
  {.cast(raises: []).}: millis = hostOrFail().mtime(jsText(path))
  if millis.isNil or millis.isUndefined:
    raise newException(OSError, "cannot stat: " & path)
  let ms = int64(millis.to(float))
  initTime(ms div 1000, (ms mod 1000) * 1_000_000)

proc createDir*(path: string) {.raises: [OSError].} =
  if path.len == 0 or dirExists(path): return
  var ok: bool
  {.cast(raises: []).}: ok = hostOrFail().mkdir(jsText(path)).to(bool)
  if not ok: raise newException(OSError, "cannot create directory: " & path)

proc removeFile*(path: string) {.raises: [OSError].} =
  ## Like ``std/os``: a file that does not exist is no error.
  if not fileExists(path): return
  var ok: bool
  {.cast(raises: []).}: ok = hostOrFail().remove(jsText(path)).to(bool)
  if not ok: raise newException(OSError, "cannot remove: " & path)

proc moveFile*(source, dest: string) {.raises: [OSError].} =
  var ok: bool
  {.cast(raises: []).}:
    ok = hostOrFail().rename(jsText(source), jsText(dest)).to(bool)
  if not ok:
    raise newException(OSError, "cannot move " & source & " to " & dest)

# paths
#
# A host's paths are POSIX paths. std/os decides whether a path is absolute
# by the operating system it was compiled for, and on JavaScript, which is
# none of them, gives up (``raiseAssert "unreachable"``) unless it may call
# Node's ``path`` module; every proc that asks, like `relativePath`, fails
# with it. So these are defined here, for POSIX paths.

proc isAbsolute*(path: string): bool = path.len > 0 and path[0] == '/'

proc normalizedPath*(path: string): string =
  ## ``path`` without empty and ``.`` segments, and with each ``..`` taking
  ## away the segment before it, where there is one.
  var parts: seq[string]
  for part in path.split('/'):
    if part.len == 0 or part == ".": continue
    if part == ".." and parts.len > 0 and parts[^1] != "..": parts.setLen(parts.len - 1)
    elif part == ".." and path.isAbsolute: discard
    else: parts.add(part)
  result = (if path.isAbsolute: "/" else: "") & parts.join("/")
  if result.len == 0: result = "."

proc normalizePath*(path: var string) = path = normalizedPath(path)

proc getCurrentDir*(): string

proc relativePath*(path, base: string, sep = '/'): string =
  ## ``path`` relative to the directory ``base``; both are made absolute
  ## against the working directory first.
  if base.len == 0: return path
  let
    cwd = getCurrentDir()
    p = normalizedPath(if path.isAbsolute: path else: cwd & "/" & path).split('/')
    b = normalizedPath(if base.isAbsolute: base else: cwd & "/" & base).split('/')
  var common = 0
  while common < p.len and common < b.len and p[common] == b[common]:
    inc(common)
  var parts: seq[string]
  for _ in common ..< b.len:
    if b[^1].len > 0: parts.add("..")
  for i in common ..< p.len:
    if p[i].len > 0: parts.add(p[i])
  result = parts.join($sep)
  if result.len == 0: result = "."

# the environment

proc getCurrentDir*(): string =
  {.cast(raises: []).}: $hostOrFail().cwd().to(cstring)

proc absolutePath*(path: string, root = getCurrentDir()): string =
  if path.isAbsolute: path else: normalizedPath(root / path)

proc getEnv*(key: string, default = ""): string =
  {.cast(raises: []).}:
    let value = hostOrFail().env(jsText(key))
    if value.isNil or value.isUndefined: default else: $value.to(cstring)

proc existsEnv*(key: string): bool =
  {.cast(raises: []).}:
    not hostOrFail().env(jsText(key)).isUndefined

proc getCacheDir*(): string =
  ## The XDG cache directory of the host's environment, as std/os has it
  ## on POSIX; std/os's own reads the environment through Node.
  result = getEnv("XDG_CACHE_HOME")
  if result.len == 0: result = getEnv("HOME", "/") / ".cache"

proc getCacheDir*(app: string): string = getCacheDir() / app

proc getCurrentProcessId*(): int =
  ## Always 0. Callers name temporary files with it so that two processes
  ## sharing a directory do not collide; the files of a host belong to one
  ## realm, which is one thread of one process.
  0

proc getTempDir*(): string =
  ## ``TMPDIR`` if the host has one, else ``/tmp``; an in-memory host has
  ## whatever directories its files name.
  result = getEnv("TMPDIR", "/tmp")
  if not result.endsWith('/'): result.add('/')

# files

type
  FileObj = object
    path: string
    fd: int        ## 0, 1 or 2 for the standard streams; -1 for a file
    mode: FileMode
    data: string   ## the content read, or what is to be written
    loaded: bool   ## standard input is read on first use
    pos: int
    dirty, closed: bool

  File* = ref FileObj

let standardFiles = [File(fd: 0, mode: fmRead), File(fd: 1, mode: fmAppend),
    File(fd: 2, mode: fmAppend)]

proc standardFile(fd: int): File {.gcsafe.} =
  # the standard streams are globals, which code marked gcsafe uses, as
  # natively; see `hostOrFail` for why that is safe here
  {.cast(gcsafe).}: standardFiles[fd]

template stdin*: File = standardFile(0)
template stdout*: File = standardFile(1)
template stderr*: File = standardFile(2)

proc load(f: File) =
  if f.loaded: return
  f.loaded = true
  if f.fd == 0:
    {.cast(raises: []).}:
      let bytes = hostOrFail().stdin()
      if not bytes.isNil and not bytes.isUndefined: f.data = fromBytes(bytes)

proc open*(f: var File, path: string, mode = fmRead, bufSize = -1): bool =
  f = File(path: path, fd: -1, mode: mode, loaded: true)
  case mode
  of fmRead, fmReadWriteExisting:
    try: f.data = readFile(path)
    except IOError: return false
  of fmAppend, fmReadWrite:
    try: f.data = readFile(path)
    except IOError: discard
    if mode == fmAppend: f.pos = f.data.len
    f.dirty = true
  of fmWrite:
    f.dirty = true
  true

proc open*(path: string, mode = fmRead, bufSize = -1): File
    {.raises: [IOError].} =
  if not open(result, path, mode, bufSize):
    raise newException(IOError, "cannot open: " & path)

proc flushFile*(f: File) {.raises: [IOError].} =
  if f.fd < 0 and f.dirty and f.mode != fmRead:
    writeFile(f.path, f.data)
    f.dirty = false

proc close*(f: File) {.raises: [IOError].} =
  if f.isNil or f.closed or f.fd >= 0: return
  f.flushFile()
  f.closed = true

proc write*(f: File, s: string) {.raises: [IOError].} =
  if s.len == 0: return
  if f.fd == 1 or f.fd == 2:
    {.cast(raises: []).}: discard hostOrFail().output(f.fd, toBytes(s))
    return
  if f.mode == fmRead: raise newException(IOError, "file not open for writing")
  if f.pos + s.len > f.data.len: f.data.setLen(f.pos + s.len)
  for i in 0 ..< s.len: f.data[f.pos + i] = s[i]
  f.pos += s.len
  f.dirty = true

proc write*(f: File, args: varargs[string, `$`]) {.raises: [IOError].} =
  for a in args: f.write(a)

proc writeLine*(f: File, args: varargs[string, `$`]) {.raises: [IOError].} =
  for a in args: f.write(a)
  f.write("\n")

proc readAll*(f: File): string {.raises: [IOError].} =
  f.load()
  result = f.data[f.pos .. ^1]
  f.pos = f.data.len

proc endOfFile*(f: File): bool =
  f.load()
  f.pos >= f.data.len

proc readLine*(f: File, line: var string): bool {.raises: [IOError].} =
  f.load()
  if f.pos >= f.data.len: return false
  line.setLen(0)
  while f.pos < f.data.len and f.data[f.pos] != '\l':
    if f.data[f.pos] != '\c' or f.pos + 1 >= f.data.len or
        f.data[f.pos + 1] != '\l':
      line.add(f.data[f.pos])
    inc(f.pos)
  if f.pos < f.data.len: inc(f.pos)
  true

proc readLine*(f: File): string {.raises: [IOError, EOFError].} =
  if not f.readLine(result): raise newException(EOFError, "end of file")

proc setFilePos*(f: File, pos: int64) =
  f.load()
  f.pos = int(pos)

proc readChars*(f: File, a: var openArray[char]): int {.raises: [IOError].} =
  f.load()
  result = min(a.len, f.data.len - f.pos)
  for i in 0 ..< result: a[i] = f.data[f.pos + i]
  f.pos += result

proc isatty*(f: File): bool =
  if f.fd < 0: return false
  {.cast(raises: []).}: hostOrFail().isatty(f.fd).to(bool)

# file streams

type FileStream* = ref object of StreamObj
  f: File

proc fsClose(s: Stream) = FileStream(s).f.close()
proc fsFlush(s: Stream) = FileStream(s).f.flushFile()
proc fsAtEnd(s: Stream): bool = FileStream(s).f.endOfFile()

proc fsReadDataStr(s: Stream, buffer: var string, slice: Slice[int]): int =
  let f = FileStream(s).f
  f.load()
  result = min(slice.b - slice.a + 1, f.data.len - f.pos)
  for i in 0 ..< result: buffer[slice.a + i] = f.data[f.pos + i]
  f.pos += result

proc fsReadData(s: Stream, buffer: pointer, bufLen: int): int =
  # std/streams passes the address of a string on JavaScript
  fsReadDataStr(s, cast[ptr string](buffer)[], 0 ..< bufLen)

proc fsWriteData(s: Stream, buffer: pointer, bufLen: int) =
  FileStream(s).f.write(cast[ptr string](buffer)[][0 ..< bufLen])

proc fsGetPosition(s: Stream): int = FileStream(s).f.pos
proc fsSetPosition(s: Stream, pos: int) = FileStream(s).f.pos = pos

proc newFileStream*(f: File): FileStream =
  FileStream(f: f, closeImpl: fsClose, flushImpl: fsFlush, atEndImpl: fsAtEnd,
      readDataStrImpl: fsReadDataStr, readDataImpl: fsReadData,
      writeDataImpl: fsWriteData, getPositionImpl: fsGetPosition,
      setPositionImpl: fsSetPosition)

proc newFileStream*(path: string, mode = fmRead, bufSize = -1): FileStream =
  ## ``nil`` if the file cannot be opened, like ``std/streams``.
  var f: File
  if open(f, path, mode, bufSize): newFileStream(f) else: nil

proc openFileStream*(path: string, mode = fmRead, bufSize = -1): FileStream
    {.raises: [IOError].} =
  newFileStream(open(path, mode, bufSize))
