#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ====================
## Module yaml/jsonpath
## ====================
##
## Selects nodes from a YAML representation graph with `JSONPath
## <https://www.rfc-editor.org/rfc/rfc9535>`_ (RFC 9535) queries such as
## ``$.store.book[?@.price < 10].title``.
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, jsonpath]
##
##   let root = loadAs[YamlNode]("""
##   store:
##     book:
##       - {title: Sayings of the Century, price: 8.95}
##       - {title: Moby Dick, price: 22.99}
##   """)
##   for node in root.query("$.store.book[?@.price < 10].title"):
##     echo node.content                 # Sayings of the Century
##   for found in root.queryLocated("$..price"):
##     echo found.path                   # $['store']['book'][0]['price'], ...
##
## The whole of RFC 9535 is implemented: all selectors and segments, filter
## expressions, the well-typedness rules for function extensions and the five
## standard functions ``length``, ``count``, ``match``, ``search`` and
## ``value``. ``match`` and ``search`` take `I-Regexp
## <https://www.rfc-editor.org/rfc/rfc9485>`_ patterns, which NimYAML matches
## with its own engine (Unicode General Categories included), so there is no
## dependency on PCRE. The implementation passes the `JSONPath Compliance
## Test Suite <https://github.com/jsonpath-standard/jsonpath-compliance-test-suite>`_.
##
## Queries are parsed once into a ``JsonPath`` and can then be applied to any
## number of documents. Malformed and ill-typed queries raise
## ``YamlJsonPathError`` when parsed; applying a valid query never fails,
## since RFC 9535 defines a result for every input.
##
## YAML is not JSON
## ----------------
##
## RFC 9535 is defined on JSON values; a ``YamlNode`` graph reads as one the
## way ``yaml/fragment`` reads it for JSON Pointers:
##
## * Scalars get their JSON type from their tag, with plain scalars resolved
##   by the YAML 1.2 core schema: ``1.5`` is a number, ``"1.5"`` a string.
## * Only string keys name members. A member whose key is ``0`` or
##   ``{a: b}`` is not selected by any selector, not even ``*``, because no
##   normalized path could name it.
## * Mapping order is not preserved by ``YamlNode``, so members are visited
##   in no particular order. RFC 9535 allows that.
## * Aliases are followed, so a node reachable along two paths is selected
##   once per path. On a cyclic graph, the descendant segment ``..`` does not
##   descend into a node that is already among the ancestors of the current
##   one; without that, ``$..*`` would never end.
##
## Results are the nodes of the graph themselves, not copies, so they keep
## their tags, styles and positions.

import std/[strutils, unicode, sets]
import dom, private/[jsonmodel, iregexp]

when defined(nimPreviewSlimSystem):
  import std/assertions

type
  YamlJsonPathError* = object of ValueError
    ## Raised for a JSONPath query that is not valid according to RFC 9535,
    ## either syntactically or because it is not well-typed.
    query*: string ## the offending query
    pos*: int      ## byte offset in ``query`` where the problem was found

  LocatedNode* = object
    ## A node selected by a query, together with its location.
    path*: string  ## the Normalized Path of ``node``, e.g. ``$['a'][0]``
    node*: YamlNode

# ============================================================================
# The query tree
#
# A query is a list of segments, each a list of selectors; filter selectors
# contain logical expressions, which in turn contain queries. The parser
# produces this tree and checks it, the evaluator walks it.
# ============================================================================

type
  SelectorKind = enum
    skName, skWildcard, skIndex, skSlice, skFilter

  Selector = object
    case kind: SelectorKind
    of skName: name: string
    of skWildcard: discard
    of skIndex: index: int64
    of skSlice:
      start, stop: int64
      hasStart, hasStop: bool
      step: int64
    of skFilter: filter: Expression

  Segment = object
    descendant: bool
    selectors: seq[Selector]

  Query = object
    relative: bool  ## starts at ``@`` instead of ``$``
    singular: bool  ## matches the grammar of a singular query
    segments: seq[Segment]

  ExpressionKind = enum
    ekOr, ekAnd, ekNot, ekComparison, ekQuery, ekFunction, ekLiteral

  ComparisonOperator = enum
    coEqual = "==", coNotEqual = "!=", coLessOrEqual = "<=",
    coGreaterOrEqual = ">=", coLess = "<", coGreater = ">"

  JsonPathType = enum
    ## The types of RFC 9535, Section 2.4.1, which make function extensions
    ## and their arguments type-checkable.
    ValueType, LogicalType, NodesType

  Function = enum
    fLength = "length", fCount = "count", fMatch = "match",
    fSearch = "search", fValue = "value"

  Expression = ref object
    pos: int  ## where in the query the expression starts, for errors
    case kind: ExpressionKind
    of ekOr, ekAnd: operands: seq[Expression]
    of ekNot: operand: Expression
    of ekComparison:
      operator: ComparisonOperator
      left, right: Expression
    of ekQuery: query: Query
    of ekFunction:
      function: Function
      arguments: seq[Expression]
      pattern: IRegexp        ## ``match``/``search`` with a literal pattern
      patternState: PatternState
    of ekLiteral: literal: JsonScalar

  PatternState = enum
    psDynamic  ## the pattern is computed per node
    psValid    ## ``pattern`` holds the compiled literal pattern
    psInvalid  ## the literal pattern is not an I-Regexp; never matches

  JsonPath* = object
    ## A parsed and type-checked JSONPath query.
    source: string
    query: Query

