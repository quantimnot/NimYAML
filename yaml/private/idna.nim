#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Internationalized host names, for JSON Schema's ``hostname`` and
## ``idn-hostname`` formats.
##
## A host name is processed the way UTS 46 (Unicode IDNA Compatibility
## Processing) does, non-transitionally, with ``CheckHyphens``,
## ``CheckBidi``, ``CheckJoiners``, ``UseSTD3ASCIIRules`` and
## ``VerifyDnsLength``: each code point is mapped (``Ａ`` becomes ``a``,
## ``。`` a label separator, zero width spaces vanish), the result is
## normalized to NFC and split into labels, and labels in Punycode
## (``xn--...``) are decoded. Each label must then be valid under IDNA2008:
##
## * no code point that IDNA2008 disallows (UTS 46 marks those ``NV8``),
## * no hyphens at both the third and fourth position, nor at either end,
## * no combining mark at the start,
## * the contextual rules of RFC 5892, Appendix A (CONTEXTJ for the zero
##   width (non-)joiner, CONTEXTO for the middle dot, Greek keraia, Hebrew
##   geresh and gershayim, Katakana middle dot and Arabic-Indic digits),
## * the Bidi rule of RFC 5893 in domain names that contain right-to-left
##   labels,
##
## and the ASCII form must fit DNS: labels of 1 to 63 octets, 253 in total.
## The data comes from ``idnatables``.

import std/strutils
import unicodecategories, idnatables

type CodePoints = seq[int32]

# ----------------------------------------------------------------------------
# Table lookup
# ----------------------------------------------------------------------------

proc idnaStatus(cp: int32, mapping: var CodePoints): IdnaStatus =
  ## The UTS 46 status of ``cp``; ``mapping`` receives its mapping.
  var
    low = 0
    high = idnaRuns.len - 1
  while low < high:
    let mid = (low + high + 1) div 2
    if int32(idnaRuns[mid] and 0x1FFFFF) <= cp: low = mid
    else: high = mid - 1
  let run = idnaRuns[low]
  result = IdnaStatus((run shr 21) and 7)
  let
    length = int((run shr 24) and 63)
    offset = int(run shr 30)
  mapping.setLen(0)
  for i in offset ..< offset + length: mapping.add(int32(idnaMappings[i]))

