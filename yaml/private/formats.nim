#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Checks for the string formats defined by JSON Schema Validation,
## Section 7.3. Each follows the grammar of the RFC the specification names
## for it, exactly and without trimming: ``"2020-01-01 "`` is not a date.

import std/strutils
import uri, ecmaregex, idna, ../uritemplate

proc digits(s: string, start, count: int): int =
  ## The value of ``count`` ASCII digits at ``start``, or -1.
  if start + count > s.len: return -1
  result = 0
  for i in start ..< start + count:
    if s[i] notin Digits: return -1
    result = result * 10 + ord(s[i]) - ord('0')

proc daysInMonth(year, month: int): int =
  case month
  of 2:
    if year mod 4 == 0 and (year mod 100 != 0 or year mod 400 == 0): 29
    else: 28
  of 4, 6, 9, 11: 30
  else: 31

proc isDate*(s: string): bool =
  ## ``full-date`` of RFC 3339, Section 5.6.
  if s.len != 10 or s[4] != '-' or s[7] != '-': return false
  let
    year = digits(s, 0, 4)
    month = digits(s, 5, 2)
    day = digits(s, 8, 2)
  result = year >= 0 and month >= 1 and month <= 12 and day >= 1 and
      day <= daysInMonth(year, month)

proc isTime*(s: string): bool =
  ## ``full-time`` of RFC 3339, Section 5.6, with a leap second only where
  ## the time is 23:59:60 in UTC.
  if s.len < 9 or s[2] != ':' or s[5] != ':': return false
  let
    hour = digits(s, 0, 2)
    minute = digits(s, 3, 2)
    second = digits(s, 6, 2)
  if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or
      second > 60:
    return false
  var i = 8
  if i < s.len and s[i] == '.':
    inc(i)
    let start = i
    while i < s.len and s[i] in Digits: inc(i)
    if i == start: return false
  if i >= s.len: return false
  var offsetMinutes = 0
  if s[i] in {'Z', 'z'}:
    inc(i)
  elif s[i] in {'+', '-'}:
    if i + 6 != s.len or s[i + 3] != ':': return false
    let
      offHour = digits(s, i + 1, 2)
      offMinute = digits(s, i + 4, 2)
    if offHour < 0 or offHour > 23 or offMinute < 0 or offMinute > 59:
      return false
    offsetMinutes = offHour * 60 + offMinute
    if s[i] == '-': offsetMinutes = -offsetMinutes
    i += 6
  else: return false
  if i != s.len: return false
  if second == 60:
    let utc = ((hour * 60 + minute - offsetMinutes) mod 1440 + 1440) mod 1440
    if utc != 23 * 60 + 59: return false
  result = true

proc isDateTime*(s: string): bool =
  ## ``date-time`` of RFC 3339, Section 5.6.
  s.len > 11 and s[10] in {'T', 't'} and isDate(s[0 ..< 10]) and
      isTime(s[11 .. ^1])

proc isDuration*(s: string): bool =
  ## ``duration`` of RFC 3339, Appendix A.
  if s.len < 2 or s[0] != 'P': return false
  var i = 1
  proc number(s: string, i: var int): bool =
    let start = i
    while i < s.len and s[i] in Digits: inc(i)
    result = i > start

  # dur-week
  block:
    var j = i
    if number(s, j) and j < s.len and s[j] == 'W':
      return j + 1 == s.len
  # dur-date: (day / month day / year month [day])
  const dateUnits = ['Y', 'M', 'D']
  var
    last = -1
    count = 0
  while i < s.len and s[i] != 'T':
    if not number(s, i) or i >= s.len: return false
    let unit = dateUnits.find(s[i])
    if unit < 0 or unit <= last: return false
    # units must be consecutive: Y then M, M then D
    if last >= 0 and unit != last + 1: return false
    last = unit
    inc(count)
    inc(i)
  if i < s.len:
    # dur-time: hour [minute [second]] / minute [second] / second
    inc(i)
    const timeUnits = ['H', 'M', 'S']
    var
      lastTime = -1
      timeCount = 0
    while i < s.len:
      if not number(s, i) or i >= s.len: return false
      let unit = timeUnits.find(s[i])
      if unit < 0 or unit <= lastTime: return false
      if lastTime >= 0 and unit != lastTime + 1: return false
      lastTime = unit
      inc(timeCount)
      inc(i)
    if timeCount == 0: return false
  elif count == 0: return false
  result = true

const atext = Letters + Digits + {'!', '#', '$', '%', '&', '\'', '*', '+',
    '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~'}

proc isHostname*(s: string, idna = true): bool =
  ## A host name as in RFC 1123, Section 2.1: dot-separated labels of
  ## letters, digits and hyphens, at most 63 octets each and 253 in total.
  ## With ``idna``, labels in the IDNA reserved form (``xn--...``, or any with
  ## hyphens in the third and fourth positions) must be valid A-labels
  ## (RFC 5890); draft-04 and draft-06 refer to RFC 1034 only.
  if s.len == 0 or s.len > 253: return false
  var reserved = false
  for label in s.split('.'):
    if label.len == 0 or label.len > 63: return false
    if label[0] == '-' or label[^1] == '-': return false
    for c in label:
      if c notin Letters + Digits + {'-'}: return false
    if idna and label.len >= 4 and label[2] == '-' and label[3] == '-':
      if not label.toLowerAscii.startsWith("xn--"): return false
      reserved = true
  # A-labels are checked as what they encode; the Bidi rule applies to the
  # whole name
  result = not reserved or isIdnaHostname(s)

