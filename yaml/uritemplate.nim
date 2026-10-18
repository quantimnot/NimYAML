#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =======================
## Module yaml/uritemplate
## =======================
##
## Expands `URI Templates <https://www.rfc-editor.org/rfc/rfc6570>`_
## (RFC 6570) like ``/users/{id}{?fields*}`` at all four levels: every
## operator (``+ # . / ; ? &``), prefix modifiers (``{var:3}``) and exploded
## lists and associative arrays (``{var*}``).
##
## .. code-block:: nim
##
##   import yaml/uritemplate
##
##   let vars = {"id": tv"jo", "fields": tv(@["name", "age"])}.toTemplateVars
##   echo expand("/users/{id}{?fields*}", vars)
##   # /users/jo?fields=name&fields=age
##
## Values come from a ``TemplateVars`` table; a variable that is not in the
## table is *undefined* in the sense of RFC 6570, Section 2.3, as are empty
## lists and associative arrays. Values of a ``YamlNode`` graph can be
## converted with ``templateValue`` (JSON Hyper-Schema does this).
##
## Templates are parsed once with ``parseUriTemplate`` and can be expanded
## any number of times. Malformed templates raise ``UriTemplateError`` when
## parsed; applying a prefix modifier to a list or associative array raises
## it when expanded (RFC 6570, Section 2.4.1). The implementation passes the
## `uritemplate-test <https://github.com/uri-templates/uritemplate-test>`_
## suite.
##
## Besides full expansion, ``expandPartially`` expands only some of the
## variables and leaves the expressions of the others in place, which JSON
## Hyper-Schema uses for templates whose remaining variables are client
## input.

import std/[strutils, tables, unicode]
import dom, private/jsonmodel

when defined(nimPreviewSlimSystem):
  import std/assertions

type
  UriTemplateError* = object of ValueError
    ## Raised for malformed templates and for prefix modifiers applied to
    ## composite values.

  TemplateValueKind* = enum
    tvString, tvList, tvMap

  TemplateValue* = object
    ## The value of a template variable (RFC 6570, Section 2.3).
    case kind*: TemplateValueKind
    of tvString: str*: string
    of tvList: list*: seq[string]
    of tvMap: pairs*: seq[(string, string)]
      ## an associative array; the order of pairs is kept

  TemplateVars* = Table[string, TemplateValue]

  Operator = enum
    opSimple, opReserved, opFragment, opLabel, opPath, opParam, opQuery,
    opContinuation

  VarSpec = object
    name: string
    prefix: int ## 0 for none
    explode: bool

  PartKind = enum
    pkLiteral, pkExpression

  Part = object
    case kind: PartKind
    of pkLiteral: literal: string ## already encoded
    of pkExpression:
      operator: Operator
      vars: seq[VarSpec]
      source: string ## the expression as written, with braces

  UriTemplate* = object
    ## A parsed URI Template.
    source: string
    parts: seq[Part]

  OperatorInfo = tuple[first, sep: string, named: bool, ifEmpty: string,
      allowReserved: bool]

const operatorInfo: array[Operator, OperatorInfo] = [
  # RFC 6570, Appendix A
  opSimple:       ("", ",", false, "", false),
  opReserved:     ("", ",", false, "", true),
  opFragment:     ("#", ",", false, "", true),
  opLabel:        (".", ".", false, "", false),
  opPath:         ("/", "/", false, "", false),
  opParam:        (";", ";", true, "", false),
  opQuery:        ("?", "&", true, "=", false),
  opContinuation: ("&", "&", true, "=", false)]

