#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ================
## Module yaml/diff
## ================
##
## Compares two YAML representation graphs by what they mean rather than by
## how they are written: the order of mapping keys, scalar and collection
## styles, comments, anchors and aliases make no difference, and numbers are
## compared by value, so ``1.0`` equals ``1``. What remains is a list of
## the nodes that were added, removed or changed:
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, diff]
##
##   let
##     old = loadAs[YamlNode]("{server: {host: a, port: 80}, tags: [x, y]}")
##     new = loadAs[YamlNode]("tags: [x, z, y]\nserver: {port: 8080, host: a}")
##   for change in diff(old, new):
##     echo change.kind, " ", change.newPath.toJsonPointer
##   # changed /server/port
##   # added /tags/1
##
## ``toJsonPatch`` turns the changes into a `JSON Patch <jsonpatch.html>`_
## (RFC 6902) that turns the old graph into the new one.
##
## Equality
## --------
##
## Scalars are equal if they are equal as JSON values (see
## `yaml/jsonpatch <jsonpatch.html>`_: plain scalars are resolved by the
## core schema, ``1`` equals ``1.0``, ``"1"`` is a string) and have the same
## tag where the tag says more than JSON can: ``!Ref a`` differs from ``a``
## and from ``!Sub a``. Collections of different kinds, or with different
## such tags, are changed as a whole; otherwise their items are compared.
##
## Mapping entries are matched by the content of their keys, whatever its
## tag or style, so that a YAML ``200:`` and a JSON ``"200":`` are the same
## member, and ``a`` and ``"a"`` are too. Keys that are collections are
## matched by equality, and named by their flow form.
##
## Sequences are aligned by their longest common subsequence of equal items,
## so that an inserted item is reported as added rather than as a change of
## every item after it. An item that was replaced, where the alignment
## removes and adds items at the same place, is reported as a change of
## that item, and if both are collections of the same kind, as changes
## within it.
##
## Paths
## -----
##
## Each change has a path in the old graph and one in the new graph, which
## differ where items before it in a sequence were added or removed. An
## added node's ``oldPath`` is where it is inserted into the old graph (an
## index into a sequence may be its length), a removed node's ``newPath``
## is where it would have been in the new graph. Changes come in document
## order: within a mapping, those of the old entries in the old graph's
## order, then the added entries in the new graph's.
##
## A change of the whole document has empty paths. Aliases can make a graph
## cyclic; a pair of nodes that is already being compared further up is
## taken as equal there.

import std/[algorithm, hashes, options, sets, strutils, tables]
import data, dom, dumping, jsonpath, native, presenter, stream,
    private/jsonmodel
from hints import guessType, TypeHint

type
  DiffChangeKind* = enum
    dkAdded = "added"
    dkRemoved = "removed"
    dkChanged = "changed"

  PathSegment* = object
    ## A step from a collection to one of its items.
    case isIndex*: bool
    of true: index*: int   ## the index of a sequence item
    of false: name*: string ## the content of a mapping key (or its flow form)

  DiffPath* = seq[PathSegment]

  DiffChange* = object
    kind*: DiffChangeKind
    oldPath*, newPath*: DiffPath
    oldNode*: YamlNode ## nil if added
    newNode*: YamlNode ## nil if removed

  Differ = object
    changes: seq[DiffChange]
    comparing: HashSet[(pointer, pointer)]

const
  # tags that say no more than the JSON type of the node
  jsonTags = [yTagQuestionMark, yTagExclamationMark, yTagString, yTagNull,
      yTagBoolean, yTagInteger, yTagFloat, yTagMapping, yTagSequence]
  # alignments beyond this many item pairs fall back to comparing by index
  maxAlignment = 4_000_000

proc indexSegment*(i: int): PathSegment = PathSegment(isIndex: true, index: i)
proc nameSegment*(n: string): PathSegment = PathSegment(isIndex: false, name: n)

proc `==`*(a, b: PathSegment): bool =
  a.isIndex == b.isIndex and
    (if a.isIndex: a.index == b.index else: a.name == b.name)

proc toJsonPointer*(path: DiffPath): string =
  ## ``path`` as a JSON Pointer (RFC 6901); the root is the empty string.
  for segment in path:
    result.add('/')
    if segment.isIndex: result.add($segment.index)
    else: result.add(segment.name.multiReplace(("~", "~0"), ("/", "~1")))