const
  resultType: array[Function, JsonPathType] = [
    fLength: ValueType, fCount: ValueType, fMatch: LogicalType,
    fSearch: LogicalType, fValue: ValueType]
  parameterTypes: array[Function, seq[JsonPathType]] = [
    fLength: @[ValueType], fCount: @[NodesType],
    fMatch: @[ValueType, ValueType], fSearch: @[ValueType, ValueType],
    fValue: @[NodesType]]
  maxSafeInteger = 9007199254740991'i64
    ## 2^53 - 1: indexes and slice bounds must lie within the I-JSON range

proc `$`*(path: JsonPath): string = path.source
  ## Returns the query text ``path`` was parsed from.

proc isSingular*(path: JsonPath): bool = path.query.singular
  ## Whether ``path`` is a singular query, which selects at most one node.

# ============================================================================
# Parsing
#
# A hand-written recursive descent parser over the bytes of the query,
# following the ABNF of RFC 9535 closely enough that each proc names the
# production it parses. The grammar is unambiguous with one exception:
# function arguments may be literals, queries or logical expressions, which
# all share prefixes. The parser therefore parses every argument as a logical
# expression that may degenerate to a lone literal, and the type check
# afterwards decides whether that is acceptable.
#
# Whitespace is significant: none is allowed around the query or between
# ``.`` and a member name, and a bracketed selector with inner whitespace is
# not part of a *singular* query.
# ============================================================================

type Parser = object
  query: string
  pos: int

{.push raises: [ValueError].}

proc fail(p: Parser, msg: string, pos = -1) {.noreturn.} =
  let at = if pos < 0: p.pos else: pos
  var e = newException(YamlJsonPathError, msg & " at position " & $at &
      " of JSONPath query " & escape(p.query))
  e.query = p.query
  e.pos = at
  raise e

proc atEnd(p: Parser): bool = p.pos >= p.query.len

proc peek(p: Parser, offset = 0): char =
  if p.pos + offset < p.query.len: p.query[p.pos + offset] else: '\0'

proc skipBlank(p: var Parser): bool {.discardable.} =
  ## Skips ``S``; returns whether there was any whitespace.
  let start = p.pos
  while p.peek in {' ', '\t', '\n', '\r'}: inc(p.pos)
  result = p.pos > start

proc expect(p: var Parser, c: char) =
  if p.peek != c:
    p.fail(if p.atEnd: "expected '" & c & "' but query ends"
           else: "expected '" & c & "'")
  inc(p.pos)

proc validateUtf8(p: Parser) =
  ## RFC 9535 queries are Unicode text. Rejecting invalid UTF-8 (including
  ## encoded surrogates) up front means the rest of the parser can treat
  ## every byte >= 0x80 as part of a valid non-ASCII character.
  var i = 0
  while i < p.query.len:
    let b = ord(p.query[i])
    var length, codePoint, minimum: int
    if b < 0x80: length = 1; codePoint = b
    elif b shr 5 == 0b110: length = 2; codePoint = b and 0x1F; minimum = 0x80
    elif b shr 4 == 0b1110: length = 3; codePoint = b and 0x0F; minimum = 0x800
    elif b shr 3 == 0b11110: length = 4; codePoint = b and 0x07; minimum = 0x10000
    else: p.fail("invalid UTF-8", i)
    if i + length > p.query.len: p.fail("invalid UTF-8", i)
    for j in 1 ..< length:
      let c = ord(p.query[i + j])
      if c shr 6 != 0b10: p.fail("invalid UTF-8", i)
      codePoint = codePoint shl 6 or (c and 0x3F)
    if codePoint < minimum or codePoint > 0x10FFFF or
        codePoint in 0xD800 .. 0xDFFF:
      p.fail("invalid UTF-8", i)
    i += length

# ----------------------------------------------------------------------------
# Literals
# ----------------------------------------------------------------------------

proc hexDigits(p: var Parser): int =
  ## Parses the four hex digits of a ``\u`` escape.
  for _ in 1 .. 4:
    let c = p.peek
    let digit = case c
      of '0'..'9': ord(c) - ord('0')
      of 'a'..'f': ord(c) - ord('a') + 10
      of 'A'..'F': ord(c) - ord('A') + 10
      else: p.fail("expected hex digit")
    result = result * 16 + digit
    inc(p.pos)