proc isIdnHostname*(s: string): bool =
  ## An internationalized host name (RFC 5890), processed as UTS 46
  ## prescribes; see ``idna``.
  isIdnaHostname(s)

proc isAddressLiteral(s: string): bool =
  ## ``address-literal`` of RFC 5321, Section 4.1.3, without the brackets.
  if s.len >= 5 and s[0 .. 4].toLowerAscii == "ipv6:": isIpv6(s[5 .. ^1])
  else: isIpv4(s)

proc isQuotedString(s: string, i: var int, unicode: bool): bool =
  ## ``Quoted-string`` of RFC 5321 (RFC 6531 with ``unicode``).
  if i >= s.len or s[i] != '"': return false
  inc(i)
  while i < s.len and s[i] != '"':
    let c = s[i]
    if c == '\\':
      inc(i)
      if i >= s.len or ord(s[i]) < 32 or ord(s[i]) > 126: return false
    elif ord(c) >= 0x80:
      if not unicode: return false
    elif ord(c) < 32 or ord(c) > 126: return false
    inc(i)
  if i >= s.len: return false
  inc(i)
  result = true

proc isMailbox(s: string, unicode: bool): bool =
  ## ``Mailbox`` of RFC 5321, Section 4.1.2, extended by RFC 6531 if
  ## ``unicode``. The domain part is a host name or an address literal.
  var i = 0
  if s.len > 0 and s[0] == '"':
    if not isQuotedString(s, i, unicode): return false
  else:
    # Dot-string
    var atomStart = true
    while i < s.len and s[i] != '@':
      let c = s[i]
      if c == '.':
        if atomStart: return false
        atomStart = true
      elif c in atext or (unicode and ord(c) >= 0x80): atomStart = false
      else: return false
      inc(i)
    if atomStart: return false
  if i >= s.len or s[i] != '@': return false
  let domain = s[i + 1 .. ^1]
  if domain.len == 0: return false
  if domain[0] == '[':
    return domain[^1] == ']' and isAddressLiteral(domain[1 .. ^2])
  result = if unicode: isIdnHostname(domain) else: isHostname(domain)

proc isEmail*(s: string): bool = isMailbox(s, false)
proc isIdnEmail*(s: string): bool = isMailbox(s, true)

proc isUuid*(s: string): bool =
  ## A UUID in the string form of RFC 9562, Section 4.
  if s.len != 36: return false
  for i, c in s:
    if i in [8, 13, 18, 23]:
      if c != '-': return false
    elif c notin HexDigits: return false
  result = true

proc isJsonPointer*(s: string): bool =
  ## A JSON Pointer in string representation (RFC 6901, Section 3).
  if s.len > 0 and s[0] != '/': return false
  for i, c in s:
    if c == '~' and (i + 1 >= s.len or s[i + 1] notin {'0', '1'}): return false
  result = true

proc isRelativeJsonPointer*(s: string): bool =
  ## A Relative JSON Pointer (draft-bhutton-relative-json-pointer-00):
  ## a non-negative integer, an optional index manipulation, then ``#`` or a
  ## JSON Pointer.
  var i = 0
  while i < s.len and s[i] in Digits: inc(i)
  if i == 0 or (s[0] == '0' and i > 1): return false
  if i < s.len and s[i] in {'+', '-'}:
    inc(i)
    let start = i
    while i < s.len and s[i] in Digits: inc(i)
    if i == start or (s[start] == '0' and i - start > 1): return false
  let rest = s[i .. ^1]
  result = rest == "#" or isJsonPointer(rest)

proc checkFormat*(format, value: string, known: var bool, idna = true): bool =
  ## Checks ``value`` against ``format``. Sets ``known`` to ``false`` (and
  ## returns ``true``) for formats this module does not know. ``idna``
  ## selects the IDNA-aware ``hostname`` of draft-07 and later.
  known = true
  case format
  of "date-time": isDateTime(value)
  of "date": isDate(value)
  of "time": isTime(value)
  of "duration": isDuration(value)
  of "email": isEmail(value)
  of "idn-email": isIdnEmail(value)
  of "hostname": isHostname(value, idna)
  of "idn-hostname": isIdnHostname(value)
  of "ipv4": isIpv4(value)
  of "ipv6": isIpv6(value)
  of "uri": isUri(value)
  of "uri-reference": isUriReference(value)
  of "iri": isIri(value)
  of "iri-reference": isIriReference(value)
  of "uuid": isUuid(value)
  of "uri-template": isUriTemplate(value)
  of "json-pointer": isJsonPointer(value)
  of "relative-json-pointer": isRelativeJsonPointer(value)
  of "regex": isEcmaRegex(value)
  else:
    known = false
    true
