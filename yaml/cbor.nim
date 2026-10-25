#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ================
## Module yaml/cbor
## ================
##
## This module reads and writes CBOR, the Concise Binary Object
## Representation (`RFC 8949 <https://www.rfc-editor.org/rfc/rfc8949>`_).
## CBOR is translated from and to a `YamlStream`_, so it can be loaded into
## and dumped from native Nim values and the DOM, and converted from and to
## YAML and JSON.
##
## A CBOR data item is a YAML document. Input holding several data items one
## after another, a CBOR sequence
## (`RFC 8742 <https://www.rfc-editor.org/rfc/rfc8742>`_), is a stream of
## several documents.
##
## Reading CBOR
## ============
##
## `parseCbor`_ yields the following events for CBOR data items:
##
## ================================ ==========================================
## CBOR                             Event
## ================================ ==========================================
## unsigned and negative integer    scalar with tag ``?``, in decimal
## tag 2 and 3 (bignums)            scalar with tag ``?``, in decimal
## float (half, single, double)     scalar with tag ``?``: shortest decimal
##                                  form, ``.inf``, ``-.inf`` or ``.nan``
## ``false``, ``true``              scalar ``false``, ``true`` with tag ``?``
## ``null``, ``undefined``          scalar ``null`` with tag ``?``
## text string                      scalar with tag ``!``
## byte string                      scalar with tag ``!!binary``, in base64
## tag 0 (date/time string)         scalar with tag ``!!timestamp``
## tag 1 (epoch-based date/time)    scalar with tag ``!!timestamp``, in UTC
## array                            sequence with tag ``?``
## map                              mapping with tag ``?``
## tag 28 (shareable)               anchor on the enclosed node
## tag 29 (shared reference)        alias of the anchor
## tags 21 to 24, 32 to 36, 55799   their enclosed item; the tag is dropped
## any other tag *N*                its enclosed item with the tag
##                                  ``tag:nimyaml.org,2016:cbor:N``; a text
##                                  string gets the double-quoted style, a
##                                  byte string the tag
##                                  ``tag:nimyaml.org,2016:cbor:N:binary``
## ================================ ==========================================
##
## Scalars that are not strings thus get the non-specific tag ``?`` and
## content which the YAML core schema resolves to their type, so they load
## into Nim values like their YAML counterparts. Anchors are named ``s0``,
## ``s1``, … in the order of their shareable tags in the data item.
##
## Input that is not well-formed CBOR, or a text string that is not UTF-8,
## raises `YamlCborError`_. Its ``mark`` has ``line`` 1 and the byte offset
## of the error plus one as ``column``.
##
## Writing CBOR
## ============
##
## `presentCbor`_ writes the preferred serialization of RFC 8949: arguments,
## lengths and floats take the fewest bytes that keep their value, and
## arrays and maps have definite lengths. Scalars are written as follows:
##
## * a scalar with the tag ``?`` is resolved by the YAML core schema: plain
##   integers, floats, booleans and nulls are written as such, all other
##   scalars (also quoted ones) as text strings
## * a scalar with the tag ``!``, ``!!str`` or the char tag of NimYAML is a
##   text string
## * ``!!int``, ``!!float``, ``!!bool``, ``!!null`` and the integer and float
##   tags of NimYAML must hold a scalar of their type. Integers may be
##   written in decimal, with ``0x`` in hexadecimal or with ``0o`` in octal;
##   those beyond the 64 bits of CBOR integers are bignums.
## * ``!!binary`` holds base64, which is written as byte string
## * ``!!timestamp`` is a text string, with tag 0 if it is an RFC 3339
##   date/time and with tag 1004 (RFC 8943) if it is a date
## * ``tag:nimyaml.org,2016:cbor:N`` writes tag *N* before its node, which
##   is then written as though it had the tag ``?``, or ``!`` if it is a
##   quoted scalar. ``tag:nimyaml.org,2016:cbor:N:binary`` writes tag *N*
##   before a byte string.
## * any other tag is dropped and its scalar written as text string
##
## An anchored node is enclosed in tag 28 and an alias is written as tag 29.
## Data that cannot be written as CBOR raises `YamlPresenterCborError`_.

import std / [base64, formatfloat, math, streams, strutils, tables, times, unicode]
import data, stream, hints, native, parser, presenter, dumping, taglib,
    private/internal, memory
