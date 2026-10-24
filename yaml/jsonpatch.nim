#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =====================
## Module yaml/jsonpatch
## =====================
##
## Applies `JSON Patch <https://www.rfc-editor.org/rfc/rfc6902>`_ (RFC 6902)
## documents to YAML representation graphs. A JSON Patch is a sequence of
## operations (``add``, ``remove``, ``replace``, ``move``, ``copy`` and
## ``test``), each naming its target with a JSON Pointer:
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, jsonpatch]
##
##   let
##     document = loadAs[YamlNode]("{name: app, tags: [a, b]}")
##     patch = loadAs[YamlNode]("""
##     - {op: test, path: /name, value: app}
##     - {op: add, path: /tags/-, value: c}
##     - {op: replace, path: /name, value: service}
##     """)
##   echo dump(document.applyJsonPatch(patch))
##   # {name: service, tags: [a, b, c]}
##
## A patch is itself a YAML (or JSON) document. ``parseJsonPatch`` checks it
## once, so that it can be applied to any number of documents.
##
## Patches never change their input
## --------------------------------
##
## RFC 6902 requires a patch to be applied atomically: if any operation
## fails, the document must be left as it was. Rather than undoing the
## operations that succeeded, ``applyJsonPatch`` never changes the input
## graph at all. Each operation copies the collections on the path to its
## target before changing them, and the result shares everything else with
## the input (and with the values in the patch). A failing patch thus simply
## discards its copies, and patching a large document costs time in
## proportion to the paths it changes, not to its size.
##
## Copying along paths is also what makes aliases behave like JSON: a node
## reachable as both ``/a`` and ``/b`` is two values to a JSON Patch, and
## changing ``/a/x`` must not change ``/b/x``. The result therefore contains
## a copy of the node at ``/a``, while ``/b`` is the original. A collection
## the patch has copied already is changed in place by later operations,
## unless a ``copy`` operation has put it in two places.
##
## Because results share nodes with the input, changing a result in place
## can change the input; copy it first if both need to stay independent.
##
## Reading YAML as JSON
## --------------------
##
## Pointers and ``test`` read the graph as JSON in the way described in
## `yaml/fragment <fragment.html>`_ and `yaml/jsonpath <jsonpath.html>`_:
## only string keys name members, scalars get their JSON type from their tag
## and the core schema, and ``test`` compares numbers by value and objects
## regardless of member order. Where a mapping spells a member name with
## several keys (``a`` and ``"a"``), ``replace`` and ``add`` keep the key
## a pointer resolves to and drop the others, and ``remove`` removes all of
## them. A new member gets a plain key, or a double-quoted one if a plain
## scalar would not read as a string (``"1"``, ``"true"``).
##
## Errors
## ------
##
## Everything that RFC 6902 calls an error raises ``YamlJsonPatchError``.
## Its ``kind`` tells a malformed patch (HTTP servers answer 400) from a
## patch whose locations do not exist in the document or whose ``test``
## fails (409 or 422, see `RFC 5789 <https://www.rfc-editor.org/rfc/rfc5789#section-2.2>`_).

import std/[sets, strutils, tables]
import dom, fragment, private/jsonmodel

type
  JsonPatchErrorKind* = enum
    jpeInvalidPatch    ## the patch is not a well-formed JSON Patch
    jpeInvalidLocation ## a location does not exist or cannot be changed
    jpeTestFailed      ## a ``test`` operation found a different value

  YamlJsonPatchError* = object of ValueError
    ## Raised when a patch is malformed or cannot be applied.
    kind*: JsonPatchErrorKind
    operation*: int ## index of the offending operation, ``-1`` if the patch
                    ## as a whole is malformed

  OperationKind = enum
    opAdd = "add", opRemove = "remove", opReplace = "replace",
    opMove = "move", opCopy = "copy", opTest = "test"

  Location = object
    text: string         ## the JSON Pointer, for error messages
    tokens: seq[string]  ## its unescaped reference tokens

  Operation = object
    kind: OperationKind
    path: Location
    source: Location     ## ``from`` of ``move`` and ``copy``
    value: YamlNode      ## ``value`` of ``add``, ``replace`` and ``test``

  JsonPatch* = object
    ## A checked JSON Patch, ready to be applied.
    operations: seq[Operation]

proc patchError(kind: JsonPatchErrorKind, operation: int, msg: string):
    ref YamlJsonPatchError =
  result = newException(YamlJsonPatchError,
      if operation < 0: msg else: "operation " & $operation & ": " & msg)
  result.kind = kind
  result.operation = operation

# ============================================================================
# Checking the patch
#
# The whole patch is checked before any operation runs, so that a malformed
# patch is reported as such even if an earlier operation would fail on the
# document. RFC 6902 ignores members it does not define, and so does this.
# ============================================================================

