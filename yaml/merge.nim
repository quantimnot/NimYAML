#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =================
## Module yaml/merge
## =================
##
## Applies `merge keys <https://yaml.org/type/merge.html>`_, the ``<<`` keys
## that let a mapping inherit the entries of other mappings:
##
## .. code-block:: yaml
##
##   defaults: &defaults {adapter: postgres, host: localhost}
##   development:
##     <<: *defaults
##     database: dev
##
## After merging, ``development`` is ``{adapter: postgres, host: localhost,
## database: dev}``. The value of ``<<`` is a mapping, or a sequence of
## mappings. A mapping's own keys win over merged ones, and in a sequence,
## earlier mappings win over later ones. Merged mappings may have merge keys
## themselves; those are applied first.
##
## Merge keys were defined for YAML 1.1 and are not part of YAML 1.2, which
## is why NimYAML does not apply them while loading and other modules
## (`yaml/fragment <fragment.html>`_, `yaml/jsonpath <jsonpath.html>`_) see
## ``<<`` as an ordinary key. They remain common in configuration files, so
## this module applies them on request, in one of two ways:
##
## * ``applyMergeKeys`` changes a ``YamlNode`` graph in place;
## * ``loadMerged`` and the ``mergeKeysApplied`` stream filter apply them
##   before constructing native values, so that ``<<`` works with
##   ``loadAs``-style loading into objects.
##
## .. code-block:: nim
##
##   import yaml, yaml/merge
##
##   type Database = object
##     adapter, host, database: string
##
##   var config: Table[string, Database]
##   loadMerged(input, config)   # instead of load(input, config)
##
## A key is a merge key if it is the plain scalar ``<<`` or is tagged
## ``!!merge``. A quoted ``"<<"`` is an ordinary string key. Keys are
## compared as YAML nodes, by tag and content, as the DOM compares them, so
## a merged ``"a"`` does not override a plain ``a``.
##
## Merged entries share their values with the mapping they come from, just
## as aliases share nodes. Merge keys with a value that is not a mapping or
## a sequence of mappings, and mappings that merge themselves (directly or
## through others), raise ``YamlMergeError``.

import std/[sets, streams, tables]
import data, dom, stream, native, parser, private/internal

type
  YamlMergeError* = object of ValueError
    ## Raised for merge keys that cannot be applied.
    mark*: Mark ## position of the offending merge key, if known

proc mergeError(key: YamlNode, msg: string): ref YamlMergeError =
  result = newException(YamlMergeError, msg)
  result.mark = key.startPos

proc isMergeKey(key: YamlNode): bool =
  key.kind == yScalar and (key.tag == yTagMerge or
      key.tag == yTagQuestionMark and key.content == "<<")

# ============================================================================
# Applying merge keys to a graph
#
# A mapping must have its own merge keys applied before it is merged into
# another, so merging recurses into merge sources first. ``resolving`` marks
# the mappings on that recursion path: meeting one again means a mapping
# merges itself. This is the only kind of cycle that is an error; aliases
# that make the graph cyclic elsewhere are fine and are handled by visiting
# every node once.
# ============================================================================

type
  MergeState = enum
    msResolving, msResolved

  Merger = object
    states: Table[pointer, MergeState]
    visited: HashSet[pointer]

proc rehash(mapping: YamlNode) =
  ## A key's hash covers its content, so a mapping key that has had merge
  ## keys applied is filed under a stale hash: rebuild the table.
  let fields = newTable[YamlNode, YamlNode]()
  for key, value in mapping.fields.pairs:
    if fields.hasKeyOrPut(key, value):
      raise mergeError(key, "applying merge keys made two keys equal")
  mapping.fields = fields

proc hasCollectionKeys(mapping: YamlNode): bool =
  for key in mapping.fields.keys:
    if key.kind != yScalar: return true