export data, stream, native, dumping

type
  YamlCborError* = object of YamlLoadingError
    ## Raised for input that is not well-formed CBOR, or that cannot be
    ## translated to a `YamlStream`_.

  YamlPresenterCborError* = object of ValueError
    ## Raised when a `YamlStream`_ cannot be written as CBOR.

const
  cborTagPrefix* = nimyamlTagRepositoryPrefix & "cbor:"
    ## prefix of the YAML tags of CBOR tags without a YAML counterpart.
    ## ``cborTagPrefix & "42"`` is CBOR tag 42.

proc cborTag*(number: uint64): Tag =
  ## the YAML tag of the CBOR tag ``number``
  Tag(cborTagPrefix & $number)

# Unsigned big integers as big-endian bytes
# -----------------------------------------

proc trimmed(n: seq[byte]): seq[byte] =
  var i = 0
  while i < n.len - 1 and n[i] == 0: inc i
  n[i .. ^1]

proc mulAdd(n: var seq[byte], factor, summand: int) =
  var carry = summand
  for i in countdown(n.len - 1, 0):
    let v = int(n[i]) * factor + carry
    n[i] = byte(v and 0xff)
    carry = v shr 8
  while carry > 0:
    n.insert(byte(carry and 0xff), 0)
    carry = carry shr 8

proc increment(n: var seq[byte]) = n.mulAdd(1, 1)

proc decrement(n: var seq[byte]) =
  ## ``n`` must not be zero
  var i = n.len - 1
  while n[i] == 0:
    n[i] = 0xff
    dec i
  dec n[i]
  n = trimmed(n)

proc toDecimal(n: seq[byte]): string =
  var n = trimmed(n)
  if n.len == 0: return "0"
  while n.len > 1 or n[0] != 0:
    var rest = 0
    for i in 0 ..< n.len:
      let v = rest * 256 + int(n[i])
      n[i] = byte(v div 10)
      rest = v mod 10
    result.add(char(ord('0') + rest))
    n = trimmed(n)
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.len - 1 - i])

proc toUint64(n: seq[byte], value: var uint64): bool =
  let n = trimmed(n)
  if n.len > 8: return false
  value = 0
  for b in n: value = (value shl 8) or uint64(b)
  true

# Reading
# -------

type
  FrameKind = enum
    fkArray, fkMap

  Frame = object
    kind: FrameKind
    remaining: uint64 ## items left of a definite-length collection
    indefinite: bool
    count: uint64 ## items read of an indefinite-length collection

  ReaderState = enum
    rsStreamStart, rsBetween, rsContent, rsDocEnd, rsDone

  Head = object
    major: int
    info: int
    arg: uint64
    indefinite: bool

  CborYamlStream = ref object of YamlStream
    input: string   # all input, or a window of a stream
    base: int       # offset of input[0]
    pos: int        # offset of the next byte
    total: int      # size of all input; -1 for a stream
    stream: Stream  # nil for string input
    budget: MemoryBudget
    charged: int    # window length the budget is charged for
    state: ReaderState
    stack: seq[Frame]
    sharedCount: int

proc mark(pos: int): Mark = Mark(line: 1, column: pos + 1)

proc cborError(pos: int, msg: string): ref YamlCborError =
  (ref YamlCborError)(msg: msg, mark: mark(pos))

proc sharedAnchor(index: uint64): Anchor = Anchor("s" & $index)

const cborChunk = 65536

proc fill(c: CborYamlStream, n: int): bool =
  ## Whether the next ``n`` bytes are in the window, reading them from the
  ## stream if they are not; false at the end of the input. The window is
  ## charged to the budget, so a string larger than it raises
  ## `YamlMemoryLimitError`.
  if c.pos - c.base + n <= c.input.len: return true
  if c.stream.isNil: return false
  let consumed = c.pos - c.base
  if consumed > 0:
    c.input.delete(0 ..< consumed)
    c.base = c.pos
  let want = max(n - c.input.len, cborChunk)
  if c.input.len + want > c.charged:
    c.budget.reserve(c.input.len + want - c.charged, "reading CBOR input")
    c.charged = c.input.len + want
  let old = c.input.len
  c.input.setLen(old + want)
  var got = 0
  while got < want:
    let r = c.stream.readDataStr(c.input, old + got ..< old + want)
    if r <= 0: break
    got += r
  c.input.setLen(old + got)
  if c.charged > c.input.len + cborChunk:
    c.budget.release(c.charged - c.input.len - cborChunk)
    c.charged = c.input.len + cborChunk
  c.pos - c.base + n <= c.input.len