proc stringMember(op: YamlNode, name: string, index: int): string =
  let value = op.member(name)
  if isNil(value):
    raise patchError(jpeInvalidPatch, index, "missing member '" & name & "'")
  if value.jsonKind != jkString:
    raise patchError(jpeInvalidPatch, index,
        "member '" & name & "' must be a string")
  result = value.content

proc location(op: YamlNode, name: string, index: int): Location =
  result.text = op.stringMember(name, index)
  try: result.tokens = pointerTokens(result.text)
  except YamlFragmentError as e:
    raise patchError(jpeInvalidPatch, index, e.msg)

proc parseJsonPatch*(patch: YamlNode): JsonPatch
    {.raises: [YamlJsonPatchError].} =
  ## Checks that ``patch`` is a JSON Patch: a sequence of operation objects,
  ## each with the members its ``op`` requires. Raises
  ## ``YamlJsonPatchError`` of kind ``jpeInvalidPatch`` if it is not.
  if patch.kind != ySequence:
    raise patchError(jpeInvalidPatch, -1, "a JSON Patch must be a sequence")
  for index, op in patch.elems:
    if op.kind != yMapping:
      raise patchError(jpeInvalidPatch, index, "operation must be a mapping")
    var operation: Operation
    let name = op.stringMember("op", index)
    try: operation.kind = parseEnum[OperationKind](name)
    except ValueError:
      raise patchError(jpeInvalidPatch, index, "unknown op " & escape(name))
    operation.path = op.location("path", index)
    case operation.kind
    of opMove, opCopy: operation.source = op.location("from", index)
    of opAdd, opReplace, opTest:
      operation.value = op.member("value")
      if isNil(operation.value):
        raise patchError(jpeInvalidPatch, index, "missing member 'value'")
    of opRemove: discard
    result.operations.add(operation)

# ============================================================================
# Copying on write
#
# ``owned`` holds the collections this application has made itself; only
# these may be changed in place. The ``kept`` sequence keeps them alive, so
# that the address of a discarded copy cannot be reused by a node the patch
# does not own.
# ============================================================================

type Patcher = object
  root: YamlNode
  owned: HashSet[pointer]
  kept: seq[YamlNode]
  index: int ## of the operation being applied

proc fail(p: Patcher, msg: string) {.noreturn.} =
  raise patchError(jpeInvalidLocation, p.index, msg)

proc own(p: var Patcher, node: YamlNode): YamlNode =
  ## ``node`` if this patch made it, otherwise a shallow copy of it that the
  ## patch may change.
  if node.kind == yScalar or cast[pointer](node) in p.owned: return node
  case node.kind
  of ySequence:
    result = YamlNode(kind: ySequence, tag: node.tag, elems: node.elems,
        seqStyle: node.seqStyle, startPos: node.startPos, endPos: node.endPos)
  of yMapping:
    result = YamlNode(kind: yMapping, tag: node.tag,
        fields: newTable[YamlNode, YamlNode](), mapStyle: node.mapStyle,
        startPos: node.startPos, endPos: node.endPos)
    for key, value in node.fields.pairs: result.fields[key] = value
  of yScalar: discard
  p.owned.incl(cast[pointer](result))
  p.kept.add(result)

proc disown(p: var Patcher, node: YamlNode) =
  ## Called when ``copy`` puts ``node`` in a second place: from now on, it
  ## and the owned collections in it must be copied before being changed.
  ## Owned collections are only ever reachable through owned parents, so
  ## the walk stops at the first node the patch does not own.
  if node.kind == yScalar or not p.owned.missingOrExcl(cast[pointer](node)):
    return
  case node.kind
  of ySequence:
    for item in node.elems: p.disown(item)
  of yMapping:
    for value in node.fields.values: p.disown(value)
  of yScalar: discard

proc arrayIndex(p: Patcher, node: YamlNode, token: string, loc: Location,
    allowEnd: bool): int =
  ## Parses ``token`` as an index into the sequence ``node``. With
  ## ``allowEnd``, as for ``add``, the index may be the length of the
  ## sequence, which ``-`` also stands for.
  if token == "-":
    if allowEnd: return node.elems.len
    p.fail("'-' does not reference an existing item in " & loc.text)
  if token.len == 0 or not token.allCharsInSet(Digits) or
      token.len > 1 and token[0] == '0':
    p.fail("invalid sequence index " & escape(token) & " in " & loc.text)
  try: result = parseInt(token)
  except ValueError: result = high(int)
  if result > node.elems.len or result == node.elems.len and not allowEnd:
    p.fail("sequence index " & token & " out of range in " & loc.text)

