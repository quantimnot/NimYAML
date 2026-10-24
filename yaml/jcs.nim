#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===============
## Module yaml/jcs
## ===============
##
## Serializes YAML representation graphs with the `JSON Canonicalization
## Scheme <https://www.rfc-editor.org/rfc/rfc8785>`_ (JCS, RFC 8785). Two
## documents with the same JSON value get byte-for-byte the same canonical
## form, however they were written, which makes it the input to hashes and
## signatures:
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, jcs]
##
##   echo canonicalJson(loadAs[YamlNode]("""
##   numbers: [1.0e+3, +16, .5]
##   "café": ok
##   """))
##   # {"café":"ok","numbers":[1000,16,0.5]}
##
## JCS is JSON without whitespace, with object members sorted by the UTF-16
## code units of their names, strings escaped as ECMAScript's
## ``JSON.stringify`` escapes them, and numbers written as ECMAScript's
## ``Number.prototype.toString`` writes IEEE 754 doubles. The implementation
## passes the test vectors of the `JCS reference implementations
## <https://github.com/cyberphone/json-canonicalization>`_.
##
## Refusing rather than guessing
## -----------------------------
##
## The graph is read as JSON in the way of `yaml/jsonpath <jsonpath.html>`_:
## scalars get their JSON type from their tag and the core schema, and
## aliases are followed. Where that reading would leave something out,
## ``canonicalJson`` raises ``YamlJcsError`` instead, because a canonical
## form that silently drops data would give different documents the same
## signature:
##
## * a mapping key that is not a string (``1: one``, ``[a]: b``);
## * two keys spelling the same member name (``a`` and ``"a"``);
## * a cyclic graph, which has no JSON value;
## * ``.inf`` and ``.nan``, which JSON cannot represent;
## * strings that are not valid UTF-8.
##
## Integers are written as the doubles they round to, as ECMAScript would
## write them; RFC 8785 (Section 3.2.2.3) recommends strings for integers
## beyond 2^53. Values with application-specific tags become strings, since
## JSON has no tags.

import std/[algorithm, math, sets, strutils, tables, unicode]
import dom, private/jsonmodel

when defined(nimPreviewSlimSystem):
  import std/formatfloat

type
  YamlJcsError* = object of ValueError
    ## Raised when a graph has no faithful JSON value to canonicalize.

proc jcsError(msg: string): ref YamlJcsError =
  newException(YamlJcsError, msg)

# ============================================================================
# Numbers
#
# ECMAScript writes a double as the shortest digit string that rounds back
# to it, laid out by the position of the decimal point: plain for decimal
# exponents from -6 to 21, scientific beyond. Nim's ``$`` already finds the
# shortest digits (it implements Ryu-style round-trip formatting), so this
# only takes them apart and lays them out the ECMAScript way, which is
# Number::toString of ECMA-262, Section 6.1.6.1.20.
# ============================================================================

proc ecmaNumber*(x: float64): string {.raises: [YamlJcsError].} =
  ## Formats ``x`` as ECMAScript's ``Number.prototype.toString`` does, which
  ## is how JCS writes numbers: ``1e21``, ``1e+21`` is not; ``0.000001``,
  ## ``1e-7``; ``-0`` as ``0``. Raises ``YamlJcsError`` for infinities and
  ## NaN.
  case classify(x)
  of fcNan, fcInf, fcNegInf:
    raise jcsError("JSON cannot represent " & $x)
  of fcZero, fcNegZero: return "0"
  else: discard
  let shortest = $abs(x)
  var
    digits = ""
    pointAt = -1   # digits before the decimal point, if Nim wrote one
    exponent = 0
  for i, c in shortest:
    case c
    of '0'..'9': digits.add(c)
    of '.': pointAt = digits.len
    of 'e':
      try: exponent = parseInt(shortest[i + 1 .. ^1])
      except ValueError: discard # Nim writes valid exponents
      break
    else: discard
  if pointAt < 0: pointAt = digits.len
  # Normalize to digits d1..dk without leading or trailing zeros and the
  # value 0.d1..dk × 10^n, which is how ECMA-262 states the layout rules.
  var n = pointAt + exponent
  let firstNonZero = digits.find({'1'..'9'})
  digits = digits[firstNonZero .. ^1]
  n -= firstNonZero
  digits.removeSuffix('0')
  let k = digits.len
  if x < 0: result.add('-')
  if k <= n and n <= 21:
    result.add(digits)
    result.add(repeat('0', n - k))
  elif 0 < n and n <= 21:
    result.add(digits[0 ..< n])
    result.add('.')
    result.add(digits[n .. ^1])
  elif -6 < n and n <= 0:
    result.add("0.")
    result.add(repeat('0', -n))
    result.add(digits)
  else:
    result.add(digits[0])
    if k > 1:
      result.add('.')
      result.add(digits[1 .. ^1])
    result.add('e')
    result.add(if n - 1 >= 0: '+' else: '-')
    result.add($abs(n - 1))

