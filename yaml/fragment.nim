#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ====================
## Module yaml/fragment
## ====================
##
## Resolves URI fragment identifiers against YAML content as defined by
## `RFC 9512, Section 1.2 <https://www.rfc-editor.org/rfc/rfc9512.html#section-1.2>`_
## for the ``application/yaml`` media type. These are the supported forms:
##
## ==================  =========================================================
## ``file.yaml#``      the root node (single-document streams only)
## ``file.yaml#/a/0``  a `JSON Pointer <https://www.rfc-editor.org/rfc/rfc6901>`_
##                     evaluated on the representation graph, traversing alias
##                     nodes (single-document streams only)
## ``file.yaml#*foo``  the first node in the stream whose anchor is ``foo``,
##                     in any document of the stream
## ==================  =========================================================
##
## Fragments of ``+yaml`` media types (e.g. ``application/openapi+yaml``) are
## defined by those types, not by RFC 9512.
##
## A JSON Pointer can only traverse nodes that are interoperable with the JSON
## data model: a mapping key matches only if it is a string scalar (a plain
## scalar that resolves to null, bool, int or float under the core schema does
## not match). Merge keys (``<<``) are not applied, so ``#/a/<<`` references
## the merged node rather than nothing.
##
## Fragments that do not reference an existing node raise
## ``YamlFragmentError``.
##
## ``resolveRelativePointer`` additionally evaluates `Relative JSON Pointers
## <https://www.ietf.org/archive/id/draft-hha-relative-json-pointer-00.html>`_
## like ``1/0`` or ``0+1#``, which reference nodes relative to a starting
## location. They are not fragment identifiers.

import std/[streams, strutils, tables]
import data, stream, parser, native, loading, dom, hints, private/internal

type
  YamlFragmentError* = object of ValueError
    ## Raised when a fragment identifier is malformed or does not reference an
    ## existing node.

  AnchorTargetState = enum
    atsSearching, atsRenaming, atsDone

  AnchorTargetStream = ref object of YamlStream
    ## Passes events through, renaming the first node anchored ``name`` and the
    ## aliases referring to it to ``targetAnchor`` so that it can be found in
    ## the construction context even if ``name`` is redefined later.
    source: YamlStream
    name: Anchor
    state: AnchorTargetState

  RelativePointerResultKind* = enum
    rprNode   ## the pointer references a node
    rprKey    ## the pointer ends in ``#`` and references a mapping value
    rprIndex  ## the pointer ends in ``#`` and references a sequence item

  RelativePointerResult* = object
    ## Result of evaluating a Relative JSON Pointer.
    case kind*: RelativePointerResultKind
    of rprNode: node*: YamlNode
    of rprKey: key*: string    ## the mapping key of the referenced value
    of rprIndex: index*: int   ## the sequence index of the referenced item

const targetAnchor = Anchor(" fragment target")
  ## contains a space and therefore cannot be produced by the parser

proc fragmentError(msg: string): ref YamlFragmentError =
  newException(YamlFragmentError, msg)

proc parseHexInt(c: char): int {.raises: [].} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  else: ord(c) - ord('A') + 10

proc percentDecode(fragment: string): string {.raises: [YamlFragmentError].} =
  result = newStringOfCap(fragment.len)
  var i = 0
  while i < fragment.len:
    if fragment[i] == '%':
      if i + 2 >= fragment.len or fragment[i + 1] notin HexDigits or
          fragment[i + 2] notin HexDigits:
        raise fragmentError("invalid percent-encoding in fragment: " & fragment)
      result.add(char(parseHexInt(fragment[i + 1]) * 16 +
          parseHexInt(fragment[i + 2])))
      i += 3
    else:
      result.add(fragment[i])
      inc(i)

proc unescapeToken(token: string): string {.raises: [YamlFragmentError].} =
  result = newStringOfCap(token.len)
  var i = 0
  while i < token.len:
    if token[i] == '~':
      if i + 1 < token.len and token[i + 1] in {'0', '1'}:
        result.add(if token[i + 1] == '0': '~' else: '/')
        i += 2
      else:
        raise fragmentError("invalid escape in JSON Pointer token: " & token)
    else:
      result.add(token[i])
      inc(i)

proc isStringKey(node: YamlNode, key: string): bool {.raises: [].} =
  if node.kind != yScalar or node.content != key: return false
  if node.tag == yTagString or node.tag == yTagExclamationMark: return true
  if node.tag != yTagQuestionMark: return false
  # timestamps are not part of the core schema and thus stay strings
  result = guessType(node.content) in {yTypeUnknown, yTypeTimestamp}