proc stringLiteral(p: var Parser): string =
  ## Parses ``string-literal`` in either quote style. Escapes produce UTF-8;
  ## ``\u`` escapes of surrogates must come as a high/low pair.
  let quote = p.peek
  inc(p.pos)
  while true:
    if p.atEnd: p.fail("unterminated string literal")
    let c = p.peek
    if c == quote:
      inc(p.pos)
      break
    if ord(c) < 0x20: p.fail("control character in string literal")
    if c != '\\':
      result.add(c)
      inc(p.pos)
      continue
    inc(p.pos)
    case p.peek
    of 'b': result.add('\b')
    of 'f': result.add('\f')
    of 'n': result.add('\n')
    of 'r': result.add('\r')
    of 't': result.add('\t')
    of '/': result.add('/')
    of '\\': result.add('\\')
    of '\'', '"':
      if p.peek != quote: p.fail("invalid escape of other quote character")
      result.add(quote)
    of 'u':
      inc(p.pos)
      var codePoint = p.hexDigits()
      if codePoint in 0xDC00 .. 0xDFFF: p.fail("unpaired low surrogate")
      if codePoint in 0xD800 .. 0xDBFF:
        if p.peek != '\\' or p.peek(1) != 'u':
          p.fail("high surrogate not followed by low surrogate")
        p.pos += 2
        let low = p.hexDigits()
        if low notin 0xDC00 .. 0xDFFF:
          p.fail("high surrogate not followed by low surrogate")
        codePoint = 0x10000 + (codePoint - 0xD800) shl 10 + (low - 0xDC00)
      result.add($Rune(codePoint))
      continue
    else: p.fail("invalid escape sequence")
    inc(p.pos)

proc integer(p: var Parser): int64 =
  ## Parses ``int`` (no leading zeros, no ``-0``) within the I-JSON range.
  let start = p.pos
  if p.peek == '-': inc(p.pos)
  if p.peek == '0':
    inc(p.pos)
    if p.query[start] == '-': p.fail("-0 is not a valid integer", start)
    if p.peek in Digits: p.fail("leading zero in integer", start)
    return 0
  if p.peek notin Digits: p.fail("expected integer")
  while p.peek in Digits:
    inc(p.pos)
    if p.pos - start > 17: p.fail("integer out of range", start)
  result = parseBiggestInt(p.query[start ..< p.pos])
  if result > maxSafeInteger or result < -maxSafeInteger:
    p.fail("integer out of range", start)

proc numberLiteral(p: var Parser): JsonScalar =
  ## Parses ``number``: like ``int`` but also ``-0``, a fraction and an
  ## exponent, and without the range restriction.
  let start = p.pos
  var isInteger = true
  if p.peek == '-': inc(p.pos)
  if p.peek == '0':
    inc(p.pos)
    if p.peek in Digits: p.fail("leading zero in number", start)
  elif p.peek in Digits:
    while p.peek in Digits: inc(p.pos)
  else: p.fail("expected number")
  if p.peek == '.':
    isInteger = false
    inc(p.pos)
    if p.peek notin Digits: p.fail("expected digit after '.'")
    while p.peek in Digits: inc(p.pos)
  if p.peek in {'e', 'E'}:
    isInteger = false
    inc(p.pos)
    if p.peek in {'+', '-'}: inc(p.pos)
    if p.peek notin Digits: p.fail("expected digit in exponent")
    while p.peek in Digits: inc(p.pos)
  let text = p.query[start ..< p.pos]
  if text == "-0": isInteger = false
  if isInteger:
    try:
      return JsonScalar(kind: jkNumber, number: JsonNumber(isInteger: true,
          integer: parseBiggestInt(text)))
    except ValueError: discard # too large for int64; use a float
  try:
    result = JsonScalar(kind: jkNumber, number: JsonNumber(isInteger: false,
        float: parseFloat(text)))
  except ValueError: p.fail("invalid number", start)

proc isNameFirst(c: char): bool = c in {'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF'}

proc memberNameShorthand(p: var Parser): string =
  if not p.peek.isNameFirst: p.fail("expected member name")
  let start = p.pos
  while p.peek.isNameFirst or p.peek in Digits: inc(p.pos)
  result = p.query[start ..< p.pos]

# ----------------------------------------------------------------------------
# Segments and selectors
# ----------------------------------------------------------------------------

proc logicalExpression(p: var Parser): Expression

proc segments(p: var Parser, query: var Query)