const
  unreserved = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}
  reserved = {':', '/', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(',
      ')', '*', '+', ',', ';', '='}

proc tv*(s: string): TemplateValue = TemplateValue(kind: tvString, str: s)
proc tv*(list: seq[string]): TemplateValue =
  TemplateValue(kind: tvList, list: list)
proc tv*(pairs: seq[(string, string)]): TemplateValue =
  TemplateValue(kind: tvMap, pairs: pairs)

proc toTemplateVars*(pairs: openArray[(string, TemplateValue)]): TemplateVars =
  result = initTable[string, TemplateValue]()
  for (name, value) in pairs: result[name] = value

proc templateError(msg: string): ref UriTemplateError =
  newException(UriTemplateError, msg)

proc `$`*(t: UriTemplate): string = t.source

# ----------------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------------

proc isHex(s: string, i: int): bool =
  ## Whether ``s[i]`` starts a percent-encoded octet.
  i + 2 < s.len and s[i] == '%' and s[i + 1] in HexDigits and
      s[i + 2] in HexDigits

proc encodeByte(result: var string, c: char) =
  result.add('%')
  result.add(toHex(ord(c), 2))

proc parseVarName(s: string, i: var int, expression: string): string =
  ## varname = varchar *( ["."] varchar ), varchar = ALPHA / DIGIT / "_" /
  ## pct-encoded
  let start = i
  var lastDot = true
  while i < s.len:
    if s[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      inc(i)
      lastDot = false
    elif s[i] == '%' and isHex(s, i):
      i += 3
      lastDot = false
    elif s[i] == '.' and not lastDot:
      inc(i)
      lastDot = true
    else: break
  if i == start or lastDot:
    raise templateError("invalid variable name in " & expression)
  result = s[start ..< i]

proc parseExpression(expression: string): Part =
  ## Parses the content of ``{...}``; ``expression`` includes the braces.
  let s = expression[1 .. ^2]
  result = Part(kind: pkExpression, source: expression)
  var i = 0
  if s.len > 0:
    case s[0]
    of '+': result.operator = opReserved
    of '#': result.operator = opFragment
    of '.': result.operator = opLabel
    of '/': result.operator = opPath
    of ';': result.operator = opParam
    of '?': result.operator = opQuery
    of '&': result.operator = opContinuation
    of '=', ',', '!', '@', '|':
      raise templateError("reserved operator in " & expression)
    else: discard
    if result.operator != opSimple: inc(i)
  while true:
    var spec = VarSpec(name: parseVarName(s, i, expression))
    if i < s.len and s[i] == ':':
      inc(i)
      let start = i
      while i < s.len and s[i] in Digits and i - start < 5: inc(i)
      if i == start or i - start > 4 or s[start] == '0':
        raise templateError("invalid prefix length in " & expression)
      spec.prefix = parseInt(s[start ..< i])
    elif i < s.len and s[i] == '*':
      spec.explode = true
      inc(i)
    result.vars.add(spec)
    if i == s.len: break
    if s[i] != ',': raise templateError("invalid expression " & expression)
    inc(i)

proc parseUriTemplate*(source: string): UriTemplate
    {.raises: [UriTemplateError].} =
  ## Parses ``source`` as a URI Template (RFC 6570, Section 2).
  result = UriTemplate(source: source)
  var
    i = 0
    literal = ""
  while i < source.len:
    let c = source[i]
    if c == '{':
      let close = source.find('}', i)
      if close < 0: raise templateError("unclosed expression in " & source)
      if literal.len > 0:
        result.parts.add(Part(kind: pkLiteral, literal: literal))
        literal = ""
      try: result.parts.add(parseExpression(source[i .. close]))
      except ValueError as e: raise templateError(e.msg)
      i = close + 1
    elif c == '}': raise templateError("unmatched '}' in " & source)
    elif c == '%':
      if not isHex(source, i):
        raise templateError("invalid percent-encoding in " & source)
      literal.add(source[i .. i + 2])
      i += 3
    elif c in unreserved + reserved:
      literal.add(c)
      inc(i)
    elif ord(c) >= 0x80:
      # ucschar / iprivate: copied percent-encoded (Section 3.1)
      literal.encodeByte(c)
      inc(i)
    else:
      # CTL, SP, DQUOTE, "'", "<", ">", "\", "^", "`", "|"
      raise templateError("invalid character " & escape($c) & " in " & source)
  if literal.len > 0: result.parts.add(Part(kind: pkLiteral, literal: literal))

proc variables*(t: UriTemplate): seq[string] =
  ## The names of all variables in ``t``, in order of appearance, without
  ## duplicates. Names are as written, including any percent-encoding.
  for part in t.parts:
    if part.kind == pkExpression:
      for spec in part.vars:
        if spec.name notin result: result.add(spec.name)

# ----------------------------------------------------------------------------
# Expansion (RFC 6570, Section 3.2 and Appendix A)
# ----------------------------------------------------------------------------

proc encode(value: string, allowReserved: bool): string =
  var i = 0
  while i < value.len:
    let c = value[i]
    if c in unreserved: result.add(c)
    elif allowReserved and c in reserved: result.add(c)
    elif allowReserved and c == '%' and isHex(value, i):
      result.add(value[i .. i + 2])
      i += 2
    else: result.encodeByte(c)
    inc(i)

proc prefixOf(value: string, length: int): string =
  ## The first ``length`` characters (code points) of ``value``.
  var count = 0
  for r in value.runes:
    if count == length: break
    result.add(r.toUTF8)
    inc(count)

proc isDefined(value: TemplateValue): bool =
  case value.kind
  of tvString: true
  of tvList: value.list.len > 0
  of tvMap: value.pairs.len > 0

proc expandExpression(result: var string, part: Part, vars: TemplateVars) =
  let info = operatorInfo[part.operator]
  var first = true
  for spec in part.vars:
    let value = vars.getOrDefault(spec.name, TemplateValue(kind: tvList))
    if not value.isDefined: continue
    result.add(if first: info.first else: info.sep)
    first = false
    case value.kind
    of tvString:
      if info.named:
        result.add(encode(spec.name, true))
        if value.str.len == 0:
          result.add(info.ifEmpty)
          continue
        result.add('=')
      let s = if spec.prefix > 0: value.str.prefixOf(spec.prefix) else: value.str
      result.add(encode(s, info.allowReserved))
    of tvList, tvMap:
      if spec.prefix > 0:
        raise templateError("prefix modifier applied to composite value " &
            spec.name & " in " & part.source)
      var items: seq[(string, string)]
      if value.kind == tvList:
        for item in value.list: items.add(("", item))
      else: items = value.pairs
      if not spec.explode:
        if info.named:
          result.add(encode(spec.name, true))
          result.add('=')
        var firstItem = true
        for (key, item) in items:
          if not firstItem: result.add(',')
          firstItem = false
          if value.kind == tvMap:
            result.add(encode(key, info.allowReserved))
            result.add(',')
          result.add(encode(item, info.allowReserved))
      else:
        var firstItem = true
        for (key, item) in items:
          if not firstItem: result.add(info.sep)
          firstItem = false
          let name = if value.kind == tvMap: key else: spec.name
          if info.named or value.kind == tvMap:
            result.add(encode(name,
                value.kind == tvList or info.allowReserved))
            if item.len == 0 and info.named:
              result.add(info.ifEmpty)
              continue
            result.add('=')
          result.add(encode(item, info.allowReserved))

proc expand*(t: UriTemplate, vars: TemplateVars): string
    {.raises: [UriTemplateError].} =
  ## Expands ``t`` with the given variable values (RFC 6570, Section 3).
  for part in t.parts:
    case part.kind
    of pkLiteral: result.add(part.literal)
    of pkExpression: result.expandExpression(part, vars)

proc expand*(source: string, vars: TemplateVars): string
    {.raises: [UriTemplateError].} =
  ## Parses and expands ``source``.
  parseUriTemplate(source).expand(vars)

proc expandPartially*(t: UriTemplate, vars: TemplateVars,
    deferred: openArray[string]): string {.raises: [UriTemplateError].} =
  ## Expands the expressions of ``t`` that use none of the ``deferred``
  ## variables and copies the others unchanged, yielding a template in which
  ## only the deferred variables remain. A query expression (``{?a,b}``) that
  ## mixes both kinds is split: ``{?a,b}`` with ``b`` deferred and ``a=1``
  ## becomes ``?a=1{&b}``. Other mixed expressions are kept as they are,
  ## since no operator could continue them.
  for part in t.parts:
    case part.kind
    of pkLiteral: result.add(part.literal)
    of pkExpression:
      var now, later: seq[VarSpec]
      for spec in part.vars:
        if spec.name in deferred: later.add(spec)
        else: now.add(spec)
      if later.len == 0: result.expandExpression(part, vars)
      elif now.len == 0: result.add(part.source)
      elif part.operator in {opQuery, opContinuation}:
        let before = result.len
        result.expandExpression(Part(kind: pkExpression,
            operator: part.operator, vars: now, source: part.source), vars)
        let op = if part.operator == opQuery and result.len == before: "?"
                 else: "&"
        result.add("{" & op)
        for i, spec in later:
          if i > 0: result.add(',')
          result.add(spec.name)
          if spec.explode: result.add('*')
          elif spec.prefix > 0: result.add(":" & $spec.prefix)
        result.add('}')
      else: result.add(part.source)

proc isUriTemplate*(source: string): bool {.raises: [].} =
  ## Whether ``source`` is a syntactically valid URI Template.
  try:
    discard parseUriTemplate(source)
    result = true
  except UriTemplateError: result = false

proc stringValue(node: YamlNode): string =
  let scalar = node.jsonScalar
  case scalar.kind
  of jkNull: "null"
  of jkBool: (if scalar.boolean: "true" else: "false")
  of jkNumber, jkString: node.content
  of jkArray, jkObject: ""

proc templateValue*(node: YamlNode): TemplateValue {.raises: [].} =
  ## Converts a node to a template value the way JSON Hyper-Schema does
  ## (Section 7.2.3): ``true``, ``false`` and ``null`` become their names,
  ## numbers keep their original spelling, sequences become lists and
  ## mappings associative arrays (of their JSON members). Nested sequences
  ## and mappings, which RFC 6570 cannot express, become empty strings.
  case node.kind
  of yScalar: result = tv(node.stringValue)
  of ySequence:
    result = TemplateValue(kind: tvList)
    for item in node.elems: result.list.add(item.stringValue)
  of yMapping:
    result = TemplateValue(kind: tvMap)
    for (name, value) in node.orderedMembers:
      result.pairs.add((name, value.stringValue))