proc resolve(m: var Merger, mapping: YamlNode) =
  ## Applies the merge keys of ``mapping`` itself (not of its children).
  let p = cast[pointer](mapping)
  if p in m.states:
    if m.states.getOrDefault(p) == msResolved: return
    raise mergeError(mapping, "mapping merges itself")
  m.states[p] = msResolving
  # Its keys may have been resolved already, through another path; merged
  # keys must be checked against their current hashes.
  if mapping.hasCollectionKeys: mapping.rehash()
  var
    mergeKeys: seq[YamlNode]
    sources: seq[YamlNode]
  # in document order, should a mapping have both << and !!merge keys
  for (key, value) in mapping.orderedFields:
    if not key.isMergeKey: continue
    mergeKeys.add(key)
    case value.kind
    of yMapping: sources.add(value)
    of ySequence:
      for item in value.elems:
        if item.kind != yMapping:
          raise mergeError(key, "merge key sequence must only contain mappings")
        sources.add(item)
    of yScalar:
      raise mergeError(key, "merge key value must be a mapping or a " &
          "sequence of mappings")
  for source in sources: m.resolve(source)
  for key in mergeKeys: mapping.fields.del(key)
  for source in sources:
    for key, value in source.fields.pairs:
      if not mapping.fields.hasKey(key): mapping.fields[key] = value
  m.states[p] = msResolved

proc walk(m: var Merger, node: YamlNode) =
  if node.kind == yScalar or
      m.visited.containsOrIncl(cast[pointer](node)): return
  case node.kind
  of ySequence:
    for item in node.elems: m.walk(item)
  of yMapping:
    m.resolve(node)
    for key, value in node.fields.pairs:
      m.walk(key)
      m.walk(value)
    # walking the keys may have applied merge keys within them
    if node.hasCollectionKeys: node.rehash()
  of yScalar: discard

proc applyMergeKeys*(root: YamlNode) {.raises: [YamlMergeError].} =
  ## Applies all merge keys in the graph reachable from ``root``, in place.
  ## Afterwards, the graph contains no merge keys.
  var m: Merger
  m.walk(root)

# ============================================================================
# Applying merge keys to an event stream
#
# Merging needs the whole document, since a merge key can refer to any
# earlier anchor. The filter therefore composes each document into a
# ``YamlNode`` graph, applies the merge keys and turns the graph into events
# again, keeping positions so that later errors still point at the input.
#
# Which nodes get an anchor matters: native construction refuses anchors on
# values that are not ``ref`` types, so the filter must not invent aliases
# the input did not have. Merging makes values shared that were written
# once (every merged entry shares its value with the source), and it can
# leave an anchored node referenced only once (when its only alias was a
# merge value). A node is therefore written as an alias only where it was
# shared both before and after merging; everywhere else it is written out
# in full. Cycles must keep an alias, also where merging made them: the
# node that a cycle reaches again while it is being written gets an anchor
# in any case.
# ============================================================================

proc countReferences(node: YamlNode, counts: var CountTable[pointer]) =
  ## Counts the places each node of the graph appears in, descending into
  ## each node once.
  counts.inc(cast[pointer](node))
  if counts[cast[pointer](node)] > 1: return
  case node.kind
  of yScalar: discard
  of ySequence:
    for item in node.elems: countReferences(item, counts)
  of yMapping:
    for key, value in node.fields.pairs:
      countReferences(key, counts)
      countReferences(value, counts)

proc findCycles(node: YamlNode, onPath, done, reachedAgain: var HashSet[pointer]) =
  ## Collects in ``reachedAgain`` the nodes that the depth-first walk of
  ## ``emit``, which visits in the same order, reaches again while they are
  ## on its path.
  let p = cast[pointer](node)
  if p in onPath:
    reachedAgain.incl(p)
    return
  if node.kind == yScalar or done.containsOrIncl(p): return
  onPath.incl(p)
  case node.kind
  of ySequence:
    for item in node.elems: findCycles(item, onPath, done, reachedAgain)
  of yMapping:
    for (key, value) in node.orderedFields:
      findCycles(key, onPath, done, reachedAgain)
      findCycles(value, onPath, done, reachedAgain)
  of yScalar: discard
  onPath.excl(p)

type Emitter = object
  wasShared, isShared: CountTable[pointer]
  cyclic: HashSet[pointer]
  anchors: Table[pointer, Anchor]
  events: seq[Event]