proc sliceOrIndex(p: var Parser): Selector =
  ## Parses ``index-selector`` or ``slice-selector``; they share the optional
  ## leading integer.
  var start: int64
  let hasStart = p.peek in {'-', '0'..'9'}
  if hasStart:
    start = p.integer()
    let beforeBlank = p.pos
    p.skipBlank()
    if p.peek != ':':
      p.pos = beforeBlank
      return Selector(kind: skIndex, index: start)
  if p.peek != ':': p.fail("expected selector")
  inc(p.pos)
  result = Selector(kind: skSlice, start: start, hasStart: hasStart, step: 1)
  p.skipBlank()
  if p.peek in {'-', '0'..'9'}:
    result.stop = p.integer()
    result.hasStop = true
    p.skipBlank()
  if p.peek == ':':
    inc(p.pos)
    p.skipBlank()
    if p.peek in {'-', '0'..'9'}: result.step = p.integer()

proc checkLogical(p: Parser, e: Expression)

proc selector(p: var Parser): Selector =
  case p.peek
  of '\'', '"': result = Selector(kind: skName, name: p.stringLiteral())
  of '*':
    inc(p.pos)
    result = Selector(kind: skWildcard)
  of '?':
    inc(p.pos)
    p.skipBlank()
    let filter = p.logicalExpression()
    p.checkLogical(filter)
    result = Selector(kind: skFilter, filter: filter)
  else: result = p.sliceOrIndex()

proc bracketedSelection(p: var Parser, segment: var Segment): bool =
  ## Parses ``bracketed-selection`` into ``segment``; returns whether it has
  ## the form of a singular query segment: one name or index selector with
  ## no whitespace inside the brackets.
  p.expect('[')
  var blank = p.skipBlank()
  segment.selectors.add(p.selector())
  while true:
    blank = p.skipBlank() or blank
    if p.peek != ',': break
    inc(p.pos)
    p.skipBlank()
    segment.selectors.add(p.selector())
  p.expect(']')
  result = not blank and segment.selectors.len == 1 and
      segment.selectors[0].kind in {skName, skIndex}

proc segment(p: var Parser, query: var Query) =
  var
    segment: Segment
    singular = false
  if p.peek == '.' and p.peek(1) == '.':
    p.pos += 2
    segment.descendant = true
    if p.peek == '[': discard p.bracketedSelection(segment)
    elif p.peek == '*':
      inc(p.pos)
      segment.selectors.add(Selector(kind: skWildcard))
    else:
      segment.selectors.add(Selector(kind: skName, name: p.memberNameShorthand()))
  elif p.peek == '.':
    inc(p.pos)
    if p.peek == '*':
      inc(p.pos)
      segment.selectors.add(Selector(kind: skWildcard))
    else:
      segment.selectors.add(Selector(kind: skName, name: p.memberNameShorthand()))
      singular = true
  else:
    singular = p.bracketedSelection(segment)
  query.singular = query.singular and singular
  query.segments.add(segment)

proc segments(p: var Parser, query: var Query) =
  ## Parses ``segments``. Whitespace before a segment belongs to it, but
  ## whitespace not followed by one belongs to whatever comes after.
  while true:
    let beforeBlank = p.pos
    p.skipBlank()
    if p.peek notin {'.', '['}:
      p.pos = beforeBlank
      return
    p.segment(query)

proc filterQuery(p: var Parser): Query =
  ## Parses ``rel-query`` or ``jsonpath-query`` inside a filter.
  result = Query(relative: p.peek == '@', singular: true)
  inc(p.pos)
  p.segments(result)

# ----------------------------------------------------------------------------
# Logical expressions
#
# Every expression is first parsed, then checked where it is used: as a
# filter or operand of ``&&``, ``||`` and ``!`` it must produce a logical
# value, as a comparison operand a value, and as a function argument
# whatever the parameter's type demands (RFC 9535, Section 2.4.3).
# ----------------------------------------------------------------------------

proc isComparable(e: Expression): bool =
  ## ``comparable``: a literal, a singular query or a function whose result
  ## is a value.
  case e.kind
  of ekLiteral: true
  of ekQuery: e.query.singular
  of ekFunction: resultType[e.function] == ValueType
  else: false

proc checkLogical(p: Parser, e: Expression) =
  ## Checks that ``e`` can be used where a logical value is expected:
  ## ``test-expr`` allows queries (testing for existence) and functions
  ## returning LogicalType or NodesType, but not values.
  case e.kind
  of ekLiteral: p.fail("a literal is not a valid filter test", e.pos)
  of ekFunction:
    if resultType[e.function] == ValueType:
      p.fail("result of " & $e.function & "() is a value and must be compared",
          e.pos)
  else: discard