proc toJsonPath*(path: DiffPath): string =
  ## ``path`` as a normalized JSON Path (RFC 9535), in dot notation where a
  ## name allows it.
  result = "$"
  for segment in path:
    if segment.isIndex:
      result.add("[" & $segment.index & "]")
    elif segment.name.len > 0 and segment.name[0] in {'A'..'Z', 'a'..'z', '_'} and
        segment.name.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      result.add("." & segment.name)
    else: result.addNameSegment(segment.name)

proc flowText*(node: YamlNode): string {.raises: [].} =
  ## ``node`` as YAML on a single line, in flow style, for showing it in a
  ## list of changes. Styles of the source are dropped, and tags that say
  ## no more than the node's JSON type; a string that would read as another
  ## type when plain is quoted.
  var dumper: Dumper
  dumper.setMinimalStyle()
  dumper.presentation.directivesEnd = deIfNecessary
  try:
    let events = newBufferYamlStream()
    for e in represent(node, SerializationOptions(tagStyle: tsAll,
        handles: @[("!", "!"), ("!!", yamlTagRepositoryPrefix)])):
      var e = e
      case e.kind
      of yamlStartMap:
        e.mapStyle = csFlow
        if e.mapProperties.tag in jsonTags:
          e.mapProperties.tag = yTagQuestionMark
      of yamlStartSeq:
        e.seqStyle = csFlow
        if e.seqProperties.tag in jsonTags:
          e.seqProperties.tag = yTagQuestionMark
      of yamlScalar:
        let tag = e.scalarProperties.tag
        e.scalarStyle =
          if tag in [yTagExclamationMark, yTagString] and
              guessType(e.scalarContent) != yTypeUnknown: ssDoubleQuoted
          else: ssAny
        if tag in jsonTags: e.scalarProperties.tag = yTagQuestionMark
      else: discard
      events.put(e)
    result = present(events, dumper.presentation).strip()
  except CatchableError: result = $node
  # written before a root with a tag, and a line break after it
  result.removePrefix("--- ")
  result = result.replace("\n", " ")

proc specificTag(node: YamlNode): Tag =
  ## The tag of ``node`` if it says more than its JSON type, otherwise
  ## ``yTagQuestionMark``.
  if node.tag in jsonTags: yTagQuestionMark else: node.tag

proc entryNames(node: YamlNode): seq[tuple[name: string, key, value: YamlNode]] =
  ## The entries of the mapping ``node`` in document order, each with the
  ## name of its key. Keys that share a name (``1`` and ``"1"``) are matched
  ## in order, the later ones under the name with a number appended. The
  ## names of collection keys are marked, so that ``[a]`` is not ``"[a]"``.
  var seen = initCountTable[string]()
  for (key, value) in node.orderedFields:
    let name = if key.kind == yScalar: key.content else: key.flowText & "\0c"
    seen.inc(name)
    let count = seen[name]
    let unique = if count == 1: name else: name & "\0" & $count
    result.add((unique, key, value))

proc same(d: var Differ, a, b: YamlNode): bool {.raises: [].}

proc sameItems(d: var Differ, a, b: YamlNode): bool =
  ## Whether the collections ``a`` and ``b`` of the same kind have the same
  ## items; see `diffMapping` for how entries are matched.
  case a.kind
  of ySequence:
    if a.elems.len != b.elems.len: return false
    for i in 0 ..< a.elems.len:
      if not d.same(a.elems[i], b.elems[i]): return false
    result = true
  of yMapping:
    if a.fields.len != b.fields.len: return false
    let others = b.entryNames
    var byName = initTable[string, int]()
    for j, entry in others: byName[entry.name] = j
    for entry in a.entryNames:
      var j = byName.getOrDefault(entry.name, -1)
      if j < 0 and entry.key.kind != yScalar:
        for k, other in others:
          if other.key.kind != yScalar and d.same(entry.key, other.key):
            j = k
            break
      if j < 0 or not d.same(entry.value, others[j].value): return false
    result = true
  of yScalar: discard

proc same(d: var Differ, a, b: YamlNode): bool {.raises: [].} =
  if cast[pointer](a) == cast[pointer](b): return true
  if a.kind != b.kind or a.specificTag != b.specificTag: return false
  if a.kind == yScalar: return a.jsonScalar == b.jsonScalar
  let pair = (cast[pointer](a), cast[pointer](b))
  if d.comparing.containsOrIncl(pair): return true
  result = d.sameItems(a, b)
  d.comparing.excl(pair)

