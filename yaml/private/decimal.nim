#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Exact decimal numbers for JSON Schema's numeric keywords.
##
## JSON numbers are decimal literals of arbitrary size and precision, and
## JSON Schema compares them as such: ``0.0075`` is a multiple of ``0.0001``,
## and ``972783798187987123879878123.18878137`` is less than
## ``972783798187987123879878123.188781371``. Neither holds for float64. So
## numbers are kept the way they are written, as a coefficient and a power of
## ten, and compared and divided exactly.
##
## Only finite numbers are representable; YAML's ``.inf`` and ``.nan`` are
## left to the caller.

import std/strutils

type
  Decimal* = object
    ## The value ``coefficient * 10^exponent``, negated if ``negative``.
    ## ``coefficient`` holds decimal digits without leading or trailing zeros
    ## (trailing zeros move into ``exponent``); it is empty for zero, which
    ## is never negative.
    negative*: bool
    coefficient*: string
    exponent*: int

const maxScale = 100_000
  ## Upper bound on the number of digits ``isMultipleOf`` expands a number
  ## to. Literals like ``1e1000000000`` would otherwise need a gigabyte.

proc normalize(d: var Decimal) =
  var first = 0
  while first < d.coefficient.len and d.coefficient[first] == '0': inc(first)
  var last = d.coefficient.high
  while last >= first and d.coefficient[last] == '0':
    dec(last)
    inc(d.exponent)
  d.coefficient = d.coefficient[first .. last]
  if d.coefficient.len == 0:
    d.negative = false
    d.exponent = 0

proc parseDecimal*(s: string, d: var Decimal): bool {.raises: [].} =
  ## Parses a decimal literal: an optional sign, digits with an optional
  ## fraction (either part may be empty, but not both), and an optional
  ## exponent. This covers JSON numbers and the decimal integers and floats
  ## of the YAML core schema. Returns ``false`` for anything else, including
  ## hexadecimal, octal, infinities and NaN.
  d = Decimal()
  var i = 0
  if i < s.len and s[i] in {'-', '+'}:
    d.negative = s[i] == '-'
    inc(i)
  var digits = 0
  while i < s.len and s[i] in Digits:
    d.coefficient.add(s[i])
    inc(i)
    inc(digits)
  if i < s.len and s[i] == '.':
    inc(i)
    while i < s.len and s[i] in Digits:
      d.coefficient.add(s[i])
      dec(d.exponent)
      inc(i)
      inc(digits)
  if digits == 0: return false
  if i < s.len and s[i] in {'e', 'E'}:
    inc(i)
    var expNegative = false
    if i < s.len and s[i] in {'-', '+'}:
      expNegative = s[i] == '-'
      inc(i)
    if i == s.len: return false
    var e = 0
    while i < s.len and s[i] in Digits:
      if e < 1_000_000_000: e = e * 10 + (ord(s[i]) - ord('0'))
      inc(i)
    d.exponent += (if expNegative: -e else: e)
  if i != s.len: return false
  d.normalize()
  result = true

proc toDecimal*(i: int64): Decimal {.raises: [].} =
  var s = $i
  result = Decimal()
  if s[0] == '-':
    result.negative = true
    s = s[1 .. ^1]
  result.coefficient = s
  result.normalize()

proc isZero*(d: Decimal): bool = d.coefficient.len == 0

proc isInteger*(d: Decimal): bool {.raises: [].} =
  ## Whether ``d`` has no fractional part (``1.0`` and ``1e3`` do not).
  d.exponent >= 0

proc magnitude(d: Decimal): int =
  ## The power of ten of the leading digit; meaningless for zero.
  d.coefficient.len + d.exponent