proc checkArgument(p: Parser, function: Function, i: int, argument: Expression) =
  case parameterTypes[function][i]
  of ValueType:
    if not argument.isComparable:
      p.fail("argument " & $(i + 1) & " of " & $function &
          "() must be a value: a literal, a singular query or a function " &
          "returning a value", argument.pos)
  of LogicalType: p.checkLogical(argument)
  of NodesType:
    if argument.kind != ekQuery and not (argument.kind == ekFunction and
        resultType[argument.function] == NodesType):
      p.fail("argument " & $(i + 1) & " of " & $function &
          "() must be a query", argument.pos)

proc prepare(e: Expression) =
  ## Compiles the pattern of ``match`` and ``search`` ahead of time if it is
  ## a literal, instead of once for every node the filter is applied to.
  if e.function notin {fMatch, fSearch}: return
  let pattern = e.arguments[1]
  if pattern.kind != ekLiteral: return
  if pattern.literal.kind != jkString:
    e.patternState = psInvalid
    return
  try:
    e.pattern = compileIRegexp(pattern.literal.str)
    e.patternState = psValid
  except IRegexpError:
    e.patternState = psInvalid

proc functionExpression(p: var Parser, name: string, start: int): Expression =
  ## Parses the arguments of ``function-expr``, the name having been read.
  var function: Function
  try: function = parseEnum[Function](name)
  except ValueError: p.fail("unknown function " & name & "()", start)
  result = Expression(kind: ekFunction, pos: start, function: function)
  p.expect('(')
  p.skipBlank()
  if p.peek != ')':
    result.arguments.add(p.logicalExpression())
    while true:
      p.skipBlank()
      if p.peek != ',': break
      inc(p.pos)
      p.skipBlank()
      result.arguments.add(p.logicalExpression())
  p.skipBlank()
  p.expect(')')
  if result.arguments.len != parameterTypes[function].len:
    p.fail($function & "() takes " & $parameterTypes[function].len &
        " argument(s), not " & $result.arguments.len, start)
  for i, argument in result.arguments:
    p.checkArgument(function, i, argument)
  result.prepare()

proc primary(p: var Parser): Expression =
  ## Parses a literal, a query or a function call: the operands of
  ## comparisons and the things a test expression can test.
  let start = p.pos
  case p.peek
  of '@', '$':
    result = Expression(kind: ekQuery, pos: start, query: p.filterQuery())
  of '\'', '"':
    result = Expression(kind: ekLiteral, pos: start,
        literal: JsonScalar(kind: jkString, str: p.stringLiteral()))
  of '-', '0'..'9':
    result = Expression(kind: ekLiteral, pos: start, literal: p.numberLiteral())
  of 'a'..'z':
    while p.peek in {'a'..'z', '0'..'9', '_'}: inc(p.pos)
    let name = p.query[start ..< p.pos]
    if p.peek == '(': return p.functionExpression(name, start)
    case name
    of "true", "false":
      result = Expression(kind: ekLiteral, pos: start,
          literal: JsonScalar(kind: jkBool, boolean: name == "true"))
    of "null":
      result = Expression(kind: ekLiteral, pos: start,
          literal: JsonScalar(kind: jkNull))
    else: p.fail("unexpected " & escape(name), start)
  else:
    p.fail(if p.atEnd: "filter expression ends prematurely"
           else: "unexpected character in filter expression")

proc comparisonOperator(p: var Parser, operator: var ComparisonOperator): bool =
  for candidate in ComparisonOperator:
    if p.query.continuesWith($candidate, p.pos):
      operator = candidate
      p.pos += len($candidate)
      return true

proc basicExpression(p: var Parser): Expression =
  ## Parses ``basic-expr``: a parenthesized or negated expression, a
  ## comparison or a test.
  let start = p.pos
  if p.peek == '!':
    inc(p.pos)
    p.skipBlank()
    let operand =
      if p.peek == '(': p.basicExpression()
      else: p.primary()
    if operand.kind == ekQuery or operand.kind == ekFunction:
      p.checkLogical(operand)
    elif operand.kind == ekLiteral:
      p.fail("a literal cannot be negated", operand.pos)
    return Expression(kind: ekNot, pos: start, operand: operand)
  if p.peek == '(':
    inc(p.pos)
    p.skipBlank()
    result = p.logicalExpression()
    p.checkLogical(result)
    p.skipBlank()
    p.expect(')')
    return
  result = p.primary()
  let beforeBlank = p.pos
  p.skipBlank()
  var operator: ComparisonOperator
  if not p.comparisonOperator(operator):
    p.pos = beforeBlank
    return # a test, or a lone literal; the caller checks which is allowed
  p.skipBlank()
  let right = p.primary()
  for operand in [result, right]:
    if not operand.isComparable:
      p.fail("comparison operand must be a literal, a singular query or a " &
          "function returning a value", operand.pos)
  result = Expression(kind: ekComparison, pos: start, operator: operator,
      left: result, right: right)