proc atByte(c: CborYamlStream, b: char): bool =
  ## Whether the next byte is ``b``.
  c.fill(1) and c.input[c.pos - c.base] == b

proc readByte(c: CborYamlStream): byte =
  if not c.fill(1):
    raise cborError(c.pos, "unexpected end of CBOR input")
  result = byte(c.input[c.pos - c.base])
  inc c.pos

proc readBytes(c: CborYamlStream, len: uint64): string =
  if (c.total >= 0 and len > uint64(c.total - c.pos)) or
      len > uint64(int.high div 2) or not c.fill(int(len)):
    raise cborError(c.pos, "unexpected end of CBOR input")
  let start = c.pos - c.base
  result = c.input[start ..< start + int(len)]
  c.pos += int(len)

proc readHead(c: CborYamlStream): Head =
  let
    start = c.pos
    b = c.readByte()
  result = Head(major: int(b shr 5), info: int(b and 0x1f))
  case result.info
  of 0 .. 23: result.arg = uint64(result.info)
  of 24 .. 27:
    for _ in 1 .. 1 shl (result.info - 24):
      result.arg = (result.arg shl 8) or uint64(c.readByte())
  of 28 .. 30:
    raise cborError(start, "reserved additional information " & $result.info)
  else:
    if result.major in [0, 1, 6]:
      raise cborError(start, "indefinite length is not allowed for major type " &
          $result.major)
    result.indefinite = true

proc readString(c: CborYamlStream, head: Head): string =
  ## reads the content of a byte or text string whose head has been read
  if not head.indefinite: return c.readBytes(head.arg)
  while true:
    let start = c.pos
    if c.atByte('\xff'):
      inc c.pos
      break
    let chunk = c.readHead()
    if chunk.major != head.major or chunk.indefinite:
      raise cborError(start, "chunk of an indefinite-length string must be a " &
          "definite-length string of the same type")
    result.add(c.readBytes(chunk.arg))

proc ldexp(x: float64, e: int): float64 =
  ## ``x`` times two to the power of ``e``, exact for the exponents used here
  x * pow(2.0, float64(e))

proc halfToFloat(h: uint16): float64 =
  let
    exp = int((h shr 10) and 0x1f)
    mant = float64(h and 0x3ff)
  result =
    if exp == 0: ldexp(mant, -24)
    elif exp == 31: (if mant == 0: Inf else: NaN)
    else: ldexp(mant + 1024, exp - 25)
  if (h and 0x8000) != 0: result = -result

proc floatContent(x: float64): string =
  if x.isNaN: ".nan"
  elif x == Inf: ".inf"
  elif x == NegInf: "-.inf"
  else: $x

proc timestampContent(seconds: float64, pos: int): string =
  if seconds.isNaN or seconds.abs > 253402300799.0:
    raise cborError(pos, "epoch-based date/time is out of range")
  var
    whole = int64(floor(seconds))
    nanos = int(round((seconds - float64(whole)) * 1e9))
  if nanos >= 1_000_000_000:
    inc whole
    nanos -= 1_000_000_000
  let t = initTime(whole, nanos).utc
  result = t.format("yyyy-MM-dd'T'HH:mm:ss")
  if nanos > 0:
    result.add('.' & align($nanos, 9, '0').strip(leading = false, chars = {'0'}))
  result.add('Z')

proc isStyleQuoted(style: ScalarStyle): bool =
  style in {ssSingleQuoted, ssDoubleQuoted, ssLiteral, ssFolded}

