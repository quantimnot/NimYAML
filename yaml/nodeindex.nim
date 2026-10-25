#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =====================
## Module yaml/nodeindex
## =====================
##
## An index of where the nodes of a YAML (or JSON) file are, kept in a file
## of its own, so that a node can be read without parsing the whole file:
## the index gives the byte range of the node, and only that slice of the
## source is read and parsed. For a large file queried again and again, this
## replaces a parse of everything with a seek and a parse of a few bytes.
##
## .. code-block:: nim
##   let source = "a:\n  b: [1, 2]\nc: 3\n"
##   var index = buildIndex(source)
##   let hits = index.lookup("$['a']['b']").get()
##   # hits[0].entry.start == 8, hits[0].entry.stop == 14
##   nodeOfSlice(source[8 ..< 14], hits[0].entry) # the sequence [1, 2]
##
## What is indexed
## ===============
##
## An index has an entry for each node that a Normalized Path names, with
## the node's byte range from `yaml/spans <spans.html>`_, per document of
## the source. How many entries there are is the index's *mode*:
##
## ========== =================================================================
## ``all``    every node; built once, it answers every singular query
## ``recent`` only the nodes of the paths looked up lately, at most
##            ``recent-limit`` paths, the least recently used dropped first;
##            small, and it costs nothing for paths never asked for
## ``off``    no index (the default)
## ========== =================================================================
##
## An alias has an entry of its own, which names the path of its anchored
## node and its anchor, so that the index says both what the node *is* (the
## anchored node's text) and how it was *written* (``*name``); a writer
## that wants to keep aliases has what it needs. A lookup follows the
## alias to the anchored node.
##
## Keeping the index true
## ======================
##
## A file edited by anything else makes its index point at the wrong
## bytes, so an index holds a fingerprint of its source: its size, its
## modification time and a 64-bit FNV-1a hash of its content. If size and
## time match, the index is trusted without reading the source (that is the
## point of it); if not, the source is hashed, and the index is used only
## if the hash matches, which then updates its time. A stale index is built
## again when the source has to be parsed anyway. FNV-1a was chosen over a
## cryptographic hash because detecting edits, not tampering, is the job,
## and it needs no code beyond a few lines here.
##
## A slice is used only when it means the same out of its document. Each
## entry holds the digest of its node (see `yaml/spans <spans.html>`_),
## computed from the parse of the whole source; the slice, indented by the
## node's column, must parse to a single node with that digest. That
## catches what slicing loses, whatever it is: a tag on the line before the
## node, an alias of an anchor outside the slice, a block scalar whose
## indentation indicator counts from its parent, an explicit key's empty
## value. Two cheap checks come first: a document with directives
## (``%TAG`` handles would be unknown in the slice) or under ``%GLOBAL``
## directives is never sliced, nor is a block scalar that keeps its
## trailing line breaks (``|+``), whose last blank lines are not within
## its range.
##
## Anything else, and any error reading the slice, falls back to parsing
## the whole source, which is always right. The index never gives an answer
## that parsing would not; over the yaml-test-suite, 86% of the nodes
## are read from their slices.
##
## Storage
## =======
##
## An index is a plain object, stored with NimYAML's own serialization as
## CBOR (``format: cbor``, the default: compact and quick to read) or YAML
## (``format: yaml``, for reading it yourself; ``yaml index --print``
## shows any index as YAML). A custom binary layout of fixed-width records
## could be memory-mapped and searched without decoding, but would need a
## reader and writer of its own; decoding an index is still far cheaper
## than parsing its source, whose text it does not hold.
##
## Where it is kept is its *location*:
##
## ============ =============================================================
## ``beside``   next to the source, as ``.NAME.index.cbor`` (or ``.yaml``):
##              hidden, so that shell globs like ``*.yaml`` skip it
## ``project``  in ``.yaml-index`` next to the config file, mirroring the
##              source's path below the config's directory
## ``user``     in the user's cache directory (``getCacheDir("nimyaml")``),
##              mirroring the source's absolute path (the default)
## ============ =============================================================
##
## Mode, format, location and limit are set in the ``index`` section of the
## ``.yaml`` config, see `toolconfig <toolconfig.html>`_.