proc junction(p: var Parser, kind: ExpressionKind, operator: string,
    operand: proc(p: var Parser): Expression {.nimcall, raises: [ValueError].}): Expression =
  ## Parses one or more operands separated by ``operator``. Every operand of
  ## an actual junction must be logical; a single operand is returned as is.
  let start = p.pos
  result = p.operand()
  while true:
    let beforeBlank = p.pos
    p.skipBlank()
    if not p.query.continuesWith(operator, p.pos):
      p.pos = beforeBlank
      return
    p.pos += operator.len
    p.skipBlank()
    if result.kind != kind:
      p.checkLogical(result)
      result =
        if kind == ekAnd: Expression(kind: ekAnd, pos: start, operands: @[result])
        else: Expression(kind: ekOr, pos: start, operands: @[result])
    let next = p.operand()
    p.checkLogical(next)
    result.operands.add(next)

proc logicalAnd(p: var Parser): Expression =
  p.junction(ekAnd, "&&", basicExpression)

proc logicalExpression(p: var Parser): Expression =
  ## Parses ``logical-expr``, also accepting a lone literal; see
  ## ``checkLogical`` for where that is rejected.
  p.junction(ekOr, "||", logicalAnd)

{.pop.}

proc parseJsonPath*(query: string): JsonPath {.raises: [YamlJsonPathError].} =
  ## Parses ``query`` as a JSONPath query (``jsonpath-query`` in RFC 9535).
  ## Raises ``YamlJsonPathError`` if it is malformed or not well-typed.
  var p = Parser(query: query)
  try:
    p.validateUtf8()
    if p.peek != '$': p.fail("query must start with '$'")
    inc(p.pos)
    result = JsonPath(source: query, query: Query(singular: true))
    p.segments(result.query)
    if not p.atEnd: p.fail("unexpected character")
  except YamlJsonPathError as e: raise e
  except ValueError as e:
    var error = newException(YamlJsonPathError, "invalid JSONPath query " &
        escape(query) & ": " & e.msg)
    error.query = query
    error.pos = p.pos
    raise error

# ============================================================================
# Normalized Paths
#
# RFC 9535, Section 2.7 defines one canonical spelling for every location:
# bracket notation, single quotes and a minimal, fixed set of escapes, so
# that two locations are equal exactly if their paths are.
# ============================================================================

proc addNameSegment(path: var string, name: string) =
  path.add("['")
  for c in name:
    case c
    of '\b': path.add("\\b")
    of '\f': path.add("\\f")
    of '\n': path.add("\\n")
    of '\r': path.add("\\r")
    of '\t': path.add("\\t")
    of '\'': path.add("\\'")
    of '\\': path.add("\\\\")
    of '\0'..'\x07', '\x0B', '\x0E'..'\x1F':
      path.add("\\u00" & toHex(ord(c), 2).toLowerAscii)
    else: path.add(c)
  path.add("']")

# ============================================================================
# Evaluation
#
# Each segment maps a list of nodes to a list of nodes. Paths are built only
# for the outermost query and only if asked for; queries inside filters need
# just the nodes. Filter expressions follow Section 2.3.5.2: comparisons are
# total (a mismatch of types is simply false) and evaluate to booleans, so
# evaluation cannot fail.
# ============================================================================

type
  Context = object
    root: YamlNode
    withPaths: bool

  ValueKind = enum
    vkNothing  ## the empty result of a singular query or function
    vkNode     ## a node of the document
    vkScalar   ## a literal or computed scalar

  Value = object
    ## ValueType: a JSON value or Nothing.
    case kind: ValueKind
    of vkNothing: discard
    of vkNode: node: YamlNode
    of vkScalar: scalar: JsonScalar

{.push raises: [].}

proc test(ctx: Context, e: Expression, current: YamlNode): bool

proc add(output: var seq[LocatedNode], ctx: Context, node: YamlNode,
    parentPath: string, name: string) =
  var path: string
  if ctx.withPaths:
    path = parentPath
    path.addNameSegment(name)
  output.add(LocatedNode(path: path, node: node))

proc add(output: var seq[LocatedNode], ctx: Context, node: YamlNode,
    parentPath: string, index: int) =
  var path: string
  if ctx.withPaths: path = parentPath & "[" & $index & "]"
  output.add(LocatedNode(path: path, node: node))

proc normalizeIndex(i, length: int64): int64 =
  if i >= 0: i else: length + i