proc cmpAbs(a, b: Decimal): int =
  if a.isZero or b.isZero: return cmp(a.coefficient.len, b.coefficient.len)
  if a.magnitude != b.magnitude: return cmp(a.magnitude, b.magnitude)
  # same magnitude: digits line up from the left
  for i in 0 ..< max(a.coefficient.len, b.coefficient.len):
    let
      x = if i < a.coefficient.len: a.coefficient[i] else: '0'
      y = if i < b.coefficient.len: b.coefficient[i] else: '0'
    if x != y: return cmp(x, y)
  result = 0

proc cmp*(a, b: Decimal): int {.raises: [].} =
  if a.negative != b.negative: return (if a.negative: -1 else: 1)
  result = cmpAbs(a, b)
  if a.negative: result = -result

proc `==`*(a, b: Decimal): bool = cmp(a, b) == 0
proc `<`*(a, b: Decimal): bool = cmp(a, b) < 0
proc `<=`*(a, b: Decimal): bool = cmp(a, b) <= 0

proc cmpDigits(a, b: string): int =
  ## Compares unsigned integers given as digit strings without leading zeros.
  if a.len != b.len: cmp(a.len, b.len) else: cmp(a, b)

proc subtract(a: var string, b: string) =
  ## ``a -= b`` for digit strings with ``a >= b``; keeps ``a`` free of
  ## leading zeros.
  var
    borrow = 0
    i = a.high
    j = b.high
  while i >= 0:
    var digit = ord(a[i]) - ord('0') - borrow -
        (if j >= 0: ord(b[j]) - ord('0') else: 0)
    borrow = 0
    if digit < 0:
      digit += 10
      borrow = 1
    a[i] = char(ord('0') + digit)
    dec(i)
    dec(j)
  var first = 0
  while first < a.len and a[first] == '0': inc(first)
  a = a[first .. ^1]

proc isMultipleOf*(a, b: Decimal, multiple: var bool): bool {.raises: [].} =
  ## Sets ``multiple`` to whether ``a`` is an integer multiple of ``b``, which
  ## must not be zero. Returns ``false`` if the numbers are too far apart in
  ## scale to be checked exactly.
  assert not b.isZero
  if a.isZero:
    multiple = true
    return true
  # a / b is an integer iff ca * 10^(ea - e) is divisible by cb * 10^(eb - e)
  # with e = min(ea, eb)
  let e = min(a.exponent, b.exponent)
  if a.exponent - e + a.coefficient.len > maxScale or
      b.exponent - e + b.coefficient.len > maxScale:
    return false
  let
    dividend = a.coefficient & repeat('0', a.exponent - e)
    divisor = b.coefficient & repeat('0', b.exponent - e)
  var remainder = ""
  for digit in dividend:
    if remainder.len > 0 or digit != '0': remainder.add(digit)
    while cmpDigits(remainder, divisor) >= 0: remainder.subtract(divisor)
  multiple = remainder.len == 0
  result = true

proc toFloat*(d: Decimal): float64 {.raises: [].} =
  if d.isZero: return 0.0
  try: result = parseFloat((if d.negative: "-" else: "") & d.coefficient &
      "e" & $d.exponent)
  except ValueError: result = 0.0 # cannot happen for normalized digits

proc `$`*(d: Decimal): string =
  ## Formats ``d`` as a JSON number: plain digits where that is short,
  ## exponent notation otherwise.
  if d.isZero: return "0"
  if d.negative: result.add('-')
  if d.exponent >= 0 and d.exponent <= 21:
    result.add(d.coefficient)
    result.add(repeat('0', d.exponent))
  elif d.exponent < 0 and d.magnitude > 0:
    result.add(d.coefficient[0 ..< d.magnitude])
    result.add('.')
    result.add(d.coefficient[d.magnitude .. ^1])
  elif d.exponent < 0 and d.magnitude > -6:
    result.add("0.")
    result.add(repeat('0', -d.magnitude))
    result.add(d.coefficient)
  else:
    result.add(d.coefficient[0])
    if d.coefficient.len > 1:
      result.add('.')
      result.add(d.coefficient[1 .. ^1])
    result.add('e')
    result.add($(d.magnitude - 1))