import std/[algorithm, options, os, sets, strutils, tables, times]
when defined(nimPreviewSlimSystem):
  import std/syncio
import cbor, data, dom, dumping, loading, native, parser, spans, stream
export options, SpanKind

type
  IndexMode* = enum
    imOff = "off", imRecent = "recent", imAll = "all"

  IndexFormat* = enum
    ifCbor = "cbor", ifYaml = "yaml"

  IndexLocation* = enum
    ilBeside = "beside", ilProject = "project", ilUser = "user"

  IndexSettings* = object
    ## What the config says about indexing a file.
    mode*: IndexMode
    format*: IndexFormat
    location*: IndexLocation
    recentLimit*: int
    configDir*: string ## the directory of the config file, or ""

  SourceFingerprint* = object
    size*: int64
    mtime*: int64 ## nanoseconds since the epoch
    hash*: string ## FNV-1a 64 of the content, in hex

  IndexEntry* = object
    ## Where a node is: ``start ..< stop`` in the source, its properties
    ## included, and the column of ``start``, which a slice must be
    ## indented by to read as it did in its document.
    path*: string
    kind*: SpanKind
    start*, stop*: int
    column*: int
    anchor*: string ## the node's own anchor, or ""
    alias*: string  ## for an alias, the anchor it names
    target*: string
      ## for an alias, the path of its anchored node; "" if no path names it
    digest*: uint64
      ## what the node means (see `yaml/spans <spans.html>`_); a slice that
      ## means something else is not used

  IndexedDocument* = object
    offset*, line*: int ## where the document begins in the source
    selfContained*: bool
      ## whether the text of a node means the same out of the document
    entries*: seq[IndexEntry] ## sorted by path; empty unless mode is all

  Hit* = object
    ## A node a path names: its document and where it is.
    document*: int
    entry*: IndexEntry

  Lookup* = object
    ## A path looked up in a ``recent`` index, and the nodes it names.
    path*: string
    used*: int64 ## when it was last looked up, nanoseconds since the epoch
    hits*: seq[Hit]

  YamlIndex* = object
    version*: int
    mode*: IndexMode
    json*: bool ## whether the source is JSON or JSONC
    source*: SourceFingerprint
    documents*: seq[IndexedDocument]
    lookups*: seq[Lookup] ## sorted by path; empty unless mode is recent

const
  indexVersion* = 1
    ## the version of the index format; an index of another version is
    ## built again
  projectIndexDirName* = ".yaml-index"
    ## the project index directory, next to the config file
  defaultRecentLimit* = 256

# Fingerprints

proc fnv1a64(content: string): uint64 =
  result = 14695981039346656037'u64
  for c in content:
    result = (result xor uint64(ord(c))) * 1099511628211'u64

proc nanoseconds(t: Time): int64 = t.toUnix * 1_000_000_000 + t.nanosecond