proc selectSlice(ctx: Context, s: Selector, input: LocatedNode,
    output: var seq[LocatedNode]) =
  ## The slice algorithm of RFC 9535, Section 2.3.4.2.2.
  let length = int64(input.node.elems.len)
  if s.step == 0: return
  let
    start = if s.hasStart: s.start elif s.step > 0: 0'i64 else: length - 1
    stop = if s.hasStop: s.stop elif s.step > 0: length else: -length - 1
    normalStart = normalizeIndex(start, length)
    normalStop = normalizeIndex(stop, length)
  if s.step > 0:
    let
      lower = min(max(normalStart, 0), length)
      upper = min(max(normalStop, 0), length)
    var i = lower
    while i < upper:
      output.add(ctx, input.node.elems[i], input.path, int(i))
      i += s.step
  else:
    let
      upper = min(max(normalStart, -1), length - 1)
      lower = min(max(normalStop, -1), length - 1)
    var i = upper
    while lower < i:
      output.add(ctx, input.node.elems[i], input.path, int(i))
      i += s.step

proc select(ctx: Context, s: Selector, input: LocatedNode,
    output: var seq[LocatedNode]) =
  let node = input.node
  case s.kind
  of skName:
    if node.kind == yMapping:
      let value = node.member(s.name)
      if not isNil(value): output.add(ctx, value, input.path, s.name)
  of skWildcard:
    case node.kind
    of ySequence:
      for i, item in node.elems: output.add(ctx, item, input.path, i)
    of yMapping:
      for name, value in node.members: output.add(ctx, value, input.path, name)
    of yScalar: discard
  of skIndex:
    if node.kind == ySequence:
      let i = normalizeIndex(s.index, int64(node.elems.len))
      if i >= 0 and i < int64(node.elems.len):
        output.add(ctx, node.elems[i], input.path, int(i))
  of skSlice:
    if node.kind == ySequence: ctx.selectSlice(s, input, output)
  of skFilter:
    case node.kind
    of ySequence:
      for i, item in node.elems:
        if ctx.test(s.filter, item): output.add(ctx, item, input.path, i)
    of yMapping:
      for name, value in node.members:
        if ctx.test(s.filter, value): output.add(ctx, value, input.path, name)
    of yScalar: discard

proc selectDescendants(ctx: Context, segment: Segment, input: LocatedNode,
    ancestors: var HashSet[pointer], output: var seq[LocatedNode]) =
  ## Applies the selectors of a descendant segment to ``input`` and then to
  ## each of its descendants, parents before children and array items in
  ## order. ``ancestors`` guards against cycles created by aliases.
  for s in segment.selectors: ctx.select(s, input, output)
  let node = input.node
  if node.kind == yScalar: return
  ancestors.incl(cast[pointer](node))
  var children: seq[LocatedNode]
  if node.kind == ySequence:
    for i, item in node.elems: children.add(ctx, item, input.path, i)
  else:
    for name, value in node.members: children.add(ctx, value, input.path, name)
  for child in children:
    if cast[pointer](child.node) notin ancestors:
      ctx.selectDescendants(segment, child, ancestors, output)
  ancestors.excl(cast[pointer](node))

proc evaluate(ctx: Context, query: Query, start: LocatedNode): seq[LocatedNode] =
  result = @[start]
  for segment in query.segments:
    var output: seq[LocatedNode]
    for input in result:
      if segment.descendant:
        var ancestors = initHashSet[pointer]()
        ctx.selectDescendants(segment, input, ancestors, output)
      else:
        for s in segment.selectors: ctx.select(s, input, output)
    result = move(output)

proc nodes(ctx: Context, query: Query, current: YamlNode): seq[LocatedNode] =
  ## Evaluates a query inside a filter, relative to ``current`` or the root.
  let filterCtx = Context(root: ctx.root, withPaths: false)
  filterCtx.evaluate(query,
      LocatedNode(node: if query.relative: current else: ctx.root))

proc value(ctx: Context, e: Expression, current: YamlNode): Value

proc scalarOf(v: Value, scalar: var JsonScalar): bool =
  ## Returns the scalar ``v`` holds, if it holds one.
  case v.kind
  of vkNothing: false
  of vkScalar:
    scalar = v.scalar
    true
  of vkNode:
    if v.node.kind != yScalar: return false
    scalar = v.node.jsonScalar
    true

proc equals(a, b: Value): bool =
  if a.kind == vkNothing or b.kind == vkNothing:
    return a.kind == b.kind
  if a.kind == vkNode and b.kind == vkNode: return jsonEquals(a.node, b.node)
  if a.kind == vkNode: return jsonEquals(a.node, b.scalar)
  if b.kind == vkNode: return jsonEquals(b.node, a.scalar)
  result = a.scalar == b.scalar

proc less(a, b: Value): bool =
  ## Only numbers and strings are ordered; strings by code point, which for
  ## UTF-8 is byte order.
  var x, y: JsonScalar
  if not a.scalarOf(x) or not b.scalarOf(y) or x.kind != y.kind: return false
  case x.kind
  of jkNumber: x.number < y.number
  of jkString: x.str < y.str
  else: false