proc quickHash(node: YamlNode, depth = 3): Hash =
  ## A hash that equal nodes share (unequal ones may too): numbers hash by
  ## their value as a float, mappings by the keys they have, and nesting
  ## beyond ``depth`` not at all, which also ends on cyclic graphs.
  result = hash(node.kind) !& hash(node.specificTag)
  case node.kind
  of yScalar:
    let value = node.jsonScalar
    result = result !& hash(value.kind)
    case value.kind
    of jkBool: result = result !& hash(value.boolean)
    of jkNumber:
      let f = if value.number.isInteger: float64(value.number.integer)
              else: value.number.float
      if f == f: result = result !& hash(f)
    of jkString: result = result !& hash(value.str)
    else: discard
  of ySequence:
    result = result !& hash(node.elems.len)
    if depth > 0:
      for item in node.elems: result = result !& item.quickHash(depth - 1)
  of yMapping:
    var keys: Hash = 0
    for key, value in node.fields.pairs:
      if key.kind == yScalar:
        keys = keys xor hash(key.content)
        if depth > 0: keys = keys xor !$(hash(key.content) !& value.quickHash(depth - 1))
    result = result !& hash(node.fields.len) !& keys
  result = !$result

proc add(d: var Differ, kind: DiffChangeKind, oldPath, newPath: DiffPath,
    oldNode, newNode: YamlNode) =
  d.changes.add(DiffChange(kind: kind, oldPath: oldPath, newPath: newPath,
      oldNode: oldNode, newNode: newNode))

proc diffNodes(d: var Differ, a, b: YamlNode, oldPath, newPath: DiffPath)
    {.raises: [].}

proc segmentOf(name: string): PathSegment =
  let cut = name.find('\0')
  nameSegment(if cut < 0: name else: name[0 ..< cut])

proc diffMapping(d: var Differ, a, b: YamlNode, oldPath, newPath: DiffPath) =
  let
    old = a.entryNames
    new = b.entryNames
  var newByName = initTable[string, int]()
  for i, entry in new: newByName[entry.name] = i
  var matched = newSeq[bool](new.len)
  for entry in old:
    var j = newByName.getOrDefault(entry.name, -1)
    if j < 0 and entry.key.kind != yScalar:
      # collection keys: by equality
      for k, other in new:
        if not matched[k] and other.key.kind != yScalar and
            d.same(entry.key, other.key):
          j = k
          break
    let segment = entry.name.segmentOf
    if j < 0:
      d.add(dkRemoved, oldPath & segment, newPath & segment, entry.value, nil)
    else:
      matched[j] = true
      d.diffNodes(entry.value, new[j].value, oldPath & segment,
          newPath & new[j].name.segmentOf)
  for j, entry in new:
    if not matched[j]:
      let segment = entry.name.segmentOf
      d.add(dkAdded, oldPath & segment, newPath & segment, nil, entry.value)

type
  Step = enum stKeep, stRemove, stAdd

proc align(d: var Differ, a, b: seq[YamlNode]): seq[Step] =
  ## The steps that turn ``a`` into ``b``, keeping a longest common
  ## subsequence of equal items, with removals before additions where both
  ## happen at the same place.
  var
    first = 0
    lastA = a.len
    lastB = b.len
  while first < lastA and first < lastB and d.same(a[first], b[first]):
    inc(first)
  while lastA > first and lastB > first and d.same(a[lastA - 1], b[lastB - 1]):
    dec(lastA)
    dec(lastB)
  for _ in 0 ..< first: result.add(stKeep)
  let
    n = lastA - first
    m = lastB - first
  if n * m > maxAlignment:
    for _ in 0 ..< n: result.add(stRemove)
    for _ in 0 ..< m: result.add(stAdd)
  elif n > 0 or m > 0:
    var hashesA, hashesB: seq[Hash]
    for i in 0 ..< n: hashesA.add(a[first + i].quickHash)
    for j in 0 ..< m: hashesB.add(b[first + j].quickHash)
    # lengths[i][j]: of the longest common subsequence of the items from i
    # and from j on
    var lengths = newSeq[seq[int32]](n + 1)
    for i in 0 .. n: lengths[i] = newSeq[int32](m + 1)
    for i in countdown(n - 1, 0):
      for j in countdown(m - 1, 0):
        lengths[i][j] =
          if hashesA[i] == hashesB[j] and d.same(a[first + i], b[first + j]):
            lengths[i + 1][j + 1] + 1
          else: max(lengths[i + 1][j], lengths[i][j + 1])
    var i, j = 0
    while i < n or j < m:
      if i < n and j < m and hashesA[i] == hashesB[j] and
          lengths[i][j] == lengths[i + 1][j + 1] + 1 and
          d.same(a[first + i], b[first + j]):
        result.add(stKeep)
        inc(i)
        inc(j)
      elif i < n and (j == m or lengths[i + 1][j] >= lengths[i][j + 1]):
        result.add(stRemove)
        inc(i)
      else:
        result.add(stAdd)
        inc(j)
  for _ in lastA ..< a.len: result.add(stKeep)