proc childAt(node: YamlNode, token, jsonPointer: string): tuple[child: YamlNode, index: int]
    {.raises: [YamlFragmentError].} =
  ## Evaluates the unescaped reference ``token`` on ``node``. ``index`` is the
  ## position of ``child`` if ``node`` is a sequence and ``-1`` otherwise.
  if isNil(node):
    raise fragmentError("no node at " & jsonPointer)
  case node.kind
  of yMapping:
    for key, value in node.pairs:
      if key.isStringKey(token):
        return (value, -1)
    raise fragmentError("no string key " & escape(token) & " at " &
        jsonPointer)
  of ySequence:
    if token.len == 0 or token.len > 1 and token[0] == '0' or
        not token.allCharsInSet(Digits):
      raise fragmentError("invalid sequence index " & escape(token) &
          " at " & jsonPointer)
    var index: int
    try: index = parseInt(token)
    except ValueError:
      raise fragmentError("sequence index out of range: " & token)
    if index >= node.elems.len:
      raise fragmentError("sequence index out of range: " & token)
    result = (node.elems[index], index)
  of yScalar:
    raise fragmentError("cannot descend into scalar at " & jsonPointer)

template forEachToken(jsonPointer: string, token, body: untyped) =
  if jsonPointer.len > 0 and jsonPointer[0] != '/':
    raise fragmentError("JSON Pointer must be empty or start with '/': " &
        jsonPointer)
  if jsonPointer.len > 0:
    for rawToken in jsonPointer[1 .. ^1].split('/'):
      let token = unescapeToken(rawToken)
      body

proc resolvePointer*(root: YamlNode, jsonPointer: string): YamlNode
    {.raises: [YamlFragmentError].} =
  ## Evaluates the given JSON Pointer (RFC 6901) on the representation graph
  ## starting at ``root``. ``jsonPointer`` must be empty (referencing ``root``)
  ## or start with ``/``, and must not be percent-encoded.
  result = root
  forEachToken(jsonPointer, token):
    result = result.childAt(token, jsonPointer).child

proc parseDigits(s: string, i: var int, positive: bool, relativePointer: string):
    int {.raises: [YamlFragmentError].} =
  let start = i
  while i < s.len and s[i] in Digits: inc(i)
  if i == start or (s[start] == '0' and (positive or i - start > 1)):
    raise fragmentError("invalid integer in Relative JSON Pointer: " &
        relativePointer)
  try: result = parseInt(s[start ..< i])
  except ValueError:
    raise fragmentError("integer out of range in Relative JSON Pointer: " &
        relativePointer)

proc resolveRelativePointer*(root: YamlNode, origin, relativePointer: string):
    RelativePointerResult {.raises: [YamlFragmentError].} =
  ## Evaluates the given `Relative JSON Pointer
  ## <https://www.ietf.org/archive/id/draft-hha-relative-json-pointer-00.html>`_
  ## on the representation graph starting at ``root``. Since alias nodes make a
  ## node reachable via multiple paths, the starting location is given as the
  ## JSON Pointer ``origin`` relative to ``root`` rather than as a node.
  ##
  ## A Relative JSON Pointer ending in ``#`` yields the key (``rprKey``) or
  ## index (``rprIndex``) of the referenced node within its parent; any other
  ## yields a node (``rprNode``). Mapping keys follow the same rules as in
  ## ``resolvePointer``. Relative JSON Pointers cannot be used as URI fragment
  ## identifiers.
  ##
  ## Raises ``YamlFragmentError`` if either pointer is malformed, if the
  ## pointer moves above ``root``, adjusts the index of a node that is not a
  ## sequence item, or references a nonexistent node, and if ``#`` is applied
  ## to ``root``.
  var
    nodes = @[root]  # nodes[i + 1] is the child of nodes[i]
    indexes: seq[int]  # index of nodes[i + 1] in nodes[i], or -1
    keys: seq[string]  # key of nodes[i + 1] in nodes[i], if any
  forEachToken(origin, token):
    let (child, index) = nodes[^1].childAt(token, origin)
    nodes.add(child)
    indexes.add(index)
    keys.add(token)

  var i = 0
  let levels = parseDigits(relativePointer, i, false, relativePointer)
  if levels > indexes.len:
    raise fragmentError("Relative JSON Pointer " & escape(relativePointer) &
        " moves above the root from " & escape(origin))
  nodes.setLen(nodes.len - levels)
  indexes.setLen(indexes.len - levels)
  keys.setLen(keys.len - levels)

  if i < relativePointer.len and relativePointer[i] in {'+', '-'}:
    let negative = relativePointer[i] == '-'
    inc(i)
    let offset = parseDigits(relativePointer, i, true, relativePointer)
    if indexes.len == 0 or indexes[^1] < 0:
      raise fragmentError("Relative JSON Pointer " & escape(relativePointer) &
          " adjusts the index of a node that is not a sequence item")
    let
      parent = nodes[^2]
      index = if negative: indexes[^1] - offset else: indexes[^1] + offset
    if index < 0 or index >= parent.elems.len:
      raise fragmentError("sequence index out of range: " & $index)
    nodes[^1] = parent.elems[index]
    indexes[^1] = index

  let rest = relativePointer[i .. ^1]
  if rest == "#":
    if indexes.len == 0:
      raise fragmentError("Relative JSON Pointer " & escape(relativePointer) &
          " requests the key or index of the root")
    if indexes[^1] < 0: result = RelativePointerResult(kind: rprKey, key: keys[^1])
    else: result = RelativePointerResult(kind: rprIndex, index: indexes[^1])
  elif rest.len == 0 or rest[0] == '/':
    result = RelativePointerResult(kind: rprNode,
        node: resolvePointer(nodes[^1], rest))
  else:
    raise fragmentError("invalid Relative JSON Pointer: " & relativePointer)

