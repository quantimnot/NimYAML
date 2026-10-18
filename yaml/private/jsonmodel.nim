#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## The JSON data model, seen through a YAML representation graph.
##
## JSON Pointer and JSONPath are defined on JSON values, but NimYAML hands
## them ``YamlNode`` graphs: scalars carry tags instead of types, mapping
## keys can be any node, and aliases can make the graph cyclic. This module
## is the one place that decides how such a graph reads as JSON, so that
## ``yaml/fragment`` and ``yaml/jsonpath`` agree on it:
##
## * A scalar's JSON type follows its tag. The non-specific tag ``!`` (quoted
##   scalars) and ``!!str`` make strings, and ``!!null``, ``!!bool``,
##   ``!!int`` and ``!!float`` the respective types if the content is valid
##   for them. A plain scalar (tag ``?``) is resolved with the YAML 1.2 core
##   schema. Anything else, including scalars with application-specific tags,
##   is a string, since that is all JSON could represent of them.
## * Only mapping keys that are unmistakably strings name JSON object members:
##   scalars tagged ``!`` or ``!!str``, and plain scalars that the core schema
##   resolves to strings. A mapping key like ``0``, ``!custom a`` or
##   ``{a: b}`` has no counterpart in JSON, so its member is invisible here,
##   rather than renamed to something that would not round-trip. (Values with
##   an application-specific tag do read as strings, because every value has
##   to be *some* JSON value, while a key can simply be left out.)
## * Merge keys (``<<``) are not applied; ``<<`` is just another member.
##
## Numbers keep the distinction between integers and floats, so that integer
## comparisons stay exact beyond 2^53. A plain integer too large for
## ``int64`` becomes a float.

import std/[sets, strutils, tables]
import ../data, ../dom, ../hints

type
  JsonKind* = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject

  JsonNumber* = object
    ## A JSON number, either an exact integer or a float.
    case isInteger*: bool
    of true: integer*: int64
    of false: float*: float64

  JsonScalar* = object
    ## The JSON value of a scalar node, or of a literal in a query.
    case kind*: JsonKind
    of jkNull, jkArray, jkObject: discard
    of jkBool: boolean*: bool
    of jkNumber: number*: JsonNumber
    of jkString: str*: string

proc parseNumber(content: string, hint: TypeHint, number: var JsonNumber):
    bool {.raises: [].} =
  ## Converts scalar content that ``guessType`` classified as ``hint``.
  case hint
  of yTypeInteger:
    try: number = JsonNumber(isInteger: true, integer: parseBiggestInt(content))
    except ValueError:
      try: number = JsonNumber(isInteger: false, float: parseFloat(content))
      except ValueError: return false
  of yTypeFloat:
    try: number = JsonNumber(isInteger: false, float: parseFloat(content))
    except ValueError: return false
  of yTypeFloatInf:
    number = JsonNumber(isInteger: false,
        float: if content[0] == '-': NegInf else: Inf)
  of yTypeFloatNaN: number = JsonNumber(isInteger: false, float: NaN)
  else: return false
  result = true

proc jsonScalar*(node: YamlNode): JsonScalar {.raises: [].} =
  ## Returns the JSON value of the scalar ``node`` as described in the module
  ## documentation.
  assert node.kind == yScalar
  let hint =
    if node.tag in [yTagQuestionMark, yTagNull, yTagBoolean, yTagInteger,
        yTagFloat]: guessType(node.content)
    else: yTypeUnknown
  if node.tag == yTagQuestionMark or node.tag == yTagNull:
    if hint == yTypeNull: return JsonScalar(kind: jkNull)
  if node.tag == yTagQuestionMark or node.tag == yTagBoolean:
    if hint in {yTypeBoolTrue, yTypeBoolFalse}:
      return JsonScalar(kind: jkBool, boolean: hint == yTypeBoolTrue)
  if node.tag in [yTagQuestionMark, yTagInteger, yTagFloat]:
    var number: JsonNumber
    if node.content.parseNumber(hint, number):
      if node.tag == yTagFloat and number.isInteger:
        number = JsonNumber(isInteger: false, float: float64(number.integer))
      return JsonScalar(kind: jkNumber, number: number)
  result = JsonScalar(kind: jkString, str: node.content)