proc emit(em: var Emitter, node: YamlNode) =
  let p = cast[pointer](node)
  if p in em.anchors:
    em.events.add(aliasEvent(em.anchors.getOrDefault(p), node.startPos,
        node.endPos))
    return
  var anchor = yAnchorNone
  if p in em.cyclic or em.wasShared[p] > 1 and em.isShared[p] > 1:
    anchor = Anchor("m" & $em.anchors.len)
    em.anchors[p] = anchor
  case node.kind
  of yScalar:
    em.events.add(scalarEvent(node.content, node.tag, anchor,
        node.scalarStyle, node.startPos, node.endPos))
  of ySequence:
    em.events.add(startSeqEvent(node.seqStyle, node.tag, anchor,
        node.startPos, node.endPos))
    for item in node.elems: em.emit(item)
    em.events.add(endSeqEvent(node.endPos, node.endPos))
  of yMapping:
    em.events.add(startMapEvent(node.mapStyle, node.tag, anchor,
        node.startPos, node.endPos))
    for (key, value) in node.orderedFields:
      em.emit(key)
      em.emit(value)
    em.events.add(endMapEvent(node.endPos, node.endPos))

proc mergedDocument(source: YamlStream): seq[Event] =
  ## Reads the content of a document from ``source`` (after its start event,
  ## up to and including its end event) and returns it with merge keys
  ## applied.
  var
    ctx = initConstructionContext(source)
    root: YamlNode
    em: Emitter
  ctx.constructChild(root)
  countReferences(root, em.wasShared)
  root.applyMergeKeys()
  countReferences(root, em.isShared)
  var onPath, done: HashSet[pointer]
  findCycles(root, onPath, done, em.cyclic)
  em.emit(root)
  result = move em.events
  result.add(source.next())

type MergingStream = ref object of YamlStream
  source: YamlStream
  pending: seq[Event] ## the rest of the current document, in order
  next: int

proc mergeKeysApplied*(source: YamlStream): YamlStream {.raises: [].} =
  ## Returns a stream with the events of ``source``, but with merge keys
  ## applied in each document. Construction and merge errors are raised,
  ## wrapped in ``YamlStreamError``, when the document's start event is
  ## read.
  let s = MergingStream(source: source)
  s.basicInit(proc(s: YamlStream, lineContent: var string): bool
      {.raises: [], gcsafe, closure.} =
    try: MergingStream(s).source.getLastTokenContext(lineContent)
    except CatchableError: false
  )
  s.nextImpl = proc(s: YamlStream, e: var Event): bool
      {.gcsafe, raises: [CatchableError], closure.} =
    let ms = MergingStream(s)
    if ms.next < ms.pending.len:
      e = ms.pending[ms.next]
      inc(ms.next)
    else:
      e = ms.source.next()
      if e.kind == yamlStartDoc:
        {.cast(gcsafe).}:
          ms.pending = mergedDocument(ms.source)
        ms.next = 0
    result = true
  result = s

proc loadMerged*[K](input: Stream | string, target: var K)
    {.raises: [YamlConstructionError, YamlMergeError, IOError, OSError,
               YamlParserError].} =
  ## Like ``load``, but applies merge keys before constructing ``target``.
  try:
    var
      parser = initYamlParser()
      events = mergeKeysApplied(parser.parse(input))
      e = events.next()
    yAssert(e.kind == yamlStartStream)
    if events.peek().kind != yamlStartDoc:
      raise constructionError(events, e.startPos, "stream contains no documents")
    construct(events, target)
    e = events.next()
    if e.kind != yamlEndStream:
      var ex = (ref YamlConstructionError)(
        mark: e.startPos, msg: "stream contains multiple documents")
      discard events.getLastTokenContext(ex.lineContent)
      raise ex
  except YamlStreamError as e:
    if e.parent of IOError: raise (ref IOError)(e.parent)
    if e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    elif e.parent of YamlConstructionError: raise (ref YamlConstructionError)(e.parent)
    elif e.parent of YamlMergeError: raise (ref YamlMergeError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)