proc newAnchorTargetStream(source: YamlStream, name: Anchor): AnchorTargetStream =
  result = AnchorTargetStream(source: source, name: name, state: atsSearching)
  result.basicInit(proc(s: YamlStream, lineContent: var string): bool
      {.raises: [], gcsafe, closure.} =
    try: AnchorTargetStream(s).source.getLastTokenContext(lineContent)
    except CatchableError: false
  )
  result.nextImpl = proc(s: YamlStream, e: var Event): bool
      {.gcsafe, raises: [CatchableError], closure.} =
    let ats = AnchorTargetStream(s)
    e = ats.source.next()
    template rename(anchor: var Anchor) =
      if anchor == ats.name:
        case ats.state
        of atsSearching:
          anchor = targetAnchor
          ats.state = atsRenaming
        of atsRenaming: ats.state = atsDone
        of atsDone: discard
    case e.kind
    of yamlStartMap: rename(e.mapProperties.anchor)
    of yamlStartSeq: rename(e.seqProperties.anchor)
    of yamlScalar: rename(e.scalarProperties.anchor)
    of yamlAlias:
      if ats.state == atsRenaming and e.aliasTarget == ats.name:
        e.aliasTarget = targetAnchor
    else: discard
    result = true

template unwrapStreamErrors(body: untyped) =
  try: body
  except YamlStreamError as e:
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    elif e.parent of YamlConstructionError:
      raise (ref YamlConstructionError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)

proc resolveAnchor*(input: Stream | string, name: string): YamlNode
    {.raises: [YamlFragmentError, YamlConstructionError, IOError, OSError,
               YamlParserError].} =
  ## Returns the first node in the YAML stream ``input`` that has the anchor
  ## ``name`` (without the leading ``*``), searching all documents in order.
  ## The returned node is part of the graph of its document, so aliases within
  ## it are resolved.
  unwrapStreamErrors:
    var
      parser = initYamlParser()
      events: YamlStream = newAnchorTargetStream(parser.parse(input), Anchor(name))
      e = events.next()
    yAssert(e.kind == yamlStartStream)
    while events.peek().kind == yamlStartDoc:
      discard events.next()
      var
        ctx = initConstructionContext(events)
        root: YamlNode
      ctx.constructChild(root)
      e = events.next()
      yAssert(e.kind == yamlEndDoc)
      let target = ctx.refs.getOrDefault(targetAnchor).p
      if not isNil(target): return cast[YamlNode](target)
  raise fragmentError("no node with anchor " & escape(name))

proc resolveFragment*(input: Stream | string, fragment: string): YamlNode
    {.raises: [YamlFragmentError, YamlConstructionError, IOError, OSError,
               YamlParserError].} =
  ## Returns the node in the YAML stream ``input`` that the URI fragment
  ## identifier ``fragment`` references according to RFC 9512. ``fragment``
  ## is the part of a URI after ``#``; a leading ``#`` is ignored.
  ## Percent-encoded octets are decoded before evaluation.
  ##
  ## Empty fragments and JSON Pointers are only defined for single-document
  ## streams; use an anchor (``*name``) to reference nodes in multi-document
  ## streams.
  var decoded = percentDecode(
      if fragment.startsWith('#'): fragment[1 .. ^1] else: fragment)
  if decoded.startsWith('*'):
    return resolveAnchor(input, decoded[1 .. ^1])
  if decoded.len > 0 and decoded[0] != '/':
    raise fragmentError("unsupported fragment identifier syntax: " & fragment)
  var docs: seq[YamlNode]
  unwrapStreamErrors:
    loadMultiDoc(input, docs)
  if docs.len != 1:
    raise fragmentError("JSON Pointer fragments require a single-document " &
        "stream, but it contains " & $docs.len & " documents")
  result = resolvePointer(docs[0], decoded)