proc jsonKind*(node: YamlNode): JsonKind {.raises: [].} =
  case node.kind
  of yScalar: node.jsonScalar.kind
  of ySequence: jkArray
  of yMapping: jkObject

proc isStringKey*(node: YamlNode): bool {.raises: [].} =
  ## Whether ``node``, used as mapping key, names a JSON object member.
  if node.kind != yScalar: return false
  if node.tag == yTagString or node.tag == yTagExclamationMark: return true
  if node.tag != yTagQuestionMark: return false
  # timestamps are not part of the core schema and thus stay strings
  result = guessType(node.content) in {yTypeUnknown, yTypeTimestamp}

iterator members*(node: YamlNode): tuple[name: string, value: YamlNode]
    {.raises: [].} =
  ## Yields the JSON object members of the mapping ``node``: the values of
  ## its string keys.
  assert node.kind == yMapping
  for key, value in node.fields.pairs:
    if key.isStringKey: yield (key.content, value)

proc member*(node: YamlNode, name: string): YamlNode {.raises: [].} =
  ## Returns the value of the member ``name`` of the mapping ``node``, or
  ## ``nil``. Looks up each tag a string key can have instead of scanning
  ## all keys. If several keys spell ``name`` (``a``, ``"a"`` and
  ## ``!!str a`` are distinct YAML nodes), the quoted one wins; JSON leaves
  ## duplicate member names undefined.
  assert node.kind == yMapping
  for tag in [yTagExclamationMark, yTagString, yTagQuestionMark]:
    let key = YamlNode(kind: yScalar, tag: tag, content: name)
    result = node.fields.getOrDefault(key)
    if not isNil(result) and key.isStringKey: return
  result = nil

proc toFloat(n: JsonNumber): float64 =
  if n.isInteger: float64(n.integer) else: n.float

proc `==`*(a, b: JsonNumber): bool {.raises: [].} =
  if a.isInteger and b.isInteger: a.integer == b.integer
  else: a.toFloat == b.toFloat

proc `<`*(a, b: JsonNumber): bool {.raises: [].} =
  if a.isInteger and b.isInteger: a.integer < b.integer
  else: a.toFloat < b.toFloat

proc `==`*(a, b: JsonScalar): bool {.raises: [].} =
  if a.kind != b.kind: return false
  case a.kind
  of jkNull: true
  of jkBool: a.boolean == b.boolean
  of jkNumber: a.number == b.number
  of jkString: a.str == b.str
  of jkArray, jkObject: false # not scalars

proc jsonEqualsImpl(a, b: YamlNode,
    assumedEqual: var HashSet[(pointer, pointer)]): bool {.raises: [].} =
  if cast[pointer](a) == cast[pointer](b): return true
  if a.kind == yScalar or b.kind == yScalar:
    return a.kind == b.kind and a.jsonScalar == b.jsonScalar
  if a.kind != b.kind: return false
  # Cyclic graphs: if this pair is already being compared further up, the
  # comparison holds unless something else differs.
  if assumedEqual.containsOrIncl((cast[pointer](a), cast[pointer](b))):
    return true
  case a.kind
  of ySequence:
    if a.elems.len != b.elems.len: return false
    for i in 0 ..< a.elems.len:
      if not jsonEqualsImpl(a.elems[i], b.elems[i], assumedEqual): return false
    result = true
  of yMapping:
    var count = 0
    for name, value in a.members:
      inc(count)
      let other = b.member(name)
      if isNil(other) or not jsonEqualsImpl(value, other, assumedEqual):
        return false
    for _ in b.members: dec(count)
    result = count == 0
  of yScalar: discard # handled above

proc jsonEquals*(a, b: YamlNode): bool {.raises: [].} =
  ## Whether ``a`` and ``b`` are equal as JSON values: numbers by value,
  ## arrays element-wise, objects member-wise regardless of order. Tags,
  ## styles and invisible members do not matter.
  var assumedEqual = initHashSet[(pointer, pointer)]()
  result = jsonEqualsImpl(a, b, assumedEqual)

proc jsonEquals*(a: YamlNode, b: JsonScalar): bool {.raises: [].} =
  a.kind == yScalar and a.jsonScalar == b