# ============================================================================
# Strings
#
# ``JSON.stringify`` escapes only what JSON requires: the quote, the
# backslash and the C0 controls, using the short forms where JSON has them
# and ``\u00XX`` with lowercase hex otherwise. Everything else, including
# U+007F and non-ASCII, is written as UTF-8.
# ============================================================================

proc addEcmaString(output: var string, s: string) {.raises: [YamlJcsError].} =
  if s.validateUtf8 >= 0:
    raise jcsError("string is not valid UTF-8: " & escape(s))
  output.add('"')
  for c in s:
    case c
    of '"': output.add("\\\"")
    of '\\': output.add("\\\\")
    of '\b': output.add("\\b")
    of '\t': output.add("\\t")
    of '\n': output.add("\\n")
    of '\f': output.add("\\f")
    of '\r': output.add("\\r")
    of '\0'..'\x07', '\x0B', '\x0E'..'\x1F':
      output.add("\\u00")
      output.add(toHex(ord(c), 2).toLowerAscii)
    else: output.add(c)
  output.add('"')

# ============================================================================
# Member order
#
# JCS sorts member names by their UTF-16 code units, as ECMAScript compares
# strings. That differs from sorting by code points (or UTF-8 bytes) only
# for characters beyond U+FFFF, whose surrogates sort below U+E000..U+FFFF;
# but that difference is exactly what the test vectors check.
# ============================================================================

proc utf16(s: string): seq[uint16] =
  for rune in s.runes:
    let c = int(rune)
    if c < 0x10000: result.add(uint16(c))
    else:
      result.add(uint16(0xD800 + ((c - 0x10000) shr 10)))
      result.add(uint16(0xDC00 + ((c - 0x10000) and 0x3FF)))

proc cmpUnits(a, b: seq[uint16]): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return cmp(a[i], b[i])
  result = cmp(a.len, b.len)

# ============================================================================
# Values
# ============================================================================

proc addCanonical(output: var string, node: YamlNode,
    ancestors: var HashSet[pointer]) {.raises: [YamlJcsError].} =
  if node.kind == yScalar:
    let scalar = node.jsonScalar
    case scalar.kind
    of jkNull: output.add("null")
    of jkBool: output.add(if scalar.boolean: "true" else: "false")
    of jkNumber:
      output.add(ecmaNumber(
        if scalar.number.isInteger: float64(scalar.number.integer)
        else: scalar.number.float))
    of jkString: output.addEcmaString(scalar.str)
    of jkArray, jkObject: discard # not scalars
    return
  if ancestors.containsOrIncl(cast[pointer](node)):
    raise jcsError("a cyclic graph has no JSON value")
  case node.kind
  of ySequence:
    output.add('[')
    for i, item in node.elems:
      if i > 0: output.add(',')
      output.addCanonical(item, ancestors)
    output.add(']')
  of yMapping:
    var
      members: seq[tuple[order: seq[uint16], name: string, value: YamlNode]]
      names = initHashSet[string]()
    for key, value in node.fields.pairs:
      if not key.isStringKey:
        raise jcsError("JSON has no counterpart for the mapping key " & $key)
      if names.containsOrIncl(key.content):
        raise jcsError("the member name " & escape(key.content) &
            " is spelled by several keys")
      members.add((key.content.utf16, key.content, value))
    members.sort(proc(a, b: auto): int = cmpUnits(a.order, b.order))
    output.add('{')
    for i, member in members:
      if i > 0: output.add(',')
      output.addEcmaString(member.name)
      output.add(':')
      output.addCanonical(member.value, ancestors)
    output.add('}')
  of yScalar: discard # handled above
  ancestors.excl(cast[pointer](node))

proc canonicalJson*(node: YamlNode): string {.raises: [YamlJcsError].} =
  ## Returns the JCS canonical form of ``node``, read as JSON. Raises
  ## ``YamlJcsError`` where the graph has no faithful JSON value, as listed
  ## in the module documentation.
  var ancestors = initHashSet[pointer]()
  result.addCanonical(node, ancestors)