proc readItem(c: CborYamlStream, e: var Event) =
  let start = c.pos
  var
    anchor = yAnchorNone
    custom = 0'u64
    hasCustom = false
    semantic = -1 # tag 0, 1, 2 or 3
    head: Head
  while true:
    let tagStart = c.pos
    head = c.readHead()
    if head.major != 6: break
    case head.arg
    of 28:
      if anchor != yAnchorNone:
        raise cborError(tagStart, "nested shareable tags")
      anchor = sharedAnchor(uint64(c.sharedCount))
      inc c.sharedCount
    of 29:
      let index = c.readHead()
      if index.major != 0:
        raise cborError(tagStart, "shared reference must enclose an unsigned integer")
      if index.arg >= uint64(c.sharedCount):
        raise cborError(tagStart, "shared reference to a value that is not shared")
      if anchor != yAnchorNone or hasCustom or semantic >= 0:
        raise cborError(start, "tag on a shared reference")
      e = aliasEvent(sharedAnchor(index.arg), mark(start), mark(c.pos))
      return
    of 0, 1, 2, 3:
      if semantic >= 0 or hasCustom:
        raise cborError(tagStart, "nested tags are not supported")
      semantic = int(head.arg)
    of 21 .. 24, 32 .. 36, 55799: discard
    else:
      if semantic >= 0 or hasCustom:
        raise cborError(tagStart, "nested tags are not supported")
      custom = head.arg
      hasCustom = true

  template tagOr(default: Tag): Tag =
    if hasCustom: cborTag(custom) else: default
  template expect(cond: bool) =
    if not cond:
      raise cborError(start, "tag " & $semantic & " must enclose " &
          (case semantic
           of 0: "a text string"
           of 1: "a number"
           else: "a byte string"))
  template scalar(content: string, tag: Tag, style = ssAny) =
    e = scalarEvent(content, (anchor, tag), style, mark(start), mark(c.pos))

  case head.major
  of 0:
    expect(semantic in [-1, 1])
    if semantic == 1:
      if head.arg > 253402300799'u64:
        raise cborError(start, "epoch-based date/time is out of range")
      scalar(timestampContent(float64(head.arg), start), yTagTimestamp)
    else: scalar($head.arg, tagOr(yTagQuestionMark))
  of 1:
    expect(semantic in [-1, 1])
    let content =
      if head.arg == high(uint64): "-18446744073709551616"
      else: "-" & $(head.arg + 1)
    if semantic == 1:
      scalar(timestampContent(parseFloat(content), start), yTagTimestamp)
    else: scalar(content, tagOr(yTagQuestionMark))
  of 2:
    let bytes = c.readString(head)
    case semantic
    of 2, 3:
      var n = newSeq[byte](bytes.len)
      for i, b in bytes: n[i] = byte(b)
      if semantic == 3: n.increment()
      scalar((if semantic == 3: "-" else: "") & toDecimal(n), yTagQuestionMark)
    of -1:
      scalar(base64.encode(bytes),
          if hasCustom: Tag($cborTag(custom) & ":binary") else: yTagBinary)
    else: expect(false)
  of 3:
    expect(semantic in [-1, 0])
    let text = c.readString(head)
    let invalid = validateUtf8(text)
    if invalid >= 0:
      raise cborError(start, "text string is not valid UTF-8")
    if semantic == 0: scalar(text, yTagTimestamp)
    elif hasCustom: scalar(text, cborTag(custom), ssDoubleQuoted)
    else: scalar(text, yTagExclamationMark)
  of 4, 5:
    expect(semantic == -1)
    let kind = if head.major == 4: fkArray else: fkMap
    if not head.indefinite:
      # every item takes at least one byte
      if c.total >= 0 and head.arg > uint64(c.total - c.pos):
        raise cborError(start, "unexpected end of CBOR input")
    c.stack.add(Frame(kind: kind, indefinite: head.indefinite,
        remaining: if kind == fkMap: head.arg * 2 else: head.arg))
    let props = (anchor, tagOr(yTagQuestionMark))
    e = if kind == fkArray: startSeqEvent(csAny, props, mark(start), mark(c.pos))
        else: startMapEvent(csAny, props, mark(start), mark(c.pos))
  else:
    var value: float64
    case head.info
    of 20, 21:
      expect(semantic == -1)
      scalar(if head.info == 21: "true" else: "false", tagOr(yTagQuestionMark))
      return
    of 22, 23:
      expect(semantic == -1)
      scalar("null", tagOr(yTagQuestionMark))
      return
    of 25: value = halfToFloat(uint16(head.arg))
    of 26: value = float64(cast[float32](uint32(head.arg)))
    of 27: value = cast[float64](head.arg)
    of 31: raise cborError(start, "unexpected break")
    else: raise cborError(start, "unassigned simple value")
    expect(semantic in [-1, 1])
    if semantic == 1: scalar(timestampContent(value, start), yTagTimestamp)
    else: scalar(floatContent(value), tagOr(yTagQuestionMark))