proc fingerprint*(content: string, mtime = 0'i64): SourceFingerprint =
  ## The fingerprint of a source with ``content``, modified at ``mtime``.
  SourceFingerprint(size: content.len, mtime: mtime,
      hash: toHex(fnv1a64(content)).toLowerAscii())

proc modificationTime*(file: string): int64 =
  ## The modification time of ``file`` in nanoseconds; 0 if it has none.
  try: getLastModificationTime(file).nanoseconds
  except OSError: 0

# Building

proc lineEnd(source: string, pos: int): int =
  result = pos
  while result < source.len and source[result] notin {'\l', '\c'}:
    inc(result)

proc entryOf(source, path: string, span: NodeSpan,
    doc: DocumentSpans): IndexEntry =
  result = IndexEntry(path: path, kind: span.kind, start: span.start,
      stop: span.stop, anchor: span.anchor, alias: span.aliasOf,
      digest: span.digest)
  if span.kind == skEmpty and span.start < 0:
    result.start = 0
    result.stop = 0
  result.column = columnOf(source, result.start)
  if span.kind == skScalar and span.content < span.stop and
      source[span.content] in {'|', '>'}:
    # a block scalar's last line break is part of its value, unless it is
    # stripped, so the slice goes on to the end of the line
    let stop = lineEnd(source, span.stop)
    result.stop = if stop < source.len: stop + 1 else: stop
  if span.kind == skAlias:
    result.target = doc.aliases.getOrDefault(path)

proc documentOf(doc: DocumentSpans): IndexedDocument =
  IndexedDocument(offset: doc.start.offset, line: doc.start.line,
      selfContained: doc.selfContained)

proc byPath(a, b: IndexEntry): int = cmp(a.path, b.path)

proc buildIndex*(source: string, spans: SourceSpans, mode = imAll,
    json = false, mtime = 0'i64): YamlIndex =
  ## The index of ``source``, whose spans are ``spans``. With ``imAll``, it
  ## has every node; with ``imRecent``, only the documents, and nodes come
  ## with `record`.
  result = YamlIndex(version: indexVersion, mode: mode, json: json,
      source: fingerprint(source, mtime))
  for doc in spans.documents:
    var indexed = documentOf(doc)
    if mode == imAll:
      for path, span in doc.nodes.pairs:
        indexed.entries.add(entryOf(source, path, span, doc))
      indexed.entries.sort(byPath)
    result.documents.add(indexed)

proc buildIndex*(source: string, mode = imAll, json = false,
    mtime = 0'i64): YamlIndex
    {.raises: [YamlParserError, YamlStreamError, YamlSpanError].} =
  ## The index of ``source``, parsed; see the other `buildIndex`.
  buildIndex(source, sourceSpans(source, json), mode, json, mtime)

# Looking up
#
# Entries are sorted by path, so a lookup is a binary search. A path that
# leads through an alias is not in the index; like `resolve` of
# `yaml/spans`, the lookup rewrites it to the path below the anchored node,
# using the longest prefix that is an alias.

proc find(doc: IndexedDocument, path: string): int =
  let i = doc.entries.lowerBound(path,
      proc(e: IndexEntry, p: string): int = cmp(e.path, p))
  if i < doc.entries.len and doc.entries[i].path == path: i else: -1

proc prefixes(path: string): seq[string] =
  ## The paths of the ancestors of the Normalized Path ``path``, longest
  ## first. Names escape ``'``, so a quote ends a name only unescaped.
  var
    i = 1 # after "$"
    ends: seq[int]
  while i < path.len:
    if path[i] == '[' and i + 1 < path.len and path[i + 1] == '\'':
      i += 2
      while i < path.len and path[i] != '\'':
        if path[i] == '\\': inc(i)
        inc(i)
      i += 2 # "']"
    else:
      while i < path.len and path[i] != ']': inc(i)
      inc(i)
    ends.add(i)
  for k in countdown(ends.len - 2, 0): result.add(path[0 ..< ends[k]])
  result.add("$")

proc resolve(doc: IndexedDocument, path: string):
    tuple[known: bool, entry: int] =
  ## The entry of the node ``path`` names in ``doc``, -1 if there is none;
  ## not ``known`` if the index cannot tell, as for an alias of a node that
  ## no path names.
  var current = path
  for _ in 0 .. 64:
    let i = doc.find(current)
    if i >= 0:
      let e = doc.entries[i]
      if e.kind != skAlias: return (true, i)
      if e.target.len == 0: return (false, -1)
      current = e.target
      continue
    var rewritten = false
    for prefix in prefixes(current):
      let j = doc.find(prefix)
      if j < 0: continue
      let e = doc.entries[j]
      if e.kind != skAlias: return (true, -1) # no such child
      if e.target.len == 0: return (false, -1)
      current = e.target & current[prefix.len .. ^1]
      rewritten = true
      break
    if not rewritten: return (true, -1)
  (false, -1)

proc findLookup(index: YamlIndex, path: string): int =
  let i = index.lookups.lowerBound(path,
      proc(l: Lookup, p: string): int = cmp(l.path, p))
  if i < index.lookups.len and index.lookups[i].path == path: i else: -1

proc lookup*(index: YamlIndex, path: string): Option[seq[Hit]] =
  ## The nodes that the Normalized Path ``path`` names, one per document
  ## that has one; none if the index does not know, so that the source must
  ## be parsed.
  case index.mode
  of imOff: discard
  of imAll:
    var hits: seq[Hit]
    for d, doc in index.documents:
      let (known, i) = doc.resolve(path)
      if not known: return
      if i >= 0: hits.add(Hit(document: d, entry: doc.entries[i]))
    result = some(hits)
  of imRecent:
    let i = index.findLookup(path)
    if i >= 0: result = some(index.lookups[i].hits)

proc touch*(index: var YamlIndex, path: string, now: int64) =
  ## Notes that ``path`` was looked up at ``now``, so that a ``recent``
  ## index keeps it longer.
  let i = index.findLookup(path)
  if i >= 0: index.lookups[i].used = now

proc record*(index: var YamlIndex, source: string, spans: SourceSpans,
    path: string, now: int64, limit = defaultRecentLimit) =
  ## Adds the nodes ``path`` names to the ``recent`` index of ``source``,
  ## whose spans are ``spans``, and drops the least recently used paths
  ## beyond ``limit``. A path that some document cannot resolve is not
  ## recorded, since the index could not answer it.
  if index.mode != imRecent: return
  var hits: seq[Hit]
  for d, doc in spans.documents:
    try:
      let (resolved, span) = doc.resolve(path)
      hits.add(Hit(document: d, entry: entryOf(source, resolved, span, doc)))
    except YamlSpanMissing: discard # the document has no such node
    except YamlSpanError: return
  let found = index.findLookup(path)
  if found >= 0:
    index.lookups[found].hits = hits
    index.lookups[found].used = now
  else:
    index.lookups.add(Lookup(path: path, used: now, hits: hits))
    if index.lookups.len > max(limit, 1):
      index.lookups.sort(proc(a, b: Lookup): int = cmp(b.used, a.used))
      index.lookups.setLen(max(limit, 1))
    index.lookups.sort(proc(a, b: Lookup): int = cmp(a.path, b.path))

# Reading nodes from slices

proc keepsTrailingBreaks(slice: string): bool =
  ## Whether ``slice`` is a block scalar with the ``+`` chomping indicator.
  var i = 0
  while i < slice.len and slice[i] in {'&', '!'}:
    while i < slice.len and slice[i] notin {' ', '\t', '\l', '\c'}: inc(i)
    while i < slice.len and slice[i] in {' ', '\t', '\l', '\c'}: inc(i)
  if i >= slice.len or slice[i] notin {'|', '>'}: return false
  inc(i)
  while i < slice.len and slice[i] in {'0'..'9', '+', '-'}:
    if slice[i] == '+': return true
    inc(i)

proc isOneDocument(events: seq[Event]): bool =
  ## Whether ``events`` are those of a stream of a single document.
  var documents = 0
  for e in events:
    if e.kind == yamlStartDoc: inc(documents)
  documents == 1

proc constructed(events: seq[Event]): YamlNode =
  var buffer = newBufferYamlStream()
  for e in events: buffer.put(e)
  var s = YamlStream(buffer)
  discard s.next() # yamlStartStream
  construct(s, result)

proc nodeOfSlice*(slice: string, entry: IndexEntry, json = false):
    Option[YamlNode] =
  ## The node whose text, from the source of an index, is ``slice``: the
  ## bytes ``entry.start ..< entry.stop``. None if the slice is not a
  ## single node or does not mean what the node meant in its document,
  ## which its digest tells; the source must then be parsed.
  if entry.kind == skAlias or slice.keepsTrailingBreaks: return
  try:
    var events: seq[Event]
    var text = ""
    if entry.kind == skEmpty:
      # what the parser gives for a node without text
      events = @[startStreamEvent(), startDocEvent(), scalarEvent(),
          endDocEvent(), endStreamEvent()]
    else:
      text = repeat(' ', entry.column) & slice
      if json: text = stripJsonComments(text)
      events = parsedEvents(text).events
    if not events.isOneDocument: return
    let spans = sourceSpans(text, events)
    if spans.documents[0].nodes.getOrDefault("$").digest != entry.digest:
      return
    result = some(constructed(events))
  except CatchableError:
    discard

proc readSlice(file: File, entry: IndexEntry): string =
  result = newString(entry.stop - entry.start)
  if result.len == 0: return
  file.setFilePos(entry.start)
  if file.readChars(result) != result.len:
    raise newException(IOError, "the source is shorter than its index")

# Index files

proc encodeSegment(segment: string): string =
  ## ``segment`` as a file name, everything but unreserved characters
  ## percent-encoded, so that a path keeps its shape but cannot leave the
  ## cache.
  if segment in [".", ".."]:
    for _ in segment: result.add("%2E")
    return
  for c in segment:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}: result.add(c)
    else: result.add('%' & toHex(ord(c), 2))

proc indexFile*(file: string, settings: IndexSettings): string =
  ## The path of the index of the source ``file``; "" if ``settings`` say
  ## there is none.
  if settings.mode == imOff: return ""
  let
    source = absolutePath(file)
    suffix = ".index." & $settings.format
  case settings.location
  of ilBeside:
    return source.parentDir / ("." & source.extractFilename & suffix)
  of ilProject:
    if settings.configDir.len > 0:
      let relative = relativePath(source, absolutePath(settings.configDir))
      if not relative.startsWith(".."):
        return absolutePath(settings.configDir) / projectIndexDirName /
            relative & suffix
  of ilUser: discard
  result = getCacheDir("nimyaml") / "index"
  for segment in source.split({DirSep, AltSep}):
    if segment.len > 0: result = result / encodeSegment(segment)
  result.add(suffix)

proc readIndex*(path: string, format: IndexFormat): Option[YamlIndex] =
  ## The index stored at ``path``; none if there is none, it cannot be read
  ## or it is of another version.
  if path.len == 0 or not fileExists(path): return
  try:
    let content = readFile(path)
    let index =
      case format
      of ifCbor: loadAsCbor[YamlIndex](content)
      of ifYaml: loadAs[YamlIndex](content)
    if index.version == indexVersion: result = some(index)
  except CatchableError:
    discard

proc writeIndex*(index: YamlIndex, path: string, format: IndexFormat): bool =
  ## Stores ``index`` at ``path`` and returns whether it was stored; an
  ## index that cannot be written is no error, just no index.
  if path.len == 0: return false
  try:
    let content =
      case format
      of ifCbor: dumpCbor(Dumper(), index)
      of ifYaml: blockOnlyDumper().dump(index)
    createDir(path.parentDir())
    # write and rename, so that readers never see half an index
    let partial = path & ".partial-" & $getCurrentProcessId()
    writeFile(partial, content)
    moveFile(partial, path)
    result = true
  except CatchableError:
    result = false

proc dropIndex*(file: string, settings: IndexSettings): bool =
  ## Removes the index of ``file``; returns whether there was one.
  let path = indexFile(file, settings)
  if path.len == 0 or not fileExists(path): return false
  try:
    removeFile(path)
    result = true
  except OSError:
    result = false

# Files
#
# What the ``yaml`` tool does with an index: look a path up before reading
# its source, and bring the index up to date when the source has been
# parsed anyway, or written.

proc indexedNodes*(file: string, path: string, settings: IndexSettings):
    Option[seq[YamlNode]] =
  ## The nodes that the Normalized Path ``path`` names in ``file``, one per
  ## document that has one, read from their slices of ``file``; none if
  ## there is no current index that knows them all, so that ``file`` must
  ## be parsed. A ``recent`` index notes the lookup.
  if path.len == 0: return
  let indexPath = indexFile(file, settings)
  var index = readIndex(indexPath, settings.format).get(YamlIndex())
  if index.version != indexVersion or index.mode != settings.mode: return
  var size: int64
  try: size = getFileSize(file)
  except OSError: return
  let mtime = modificationTime(file)
  var touched = false
  if size != index.source.size: return
  if mtime != index.source.mtime:
    try:
      if fingerprint(readFile(file)).hash != index.source.hash: return
    except IOError: return
    index.source.mtime = mtime
    touched = true
  let hits = index.lookup(path)
  if hits.isNone: return
  var nodes: seq[YamlNode]
  try:
    let f = open(file)
    defer: f.close()
    for hit in hits.get():
      if not index.documents[hit.document].selfContained: return
      let node = nodeOfSlice(f.readSlice(hit.entry), hit.entry, index.json)
      if node.isNone: return
      nodes.add(node.get())
  except IOError: return
  if index.mode == imRecent:
    index.touch(path, getTime().nanoseconds)
    touched = true
  if touched: discard index.writeIndex(indexPath, settings.format)
  result = some(nodes)

proc updateIndex*(file, source: string, paths: openArray[string],
    settings: IndexSettings, json = false) =
  ## Brings the index of ``file``, whose content is ``source``, up to date
  ## after the Normalized Paths ``paths`` were looked up in it by parsing:
  ## an ``all`` index that is missing or stale is built, a ``recent`` one
  ## records the paths. ``source`` is parsed again only if the index
  ## changes; a source that does not parse is left alone.
  if settings.mode == imOff: return
  let
    indexPath = indexFile(file, settings)
    mtime = modificationTime(file)
    current = fingerprint(source, mtime)
  var index = readIndex(indexPath, settings.format).get(YamlIndex())
  let stale = index.version != indexVersion or index.mode != settings.mode or
      index.json != json or index.source.size != current.size or
      index.source.hash != current.hash
  var toRecord: seq[string]
  if settings.mode == imRecent:
    for path in paths:
      if path.len > 0 and (stale or index.findLookup(path) < 0):
        toRecord.add(path)
  if not stale and toRecord.len == 0:
    if index.source.mtime != mtime:
      index.source.mtime = mtime
      discard index.writeIndex(indexPath, settings.format)
    return
  var spans: SourceSpans
  try: spans = sourceSpans(source, json)
  except CatchableError: return
  if stale: index = buildIndex(source, spans, settings.mode, json, mtime)
  index.source.mtime = mtime
  let now = getTime().nanoseconds
  for path in toRecord:
    index.record(source, spans, path, now, settings.recentLimit)
  discard index.writeIndex(indexPath, settings.format)

proc refreshIndex*(file, source: string, settings: IndexSettings,
    json = false) =
  ## Builds the index of ``file`` anew after ``source`` was written to it:
  ## the writer knows the content, so the index is right from the start. A
  ## ``recent`` index keeps its paths, looked up in the new content. A
  ## source that does not parse loses its index.
  if settings.mode == imOff: return
  let indexPath = indexFile(file, settings)
  let old = readIndex(indexPath, settings.format)
  var spans: SourceSpans
  try: spans = sourceSpans(source, json)
  except CatchableError:
    discard dropIndex(file, settings)
    return
  var index = buildIndex(source, spans, settings.mode, json,
      modificationTime(file))
  if settings.mode == imRecent and old.isSome:
    for lookup in old.get().lookups:
      index.record(source, spans, lookup.path, lookup.used,
          settings.recentLimit)
  discard index.writeIndex(indexPath, settings.format)