proc lookup(runs: openArray[uint32], shift: int, cp: int32): int =
  ## The value of the run containing ``cp``, for runs packed as
  ## ``firstCodePoint shl shift or value``.
  var
    low = 0
    high = runs.high
  while low < high:
    let mid = (low + high + 1) div 2
    if int32(runs[mid] shr shift) <= cp: low = mid
    else: high = mid - 1
  result = int(runs[low] and ((1'u32 shl shift) - 1))

proc bidiClass(cp: int32): BidiClass = BidiClass(lookup(bidiRuns, 5, cp))
proc joiningType(cp: int32): JoiningType = JoiningType(lookup(joiningRuns, 3, cp))
proc script(cp: int32): IdnaScript = IdnaScript(lookup(scriptRuns, 3, cp))
proc combiningClass(cp: int32): int = lookup(combiningRuns, 8, cp)

proc decomposition(cp: int32, first, second: var int32): bool =
  var
    low = 0
    high = decompositions.len - 1
  while low <= high:
    let
      mid = (low + high) div 2
      c = int32(decompositions[mid] and 0x1FFFFF)
    if c == cp:
      first = int32((decompositions[mid] shr 21) and 0x1FFFFF)
      second = int32(decompositions[mid] shr 42)
      return true
    if c < cp: low = mid + 1
    else: high = mid - 1
  result = false

# ----------------------------------------------------------------------------
# NFC (UAX 15)
# ----------------------------------------------------------------------------

const
  sBase = 0xAC00'i32
  lBase = 0x1100'i32
  vBase = 0x1161'i32
  tBase = 0x11A7'i32
  lCount = 19'i32
  vCount = 21'i32
  tCount = 28'i32
  nCount = vCount * tCount
  sCount = lCount * nCount

proc decompose(cp: int32, output: var CodePoints) =
  if cp >= sBase and cp < sBase + sCount:
    let s = cp - sBase
    output.add(lBase + s div nCount)
    output.add(vBase + (s mod nCount) div tCount)
    if s mod tCount != 0: output.add(tBase + s mod tCount)
    return
  var first, second: int32
  if decomposition(cp, first, second):
    decompose(first, output)
    if second != 0: decompose(second, output)
  else: output.add(cp)

proc compose(first, second: int32): int32 =
  ## The primary composite of the pair, or -1.
  if first >= lBase and first < lBase + lCount and second >= vBase and
      second < vBase + vCount:
    return sBase + ((first - lBase) * vCount + second - vBase) * tCount
  if first >= sBase and first < sBase + sCount and (first - sBase) mod tCount == 0 and
      second > tBase and second < tBase + tCount:
    return first + second - tBase
  let key = uint64(first) shl 42 or uint64(second) shl 21
  var
    low = 0
    high = compositions.len - 1
  while low <= high:
    let
      mid = (low + high) div 2
      k = compositions[mid] and not 0x1FFFFF'u64
    if k == key: return int32(compositions[mid] and 0x1FFFFF)
    if k < key: low = mid + 1
    else: high = mid - 1
  result = -1

proc nfc(input: CodePoints): CodePoints =
  var d: CodePoints
  for cp in input: decompose(cp, d)
  # canonical ordering
  for i in 1 ..< d.len:
    var j = i
    let cc = combiningClass(d[j])
    if cc == 0: continue
    while j > 0 and combiningClass(d[j - 1]) > cc:
      swap(d[j - 1], d[j])
      dec(j)
  if d.len == 0: return
  result = @[d[0]]
  var
    starter = if combiningClass(d[0]) == 0: 0 else: -1
    lastClass = if starter == 0: 0 else: 256
  for i in 1 ..< d.len:
    let
      c = d[i]
      cc = combiningClass(c)
    if starter >= 0 and (lastClass < cc or lastClass == 0):
      let composite = compose(result[starter], c)
      if composite >= 0:
        result[starter] = composite
        continue
    if cc == 0: starter = result.len
    lastClass = cc
    result.add(c)

# ----------------------------------------------------------------------------
# Punycode (RFC 3492)
# ----------------------------------------------------------------------------

const
  base = 36
  tMin = 1
  tMax = 26
  skew = 38
  damp = 700
  initialBias = 72
  initialN = 128

proc adapt(delta, numPoints: int, firstTime: bool): int =
  var delta = if firstTime: delta div damp else: delta div 2
  delta += delta div numPoints
  var k = 0
  while delta > ((base - tMin) * tMax) div 2:
    delta = delta div (base - tMin)
    k += base
  result = k + (base - tMin + 1) * delta div (delta + skew)

proc punycodeDecode(input: string, output: var CodePoints): bool =
  output.setLen(0)
  let b = input.rfind('-')
  if b > 0:
    for c in input[0 ..< b]:
      if ord(c) >= 0x80: return false
      output.add(int32(ord(c)))
  var
    pos = if b > 0: b + 1 else: 0
    n = initialN
    i = 0
    bias = initialBias
  while pos < input.len:
    let oldI = i
    var
      w = 1
      k = base
    while true:
      if pos >= input.len: return false
      let c = input[pos]
      inc(pos)
      let digit = case c
        of 'a'..'z': ord(c) - ord('a')
        of 'A'..'Z': ord(c) - ord('A')
        of '0'..'9': ord(c) - ord('0') + 26
        else: return false
      if digit > (high(int32) - i) div w: return false
      i += digit * w
      let t = if k <= bias: tMin elif k >= bias + tMax: tMax else: k - bias
      if digit < t: break
      if w > high(int32) div (base - t): return false
      w *= base - t
      k += base
    bias = adapt(i - oldI, output.len + 1, oldI == 0)
    if i div (output.len + 1) > 0x10FFFF - n: return false
    n += i div (output.len + 1)
    i = i mod (output.len + 1)
    if n < 0x80 or n > 0x10FFFF: return false
    output.insert(int32(n), i)
    inc(i)
  result = true

proc punycodeEncode(input: CodePoints): string =
  var basicCount = 0
  for cp in input:
    if cp < 0x80:
      result.add(char(cp))
      inc(basicCount)
  var h = basicCount
  if basicCount > 0: result.add('-')
  var
    n = initialN
    delta = 0
    bias = initialBias
  while h < input.len:
    var m = high(int)
    for cp in input:
      if cp >= n and cp < m: m = cp
    delta += (m - n) * (h + 1)
    n = m
    for cp in input:
      if cp < n: inc(delta)
      elif cp == n:
        var q = delta
        var k = base
        while true:
          let t = if k <= bias: tMin elif k >= bias + tMax: tMax else: k - bias
          if q < t: break
          let digit = t + (q - t) mod (base - t)
          result.add(if digit < 26: char(ord('a') + digit)
                     else: char(ord('0') + digit - 26))
          q = (q - t) div (base - t)
          k += base
        result.add(if q < 26: char(ord('a') + q) else: char(ord('0') + q - 26))
        bias = adapt(delta, h + 1, h == basicCount)
        delta = 0
        inc(h)
    inc(delta)
    inc(n)

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------

proc decodeUtf8(s: string, output: var CodePoints): bool =
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    var
      length: int
      cp: int
    if c < 0x80: (length, cp) = (1, c)
    elif c shr 5 == 0b110: (length, cp) = (2, c and 0x1F)
    elif c shr 4 == 0b1110: (length, cp) = (3, c and 0x0F)
    elif c shr 3 == 0b11110: (length, cp) = (4, c and 0x07)
    else: return false
    if i + length > s.len: return false
    for k in 1 ..< length:
      let b = ord(s[i + k])
      if b shr 6 != 0b10: return false
      cp = cp shl 6 or (b and 0x3F)
    if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF): return false
    output.add(int32(cp))
    i += length
  result = true

proc isAscii(label: CodePoints): bool =
  for cp in label:
    if cp >= 0x80: return false
  result = true

proc toLowerAscii(label: CodePoints): string =
  for cp in label:
    result.add(if cp >= int32('A') and cp <= int32('Z'): char(cp + 32)
               else: char(cp))

proc contextOk(label: CodePoints, i: int): bool =
  ## The contextual rules of RFC 5892, Appendix A for ``label[i]``.
  let cp = label[i]
  template before: int32 = (if i > 0: label[i - 1] else: -1)
  template after: int32 = (if i < label.high: label[i + 1] else: -1)
  case cp
  of 0x200C:
    if i > 0 and combiningClass(before) == 9: return true # virama
    var j = i - 1
    while j >= 0 and joiningType(label[j]) == jtT: dec(j)
    if j < 0 or joiningType(label[j]) notin {jtL, jtD}: return false
    j = i + 1
    while j < label.len and joiningType(label[j]) == jtT: inc(j)
    result = j < label.len and joiningType(label[j]) in {jtR, jtD}
  of 0x200D: result = i > 0 and combiningClass(before) == 9
  of 0x00B7: result = before == int32('l') and after == int32('l')
  of 0x0375: result = after >= 0 and script(after) == scGreek
  of 0x05F3, 0x05F4: result = before >= 0 and script(before) == scHebrew
  of 0x30FB:
    result = false
    for c in label:
      if script(c) in {scHiragana, scKatakana, scHan}: return true
  of 0x0660 .. 0x0669:
    for c in label:
      if c >= 0x06F0 and c <= 0x06F9: return false
    result = true
  of 0x06F0 .. 0x06F9:
    for c in label:
      if c >= 0x0660 and c <= 0x0669: return false
    result = true
  else: result = true

proc labelValid(label: CodePoints): bool =
  ## Validity criteria of UTS 46, Section 4.1, with IDNA2008's restrictions.
  if label.len == 0: return false
  if label.len >= 4 and label[2] == int32('-') and label[3] == int32('-'):
    return false
  if label[0] == int32('-') or label[^1] == int32('-'): return false
  if label[0].generalCategory in {Mn, Mc, Me}: return false
  var mapping: CodePoints
  for i, cp in label:
    if cp == int32('.'): return false
    if idnaStatus(cp, mapping) notin {valid, deviation}: return false
    if not contextOk(label, i): return false
  result = true

proc bidiValid(label: CodePoints): bool =
  ## The Bidi rule of RFC 5893, Section 2.
  let first = bidiClass(label[0])
  if first notin {bcL, bcR, bcAL}: return false
  var last = label.high
  while last > 0 and bidiClass(label[last]) == bcNSM: dec(last)
  let lastClass = bidiClass(label[last])
  if first in {bcR, bcAL}:
    var hasEN, hasAN = false
    for cp in label:
      let c = bidiClass(cp)
      if c notin {bcR, bcAL, bcAN, bcEN, bcES, bcCS, bcET, bcON, bcBN, bcNSM}:
        return false
      if c == bcEN: hasEN = true
      if c == bcAN: hasAN = true
    if lastClass notin {bcR, bcAL, bcEN, bcAN}: return false
    result = not (hasEN and hasAN)
  else:
    for cp in label:
      if bidiClass(cp) notin {bcL, bcEN, bcES, bcCS, bcET, bcON, bcBN, bcNSM}:
        return false
    result = lastClass in {bcL, bcEN}

proc isIdnaHostname*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is a valid internationalized host name, as described in
  ## the module documentation.
  var input: CodePoints
  if s.len == 0 or not decodeUtf8(s, input): return false
  # mapping
  var
    processed: CodePoints
    mapping: CodePoints
  for cp in input:
    case idnaStatus(cp, mapping)
    of valid, validNV8, deviation: processed.add(cp)
    of ignored: discard
    of mapped: processed.add(mapping)
    of disallowed: return false
  let normalized = nfc(processed)
  # labels
  var
    labels: seq[CodePoints] = @[@[]]
  for cp in normalized:
    if cp == int32('.'): labels.add(@[])
    else: labels[^1].add(cp)
  var
    total = labels.len - 1
    bidiDomain = false
  for label in labels.mitems:
    if label.len == 0: return false
    var ascii: string
    let lower = if label.isAscii: label.toLowerAscii else: ""
    if label.len >= 4 and lower.len > 0 and lower[0 .. 3] == "xn--":
      var decoded: CodePoints
      if not punycodeDecode(lower[4 .. ^1], decoded): return false
      if decoded.len == 0 or decoded.isAscii: return false
      if punycodeEncode(decoded) != lower[4 .. ^1]: return false
      if nfc(decoded) != decoded: return false
      ascii = lower
      label = decoded
    elif label.isAscii: ascii = lower
    else: ascii = "xn--" & punycodeEncode(label)
    if ascii.len > 63: return false
    total += ascii.len
    if not labelValid(label): return false
    for cp in label:
      if bidiClass(cp) in {bcR, bcAL, bcAN}: bidiDomain = true
  if total > 253: return false
  if bidiDomain:
    for label in labels:
      if not bidiValid(label): return false
  result = true