proc cborNext(s: YamlStream, e: var Event): bool {.raises: [CatchableError].} =
  let c = CborYamlStream(s)
  result = true
  case c.state
  of rsStreamStart:
    e = startStreamEvent()
    c.state = rsBetween
  of rsBetween:
    if not c.fill(1):
      e = endStreamEvent()
      c.state = rsDone
      c.budget.release(c.charged)
      c.charged = 0
    else:
      e = startDocEvent(startPos = mark(c.pos), endPos = mark(c.pos))
      c.sharedCount = 0
      c.state = rsContent
  of rsContent:
    if c.stack.len > 0:
      var ended = false
      if c.stack[^1].indefinite:
        if c.atByte('\xff'):
          if c.stack[^1].kind == fkMap and c.stack[^1].count mod 2 == 1:
            raise cborError(c.pos, "map ends after a key without a value")
          inc c.pos
          ended = true
        else: inc c.stack[^1].count
      elif c.stack[^1].remaining == 0: ended = true
      else: dec c.stack[^1].remaining
      if ended:
        let kind = c.stack.pop().kind
        e = if kind == fkArray: endSeqEvent(mark(c.pos), mark(c.pos))
            else: endMapEvent(mark(c.pos), mark(c.pos))
        if c.stack.len == 0: c.state = rsDocEnd
        return
    c.readItem(e)
    if c.stack.len == 0: c.state = rsDocEnd
  of rsDocEnd:
    e = endDocEvent(startPos = mark(c.pos), endPos = mark(c.pos))
    c.state = rsBetween
  of rsDone:
    e = endStreamEvent()

proc parseCbor*(input: string): YamlStream {.raises: [].} =
  ## Returns the events of the CBOR data items in ``input``, which holds
  ## bytes. The stream raises a `YamlStreamError`_ whose ``parent`` is a
  ## `YamlCborError`_ for input that is not well-formed CBOR.
  let c = CborYamlStream(input: input, total: input.len)
  c.basicInit()
  c.nextImpl = cborNext
  result = c

proc parseCbor*(input: Stream, budget: MemoryBudget = nil): YamlStream
    {.raises: [].} =
  ## Returns the events of the CBOR data items in ``input``, which is read
  ## in chunks as the events are pulled, so that input of any size can be
  ## decoded. ``budget`` is charged for the window of input held, which
  ## must hold every byte or text string whole: a larger one raises a
  ## `YamlStreamError`_ whose ``parent`` is a `YamlMemoryLimitError`.
  let c = CborYamlStream(total: -1, stream: input, budget: budget)
  c.basicInit()
  c.nextImpl = cborNext
  result = c

# Writing
# -------

proc cborWriteError(msg: string): ref YamlPresenterCborError =
  newException(YamlPresenterCborError, msg)

proc addHead(buf: var string, major: int, arg: uint64) =
  let m = major shl 5
  if arg < 24:
    buf.add(char(m or int(arg)))
    return
  let size =
    if arg <= 0xff: 0
    elif arg <= 0xffff: 1
    elif arg <= 0xffff_ffff'u64: 2
    else: 3
  buf.add(char(m or (24 + size)))
  for i in countdown((1 shl size) - 1, 0):
    buf.add(char((arg shr (8 * i)) and 0xff))

proc addFloat(buf: var string, x: float64) =
  if x.isNaN:
    buf.add("\xf9\x7e\x00")
    return
  let single = float32(x)
  if float64(single) != x:
    buf.add('\xfb')
    let bits = cast[uint64](x)
    for i in countdown(7, 0): buf.add(char((bits shr (8 * i)) and 0xff))
    return
  # try half precision
  let
    bits = cast[uint32](single)
    sign = uint16((bits shr 16) and 0x8000)
    exp = int((bits shr 23) and 0xff) - 127
    mant = bits and 0x7fffff
  var half = -1
  if x == 0 or x.classify in {fcInf, fcNegInf}:
    half = int(sign or (if x == 0: 0'u16 else: 0x7c00'u16))
  elif exp in -14 .. 15 and (mant and 0x1fff) == 0:
    half = int(sign or uint16((exp + 15) shl 10) or uint16(mant shr 13))
  elif exp in -24 .. -15:
    let m = ldexp(abs(x), 24)
    if m == floor(m) and m < 1024: half = int(sign or uint16(m))
  if half >= 0 and halfToFloat(uint16(half)) == x:
    buf.add('\xf9')
    buf.add(char(half shr 8))
    buf.add(char(half and 0xff))
  else:
    buf.add('\xfa')
    for i in countdown(3, 0): buf.add(char((bits shr (8 * i)) and 0xff))