proc child(p: Patcher, node: YamlNode, token: string, loc: Location):
    YamlNode =
  case node.kind
  of yMapping:
    result = node.member(token)
    if isNil(result):
      p.fail("no member " & escape(token) & " for " & loc.text)
  of ySequence: result = node.elems[p.arrayIndex(node, token, loc, false)]
  of yScalar: p.fail("cannot descend into a scalar for " & loc.text)

proc resolve(p: Patcher, loc: Location): YamlNode =
  result = p.root
  for token in loc.tokens: result = p.child(result, token, loc)

proc ownedParent(p: var Patcher, loc: Location): YamlNode =
  ## The collection containing the location ``loc``, after making it and
  ## every collection above it owned. ``loc`` must not be the root.
  p.root = p.own(p.root)
  result = p.root
  for i in 0 ..< loc.tokens.len - 1:
    let
      token = loc.tokens[i]
      child = p.own(p.child(result, token, loc))
    if result.kind == yMapping:
      result.fields[result.memberKey(token)] = child
    else:
      result.elems[p.arrayIndex(result, token, loc, false)] = child
    result = child
  if result.kind == yScalar:
    p.fail("cannot change a member of a scalar at " & loc.text)

# ============================================================================
# The operations
#
# RFC 6902 defines ``move`` as ``remove`` then ``add``, ``copy`` as ``add``
# of a value found elsewhere, and ``replace`` as ``remove`` then ``add`` of
# an existing location, which is what the procs below do.
# ============================================================================

proc add(p: var Patcher, loc: Location, value: YamlNode) =
  if loc.tokens.len == 0:
    p.root = value
    return
  let
    parent = p.ownedParent(loc)
    last = loc.tokens[^1]
  if parent.kind == yMapping: parent.setMember(last, value)
  else: parent.elems.insert(value, p.arrayIndex(parent, last, loc, true))

proc remove(p: var Patcher, loc: Location): YamlNode =
  ## Removes the value at ``loc`` and returns it.
  if loc.tokens.len == 0: p.fail("cannot remove the root")
  let
    parent = p.ownedParent(loc)
    last = loc.tokens[^1]
  result = p.child(parent, last, loc)
  if parent.kind == yMapping: discard parent.removeMember(last)
  else: parent.elems.delete(p.arrayIndex(parent, last, loc, false))

proc replace(p: var Patcher, loc: Location, value: YamlNode) =
  if loc.tokens.len == 0:
    p.root = value
    return
  let
    parent = p.ownedParent(loc)
    last = loc.tokens[^1]
  discard p.child(parent, last, loc) # must exist
  if parent.kind == yMapping: parent.setMember(last, value)
  else: parent.elems[p.arrayIndex(parent, last, loc, false)] = value

proc isProperPrefix(a, b: Location): bool =
  a.tokens.len < b.tokens.len and a.tokens == b.tokens[0 ..< a.tokens.len]

proc apply(p: var Patcher, op: Operation) =
  case op.kind
  of opAdd: p.add(op.path, op.value)
  of opRemove: discard p.remove(op.path)
  of opReplace: p.replace(op.path, op.value)
  of opMove:
    if op.source.isProperPrefix(op.path):
      p.fail("cannot move " & op.source.text & " into its own child " &
          op.path.text)
    if op.source.tokens == op.path.tokens: discard p.resolve(op.source)
    else: p.add(op.path, p.remove(op.source))
  of opCopy:
    let value = p.resolve(op.source)
    p.add(op.path, value)
    p.disown(value)
  of opTest:
    if not jsonEquals(p.resolve(op.path), op.value):
      raise patchError(jpeTestFailed, p.index,
          "test failed: " & op.path.text & " has a different value")

proc applyJsonPatch*(document: YamlNode, patch: JsonPatch): YamlNode
    {.raises: [YamlJsonPatchError].} =
  ## Applies ``patch`` to ``document`` and returns the patched document,
  ## which shares unchanged nodes with ``document`` and ``patch``.
  ## ``document`` itself is never changed, also not if the patch fails.
  ##
  ## Raises ``YamlJsonPatchError`` of kind ``jpeInvalidLocation`` if an
  ## operation's location does not exist or cannot be changed, and of kind
  ## ``jpeTestFailed`` if a ``test`` operation fails.
  var p = Patcher(root: document, owned: initHashSet[pointer]())
  for index, op in patch.operations:
    p.index = index
    p.apply(op)
  result = p.root

proc applyJsonPatch*(document, patch: YamlNode): YamlNode
    {.raises: [YamlJsonPatchError].} =
  ## Checks ``patch`` with ``parseJsonPatch`` and applies it to
  ## ``document``.
  document.applyJsonPatch(parseJsonPatch(patch))