proc diffSequence(d: var Differ, a, b: YamlNode, oldPath, newPath: DiffPath) =
  let steps = d.align(a.elems, b.elems)
  var
    i, j = 0 # the next items of a and b
    s = 0
  while s < steps.len:
    if steps[s] == stKeep:
      inc(i)
      inc(j)
      inc(s)
      continue
    # a run of removals, then additions: the first of both pair up as
    # changes, the rest are removed or added
    var removed, added = 0
    while s + removed < steps.len and steps[s + removed] == stRemove:
      inc(removed)
    while s + removed + added < steps.len and
        steps[s + removed + added] == stAdd:
      inc(added)
    let paired = min(removed, added)
    for k in 0 ..< paired:
      d.diffNodes(a.elems[i + k], b.elems[j + k], oldPath & indexSegment(i + k),
          newPath & indexSegment(j + k))
    for k in paired ..< removed:
      d.add(dkRemoved, oldPath & indexSegment(i + k), newPath & indexSegment(j + paired),
          a.elems[i + k], nil)
    for k in paired ..< added:
      d.add(dkAdded, oldPath & indexSegment(i + removed), newPath & indexSegment(j + k),
          nil, b.elems[j + k])
    i += removed
    j += added
    s += removed + added

proc diffNodes(d: var Differ, a, b: YamlNode, oldPath, newPath: DiffPath)
    {.raises: [].} =
  if d.same(a, b): return
  if a.kind == yScalar or a.kind != b.kind or a.specificTag != b.specificTag:
    d.add(dkChanged, oldPath, newPath, a, b)
    return
  let pair = (cast[pointer](a), cast[pointer](b))
  if d.comparing.containsOrIncl(pair): return
  if a.kind == yMapping: d.diffMapping(a, b, oldPath, newPath)
  else: d.diffSequence(a, b, oldPath, newPath)
  d.comparing.excl(pair)

proc diff*(old, new: YamlNode): seq[DiffChange] {.raises: [].} =
  ## The changes that turn the graph ``old`` into ``new``, in document
  ## order; empty if they are equal. See the module documentation.
  var d: Differ
  d.diffNodes(old, new, @[], @[])
  result = d.changes

proc semanticEquals*(a, b: YamlNode): bool {.raises: [].} =
  ## Whether ``diff(a, b)`` is empty.
  var d: Differ
  d.same(a, b)

proc toJsonPatch*(changes: openArray[DiffChange]): YamlNode {.raises: [].} =
  ## A JSON Patch (RFC 6902) that makes the changes, as computed by `diff`,
  ## to the old graph: ``old.applyJsonPatch(toJsonPatch(diff(old, new)))``
  ## equals ``new`` as JSON. The operations come in reverse document order,
  ## so that each uses the paths of the old graph.
  ##
  ## JSON Pointers name only members whose keys are strings (see
  ## `yaml/jsonpatch <jsonpatch.html>`_), so a change of a member under a
  ## key like ``200`` or ``[a, b]`` cannot be applied.
  result = newYamlNode(newSeq[YamlNode]())
  for i in countdown(changes.high, 0):
    let change = changes[i]
    var fields = @[(newYamlNode("op"), newYamlNode(case change.kind
        of dkAdded: "add"
        of dkRemoved: "remove"
        of dkChanged: "replace")),
      (newYamlNode("path"),
       newYamlNode(change.oldPath.toJsonPointer, yTagExclamationMark))]
    if change.kind != dkRemoved:
      fields.add((newYamlNode("value"), change.newNode))
    # the members in this order when dumped
    for k, (key, _) in fields:
      key.startPos = Mark(line: 1, column: k + 2)
    result.elems.add(newYamlNode(fields))