proc addInteger(buf: var string, content: string): bool =
  ## writes the YAML integer ``content``; ``false`` if it is none
  var
    i = 0
    negative = false
    base = 10
  if i < content.len and content[i] in {'-', '+'}:
    negative = content[i] == '-'
    inc i
  if i + 1 < content.len and content[i] == '0' and content[i + 1] in {'x', 'o'}:
    base = if content[i + 1] == 'x': 16 else: 8
    i += 2
  if i >= content.len: return false
  var magnitude = @[0'u8]
  for c in content[i .. ^1]:
    let digit =
      case c
      of '0' .. '9': ord(c) - ord('0')
      of 'a' .. 'f': ord(c) - ord('a') + 10
      of 'A' .. 'F': ord(c) - ord('A') + 10
      else: 99
    if digit >= base: return false
    magnitude.mulAdd(base, digit)
  magnitude = trimmed(magnitude)
  # -0 is 0
  negative = negative and (magnitude.len > 1 or magnitude[0] != 0)
  if negative: magnitude.decrement()
  var value: uint64
  if magnitude.toUint64(value):
    buf.addHead(if negative: 1 else: 0, value)
  else:
    buf.addHead(6, if negative: 3 else: 2)
    buf.addHead(2, uint64(magnitude.len))
    for b in magnitude: buf.add(char(b))
  true

proc addText(buf: var string, text: string) =
  if validateUtf8(text) >= 0:
    raise cborWriteError("string is not valid UTF-8: " & escape(text))
  buf.addHead(3, uint64(text.len))
  buf.add(text)

proc isDigits(s: string, first, last: int): bool =
  if last >= s.len: return false
  for i in first .. last:
    if s[i] notin Digits: return false
  true

proc isFullDate(s: string): bool =
  s.len == 10 and s.isDigits(0, 3) and s[4] == '-' and s.isDigits(5, 6) and
      s[7] == '-' and s.isDigits(8, 9)

proc isRfc3339(s: string): bool =
  ## whether ``s`` is an RFC 3339 date-time
  if s.len < 20 or not s[0 .. 9].isFullDate or s[10] notin {'T', 't'} or
      not (s.isDigits(11, 12) and s[13] == ':' and s.isDigits(14, 15) and
      s[16] == ':' and s.isDigits(17, 18)):
    return false
  var i = 19
  if s[i] == '.':
    inc i
    let first = i
    while i < s.len and s[i] in Digits: inc i
    if i == first: return false
  if i < s.len and s[i] in {'Z', 'z'}: return i == s.len - 1
  i + 6 == s.len and s[i] in {'+', '-'} and s.isDigits(i + 1, i + 2) and
      s[i + 3] == ':' and s.isDigits(i + 4, i + 5)

const
  integerTags = [yTagInteger, yTagNimInt8, yTagNimInt16, yTagNimInt32,
      yTagNimInt64, yTagNimUInt8, yTagNimUInt16, yTagNimUInt32, yTagNimUInt64]
  floatTags = [yTagFloat, yTagNimFloat32, yTagNimFloat64]

proc addScalar(buf: var string, e: Event) =
  let content = e.scalarContent
  var tag = e.scalarProperties.tag
  if ($tag).startsWith(cborTagPrefix):
    var
      number = ($tag)[cborTagPrefix.len .. ^1]
      binary = false
    if number.endsWith(":binary"):
      number.setLen(number.len - ":binary".len)
      binary = true
    try: buf.addHead(6, parseBiggestUInt(number))
    except ValueError:
      raise cborWriteError("invalid CBOR tag: " & $tag)
    tag =
      if binary: yTagBinary
      elif e.scalarStyle.isStyleQuoted: yTagExclamationMark
      else: yTagQuestionMark
  if tag == yTagQuestionMark:
    tag =
      if e.scalarStyle.isStyleQuoted: yTagString
      else:
        case guessType(content)
        of yTypeInteger: yTagInteger
        of yTypeFloat, yTypeFloatInf, yTypeFloatNaN: yTagFloat
        of yTypeBoolTrue, yTypeBoolFalse: yTagBoolean
        of yTypeNull: yTagNull
        of yTypeUnknown, yTypeTimestamp: yTagString
  if tag in integerTags:
    if not buf.addInteger(content):
      raise cborWriteError("not an integer: " & escape(content))
  elif tag in floatTags:
    case guessType(content)
    of yTypeFloatInf: buf.addFloat(if content[0] == '-': NegInf else: Inf)
    of yTypeFloatNaN: buf.addFloat(NaN)
    of yTypeInteger, yTypeFloat:
      try: buf.addFloat(parseFloat(content))
      except ValueError:
        raise cborWriteError("not a float: " & escape(content))
    else: raise cborWriteError("not a float: " & escape(content))
  elif tag == yTagBoolean:
    case guessType(content)
    of yTypeBoolTrue: buf.add('\xf5')
    of yTypeBoolFalse: buf.add('\xf4')
    else: raise cborWriteError("not a boolean: " & escape(content))
  elif tag == yTagNull:
    if content.len > 0 and guessType(content) != yTypeNull:
      raise cborWriteError("not null: " & escape(content))
    buf.add('\xf6')
  elif tag == yTagBinary:
    var data = newStringOfCap(content.len)
    for c in content:
      if c notin Whitespace: data.add(c)
    try: data = base64.decode(data)
    except ValueError:
      raise cborWriteError("not base64: " & escape(content))
    buf.addHead(2, uint64(data.len))
    buf.add(data)
  elif tag == yTagTimestamp:
    if content.isRfc3339: buf.addHead(6, 0)
    elif content.isFullDate: buf.addHead(6, 1004)
    buf.addText(content)
  else: buf.addText(content)

proc collectionPrefix(buf: var string, tag: Tag) =
  if ($tag).startsWith(cborTagPrefix):
    try: buf.addHead(6, parseBiggestUInt(($tag)[cborTagPrefix.len .. ^1]))
    except ValueError:
      raise cborWriteError("invalid CBOR tag: " & $tag)

proc presentCbor*(s: YamlStream): string
    {.raises: [YamlPresenterCborError, YamlStreamError].} =
  ## Writes the documents of ``s`` as CBOR sequence: each document is a
  ## CBOR data item.
  type Open = object
    kind: FrameKind
    count: uint64
    prefix, content: string
  var
    # stack[0] holds the output
    stack = @[Open()]
    shared = initTable[Anchor, uint64]()
    sharedCount = 0'u64
  template target: var string = stack[^1].content
  template share(anchor: Anchor, buf: var string) =
    if anchor != yAnchorNone:
      buf.addHead(6, 28)
      shared[anchor] = sharedCount
      inc sharedCount
  for e in s:
    if e.kind in {yamlStartMap, yamlStartSeq, yamlScalar, yamlAlias}:
      inc stack[^1].count
    case e.kind
    of yamlStartStream, yamlEndStream, yamlEndDoc: discard
    of yamlStartDoc:
      shared.clear()
      sharedCount = 0
    of yamlStartMap, yamlStartSeq:
      var o = Open(kind: if e.kind == yamlStartMap: fkMap else: fkArray)
      let props = if e.kind == yamlStartMap: e.mapProperties else: e.seqProperties
      share(props.anchor, o.prefix)
      o.prefix.collectionPrefix(props.tag)
      stack.add(o)
    of yamlEndMap, yamlEndSeq:
      let o = stack.pop()
      var buf = o.prefix
      buf.addHead(if o.kind == fkMap: 5 else: 4,
          if o.kind == fkMap: o.count div 2 else: o.count)
      buf.add(o.content)
      target.add(buf)
    of yamlScalar:
      share(e.scalarProperties.anchor, target)
      target.addScalar(e)
    of yamlAlias:
      let index = shared.getOrDefault(e.aliasTarget, high(uint64))
      if index == high(uint64):
        raise cborWriteError("alias to unknown anchor: " & $e.aliasTarget)
      target.addHead(6, 29)
      target.addHead(0, index)
  result = move(stack[0].content)

proc presentCbor*(s: YamlStream, target: Stream) {.raises: [
    YamlPresenterCborError, YamlPresenterOutputError, YamlStreamError].} =
  ## Writes the documents of ``s`` as CBOR sequence into ``target``.
  let data = presentCbor(s)
  try: target.write(data)
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "Error while writing to output stream")
    e.parent = ce
    raise e