proc compare(operator: ComparisonOperator, a, b: Value): bool =
  case operator
  of coEqual: equals(a, b)
  of coNotEqual: not equals(a, b)
  of coLess: less(a, b)
  of coGreater: less(b, a)
  of coLessOrEqual: less(a, b) or equals(a, b)
  of coGreaterOrEqual: less(b, a) or equals(a, b)

proc number(n: int): Value =
  Value(kind: vkScalar, scalar: JsonScalar(kind: jkNumber,
      number: JsonNumber(isInteger: true, integer: int64(n))))

proc matchPattern(ctx: Context, e: Expression, current: YamlNode): bool =
  ## ``match()`` and ``search()``: false unless both arguments are strings
  ## and the pattern is a valid I-Regexp.
  var subject, patternText: JsonScalar
  if not ctx.value(e.arguments[0], current).scalarOf(subject) or
      subject.kind != jkString:
    return false
  var pattern: IRegexp
  case e.patternState
  of psValid: pattern = e.pattern
  of psInvalid: return false
  of psDynamic:
    if not ctx.value(e.arguments[1], current).scalarOf(patternText) or
        patternText.kind != jkString:
      return false
    try: pattern = compileIRegexp(patternText.str)
    except IRegexpError: return false
  result = if e.function == fMatch: pattern.matches(subject.str)
           else: pattern.matchesSubstring(subject.str)

proc value(ctx: Context, e: Expression, current: YamlNode): Value =
  ## Evaluates an expression of ValueType.
  case e.kind
  of ekLiteral: Value(kind: vkScalar, scalar: e.literal)
  of ekQuery:
    let found = ctx.nodes(e.query, current)
    if found.len == 1: Value(kind: vkNode, node: found[0].node)
    else: Value(kind: vkNothing)
  of ekFunction:
    case e.function
    of fLength:
      let argument = ctx.value(e.arguments[0], current)
      var scalar: JsonScalar
      if argument.kind == vkNode and argument.node.kind == ySequence:
        number(argument.node.elems.len)
      elif argument.kind == vkNode and argument.node.kind == yMapping:
        var count = 0
        for _ in argument.node.members: inc(count)
        number(count)
      elif argument.scalarOf(scalar) and scalar.kind == jkString:
        number(scalar.str.runeLen)
      else: Value(kind: vkNothing)
    of fCount: number(ctx.nodes(e.arguments[0].query, current).len)
    of fValue:
      let found = ctx.nodes(e.arguments[0].query, current)
      if found.len == 1: Value(kind: vkNode, node: found[0].node)
      else: Value(kind: vkNothing)
    of fMatch, fSearch: Value(kind: vkNothing) # LogicalType; rejected by parser
  else: Value(kind: vkNothing) # logical expressions are not values

proc test(ctx: Context, e: Expression, current: YamlNode): bool =
  ## Evaluates an expression of LogicalType, converting queries (and
  ## functions of NodesType) by testing whether they select anything.
  case e.kind
  of ekOr:
    for operand in e.operands:
      if ctx.test(operand, current): return true
    false
  of ekAnd:
    for operand in e.operands:
      if not ctx.test(operand, current): return false
    true
  of ekNot: not ctx.test(e.operand, current)
  of ekComparison:
    compare(e.operator, ctx.value(e.left, current), ctx.value(e.right, current))
  of ekQuery: ctx.nodes(e.query, current).len > 0
  of ekFunction:
    case e.function
    of fMatch, fSearch: ctx.matchPattern(e, current)
    else: false # ValueType; rejected by parser
  of ekLiteral: false # rejected by parser

{.pop.}

proc queryLocated*(root: YamlNode, path: JsonPath): seq[LocatedNode]
    {.raises: [].} =
  ## Applies ``path`` to the document ``root`` and returns the selected nodes
  ## along with their Normalized Paths, in the order RFC 9535 prescribes
  ## (except that mapping members come in no particular order).
  let ctx = Context(root: root, withPaths: true)
  result = ctx.evaluate(path.query, LocatedNode(path: "$", node: root))

proc queryLocated*(root: YamlNode, path: string): seq[LocatedNode]
    {.raises: [YamlJsonPathError].} =
  ## Parses ``path`` and applies it to ``root``.
  root.queryLocated(parseJsonPath(path))

proc query*(root: YamlNode, path: JsonPath): seq[YamlNode] {.raises: [].} =
  ## Applies ``path`` to the document ``root`` and returns the selected
  ## nodes. A node appears once for every path along which it was selected.
  let ctx = Context(root: root, withPaths: false)
  for found in ctx.evaluate(path.query, LocatedNode(node: root)):
    result.add(found.node)

proc query*(root: YamlNode, path: string): seq[YamlNode]
    {.raises: [YamlJsonPathError].} =
  ## Parses ``path`` and applies it to ``root``.
  root.query(parseJsonPath(path))
