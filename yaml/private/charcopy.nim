#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Copying runs of characters between buffers, on every backend.
##
## The lexer, the sources and the filter streams move input in runs:
## appending fed input, shifting the unread rest of a buffer to its start,
## serving a read from a page. Natively that is ``copyMem`` and
## ``moveMem``, which matter for speed on large inputs. The JavaScript
## backend has neither, because a string there is an array of numbers and
## not memory, so there a run is copied element by element.
##
## Both procs take the run's bounds explicitly rather than slices, so that
## no backend allocates a temporary for the run.

proc copyChars*(dest: var openArray[char], destStart: int,
    src: openArray[char], srcStart, count: int) {.inline, raises: [].} =
  ## Copies ``count`` characters of ``src`` from ``srcStart`` on into
  ## ``dest`` from ``destStart`` on. The runs must not overlap.
  if count <= 0: return
  when defined(js):
    for i in 0 ..< count: dest[destStart + i] = src[srcStart + i]
  else:
    copyMem(addr dest[destStart], unsafeAddr src[srcStart], count)

proc shiftChars*(s: var string, srcStart, destStart, count: int)
    {.inline, raises: [].} =
  ## Moves ``count`` characters of ``s`` from ``srcStart`` to
  ## ``destStart``, where the runs may overlap.
  if count <= 0 or srcStart == destStart: return
  when defined(js):
    if destStart < srcStart:
      for i in 0 ..< count: s[destStart + i] = s[srcStart + i]
    else:
      for i in countdown(count - 1, 0): s[destStart + i] = s[srcStart + i]
  else:
    moveMem(addr s[destStart], addr s[srcStart], count)

proc sameChars*(a, b: openArray[char], count: int): bool
    {.inline, raises: [].} =
  ## Whether the first ``count`` characters of ``a`` and ``b`` are equal.
  if count <= 0: return true
  when defined(js):
    for i in 0 ..< count:
      if a[i] != b[i]: return false
    true
  else:
    equalMem(unsafeAddr a[0], unsafeAddr b[0], count)

# A ``Stream``'s ``readData`` and ``writeData`` receive a buffer as a
# ``pointer``: memory natively, but on JavaScript the address of a string,
# which ``std/streams`` passes for want of memory. These read the buffer of
# a ``writeData`` either way.

template streamBufferChar*(buffer: pointer, i: int): char =
  ## The character ``i`` of a stream's buffer.
  when defined(js): cast[ptr string](buffer)[][i]
  else: cast[ptr UncheckedArray[char]](buffer)[i]

proc addStreamBuffer*(s: var string, buffer: pointer, bufLen: int)
    {.inline, raises: [].} =
  ## Appends the first ``bufLen`` characters of a stream's buffer to ``s``.
  if bufLen <= 0: return
  let old = s.len
  s.setLen(old + bufLen)
  when defined(js):
    for i in 0 ..< bufLen: s[old + i] = cast[ptr string](buffer)[][i]
  else:
    copyMem(addr s[old], buffer, bufLen)

import std/streams

proc writeChars*(s: Stream, chars: string, count: int) =
  ## Writes the first ``count`` characters of ``chars``, without copying
  ## them natively. On JavaScript a stream must get a string's address,
  ## never an element's, so the run is written as a string.
  if count <= 0: return
  when defined(js): s.write(chars[0 ..< count])
  else: s.writeData(unsafeAddr chars[0], count)

when defined(js):

  proc write*(s: Stream, c: char) {.inline.} =
    ## Writes the character ``c``. std/streams writes any value through its
    ## address, which its JavaScript streams take for a string's; a char
    ## is written as a string of one instead. Being more specific than
    ## std/streams' generic ``write``, this is what a char resolves to.
    s.write($c)