# High-level API
# --------------

template unwrapStreamError(e: ref YamlStreamError, T: typedesc) =
  if e.parent of T: raise (ref T)(e.parent)
  else: internalError("Unexpected exception: " & $e.parent.name)

proc loadCbor*[K](input: Stream | string, target: var K) {.raises: [
    YamlConstructionError, YamlCborError, IOError, OSError].} =
  ## Loads a Nim value from a single CBOR data item.
  var events = parseCbor(input)
  try:
    var e = events.next()
    yAssert(e.kind == yamlStartStream)
    if events.peek().kind != yamlStartDoc:
      raise constructionError(events, e.startPos, "CBOR input is empty")
    construct(events, target)
    e = events.next()
    if e.kind != yamlEndStream:
      raise constructionError(events, e.startPos,
          "CBOR input contains multiple data items")
  except YamlStreamError as e: unwrapStreamError(e, YamlCborError)

proc loadAsCbor*[K](input: Stream | string): K {.raises: [
    YamlConstructionError, YamlCborError, IOError, OSError].} =
  ## Loads a value of the type K from a single CBOR data item and returns it.
  loadCbor(input, result)

proc loadCborSequence*[K](input: Stream | string, target: var seq[K]) {.raises: [
    YamlConstructionError, YamlCborError, IOError, OSError].} =
  ## Loads a value of the type K from each data item of a CBOR sequence and
  ## adds them to ``target``. Counterpart of `dumpCborSequence`_.
  var events = parseCbor(input)
  try:
    var e = events.next()
    yAssert(e.kind == yamlStartStream)
    while events.peek().kind == yamlStartDoc:
      var item: K
      construct(events, item)
      target.add(item)
    e = events.next()
    yAssert(e.kind == yamlEndStream)
  except YamlStreamError as e: unwrapStreamError(e, YamlCborError)

proc dumpCbor*[K](dumper: Dumper, value: K): string {.raises: [
    YamlPresenterCborError, YamlSerializationError].} =
  ## Dumps a Nim value as CBOR data item. Of ``dumper``, only the
  ## serialization options are used.
  var events = represent(value, dumper.serialization)
  try: result = presentCbor(events)
  except YamlStreamError as e:
    internalError("Unexpected exception: " & $e.name)

proc dumpCbor*[K](dumper: Dumper, value: K, target: Stream) {.raises: [
    YamlPresenterCborError, YamlPresenterOutputError, YamlSerializationError].} =
  ## Dumps a Nim value as CBOR data item into ``target``.
  var events = represent(value, dumper.serialization)
  try: presentCbor(events, target)
  except YamlStreamError as e:
    internalError("Unexpected exception: " & $e.name)

proc dumpCborSequence*[K](dumper: Dumper, values: openArray[K]): string {.raises: [
    YamlPresenterCborError, YamlSerializationError].} =
  ## Dumps each of the given Nim values as data item of a CBOR sequence.
  ## Shared values are local to each data item. Counterpart of
  ## `loadCborSequence`_.
  for value in values: result.add(dumper.dumpCbor(value))

proc yamlToCbor*(input: Stream | string): string {.raises: [
    YamlParserError, YamlPresenterCborError, IOError, OSError].} =
  ## Converts each document of the YAML (or JSON) ``input`` to a CBOR data
  ## item and returns the resulting CBOR sequence.
  var
    parser = initYamlParser()
    events = parser.parse(input)
  try: result = presentCbor(events)
  except YamlStreamError as e:
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of OSError: raise (ref OSError)(e.parent)
    else: unwrapStreamError(e, YamlParserError)

proc cborToYaml*(
  input  : Stream | string,
  options: PresentationOptions = PresentationOptions(),
): string {.raises: [
  YamlCborError, YamlPresenterJsonError, YamlPresenterOutputError,
  IOError, OSError
].} =
  ## Converts each data item of the CBOR ``input`` to a YAML document. With
  ## the presentation options of `jsonDumper`_, the output is JSON.
  var events = parseCbor(input)
  try: result = present(events, options)
  except YamlStreamError as e: unwrapStreamError(e, YamlCborError)
