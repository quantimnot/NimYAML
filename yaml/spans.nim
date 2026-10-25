#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =================
## Module yaml/spans
## =================
##
## Where each node of a YAML source is: the byte range of its text, named by
## its `Normalized Path <jsonpath.html>`_. Events carry line and column
## marks, which say where a node begins and ends but not where its
## properties stop and its content begins, nor where a block collection's
## content really ends (its end event is at the next token, after trailing
## blank lines and comments). Tools that work on the text itself need those
## ranges in bytes:
##
## * `yaml/edit <edit.html>`_ rewrites the text of the nodes a JSONPath
##   selects and leaves everything else alone;
## * `yaml/nodeindex <nodeindex.html>`_ stores the ranges, so that a node can
##   be read from its slice of the source without parsing all of it.
##
## .. code-block:: nim
##   let spans = sourceSpans("a: &x [1, 2]\nb: *x\n")
##   let doc = spans.documents[0]
##   # doc.nodes["$['a']"]: kind skFlow, start 3 (the anchor), content 6,
##   #   stop 12
##   # doc.aliases["$['b']"] == "$['a']"
##   # doc.resolve("$['b'][1]") gives the span of "$['a'][1]"
##
## Only nodes that a path names get a span: the members of a mapping with a
## string key (a scalar that JSON would read as a string) and the
## items of a sequence, recursively from the root ``$``. Keys are no nodes a
## path names, but the key of each named member has its own span in
## ``keys``, so that it can be renamed.
##
## An alias is a node of its own: its span is the ``*name`` token, and
## ``aliases`` has the path of the anchored node it stands for. A path that
## leads *through* an alias names no span; `resolve` rewrites it to the path
## below the anchored node, which is what a reader of the graph sees there.
##
## The ranges are computed from the event marks and the text between them;
## the alternative, a concrete syntax tree from the lexer, would know every
## token but would duplicate the parser. Marks plus a little scanning for
## ``:``, ``-``, properties and trailing blanks are enough for nodes.

import std/[tables, sets, strutils]
import data, dom, jsonpath, loading, parser, stream
import private/jsonmodel

type
  YamlSpanError* = object of ValueError
    ## Raised when a path cannot be resolved to a span, or the events of a
    ## source are not those of a parsed document.

  YamlSpanMissing* = object of YamlSpanError
    ## Raised by `resolve` when the source has no node at a path.

  SpanKind* = enum
    ## How a node is written, which decides what replacing its text needs.
    skScalar ## a scalar with text: plain, quoted or block
    skEmpty  ## an empty scalar without properties, e.g. the value of ``a:``
    skAlias  ## an alias, ``*name``
    skFlow   ## a flow collection, ``[...]`` or ``{...}``
    skBlock  ## a block collection

  PropertyToken* = tuple[first, last: int, tag: bool]
    ## An anchor (``&a``) or tag (``!t``) token: ``first ..< last``.

  NodeSpan* = object
    ## A node of the source. Offsets are bytes; ``stop`` is exclusive and
    ## after the last character of content, so trailing blanks and comments
    ## are not part of the node.
    kind*: SpanKind
    start*: int   ## the first property, or ``content`` if there are none;
                  ## for an empty node, after the ``:`` or ``-`` before it
                  ## (-1 if there is none)
    content*: int ## where the content begins, after the properties
    stop*: int
    props*: seq[PropertyToken]   ## anchor and tag tokens before ``content``
    anchor*: string      ## the node's own anchor, or ""
    aliasOf*: string     ## for an alias, the anchor it names
    inFlow*: bool        ## whether the node is within a flow collection
    parentMapColumn*: int
      ## the column of the block mapping the node is a value of, or -1
    parentPath*: string  ## "" for the root
    index*: int          ## in the parent sequence, or -1
    name*: string        ## the key in the parent mapping, or ""
    digest*: uint64
      ## what the node means, see `Digests`_: two nodes with the same
      ## digest are the same graph, whatever their text

  DocumentSpans* = object
    ## The spans of one document of a source.
    start*: YamlDocumentStart
      ## where the document begins; parsing can start there
    selfContained*: bool
      ## whether the document has no directives and no ``%GLOBAL``
      ## directives apply to it, so that the text of a node means the same
      ## out of the document
    nodes*: Table[string, NodeSpan]    ## path -> span
    keys*: Table[string, NodeSpan]     ## path of a member -> span of its key
    aliases*: Table[string, string]
      ## path of an alias -> path of its anchored node; "" if no path names
      ## that node (it is a key, say)

  SourceSpans* = object
    documents*: seq[DocumentSpans]
    anchorNames*: HashSet[string]
      ## every anchor of the source, so that new anchors can avoid them

# Offsets
#
# Marks count lines from 1 and columns from 1 in bytes, so a table of line
# starts turns them into offsets.

proc lineStarts(src: string): seq[int] =
  result = @[0]
  for i, c in src:
    if c == '\l': result.add(i + 1)

proc offset(lineStarts: seq[int], srcLen: int, m: Mark): int =
  if m.line < 1: return 0
  if m.line > lineStarts.len: return srcLen
  min(lineStarts[m.line - 1] + m.column - 1, srcLen)

proc columnOf*(src: string, offset: int): int =
  ## Zero-based column of ``offset`` in ``src``.
  var i = offset
  while i > 0 and src[i - 1] != '\l': dec(i)
  offset - i

# Scanning the text between marks

proc trimEnd(src: string, first, last: int): int =
  result = last
  while result > first and src[result - 1] in {' ', '\t', '\l', '\c'}:
    dec(result)

proc after(src: string, pos: int, indicator: char): int =
  ## The offset after ``indicator`` that follows ``pos`` across whitespace
  ## and comments, or -1.
  if pos < 0: return -1
  var i = pos
  while i < src.len:
    case src[i]
    of ' ', '\t', '\l', '\c': inc(i)
    of '#':
      while i < src.len and src[i] notin {'\l', '\c'}: inc(i)
    else: break
  if i < src.len and src[i] == indicator: i + 1 else: -1

proc tokens(src: string, first, last: int): seq[PropertyToken] =
  ## The anchor and tag tokens in ``first ..< last``; comments are skipped.
  var i = first
  while i < last:
    case src[i]
    of ' ', '\t', '\l', '\c': inc(i)
    of '#':
      while i < last and src[i] notin {'\l', '\c'}: inc(i)
    else:
      let start = i
      while i < last and src[i] notin {' ', '\t', '\l', '\c'}: inc(i)
      if src[start] in {'&', '!'}:
        result.add((start, i, src[start] == '!'))

proc contentAfterProps(src: string, first, last: int): int =
  ## Skips the anchor and tag tokens at ``first``; plain scalars cannot start
  ## with ``&`` or ``!``.
  result = first
  while result < last and src[result] in {'&', '!'}:
    while result < last and src[result] notin {' ', '\t', '\l', '\c'}:
      inc(result)
    while result < last and src[result] in {' ', '\t', '\l', '\c'}:
      inc(result)

proc anchorOf(e: Event): Anchor =
  case e.kind
  of yamlScalar: e.scalarProperties.anchor
  of yamlStartMap: e.mapProperties.anchor
  of yamlStartSeq: e.seqProperties.anchor
  else: yAnchorNone

# Digests
# =======
#
# A digest sums up what a node means, as a parser reads it: its kind, its
# tag and content, and the digests of its children in order (keys
# included), as a 64-bit FNV-1a hash. An alias means its anchored node, so
# its digest is that node's; an alias of an anchor not defined (yet) is
# its name. Styles, anchor names, comments and layout are not part of it.
#
# The digest is what makes reading a node from its slice of the source
# safe (see `yaml/nodeindex <nodeindex.html>`_): whatever in the slice's
# surroundings changes its meaning, from a tag on the line before it to the
# indentation its block scalar indicator counts from, changes its digest.

const
  fnvOffset = 14695981039346656037'u64
  fnvPrime = 1099511628211'u64

proc mix(h: var uint64, text: string) =
  for c in text: h = (h xor uint64(ord(c))) * fnvPrime
  h = (h xor 0xFF'u64) * fnvPrime # ends the text, which holds no 0xFF byte
                                  # that is not part of a UTF-8 sequence

proc mix(h: var uint64, x: uint64) =
  for k in 0 ..< 8: h = (h xor ((x shr (8 * k)) and 0xFF'u64)) * fnvPrime

# The walk
#
# One pass over the events of a document, in step with the nodes they
# describe. Each node returns where its content ends, because a block
# collection ends with its last child, not at its end event.

type Walker = object
  src: string
  lineStarts: seq[int]
  events: seq[Event]
  i: int
  doc: DocumentSpans
  anchors: Table[string, string] # anchor -> path of its node
  anchorDigests: Table[string, uint64]
  anchorNames: HashSet[string]
  digest: uint64 # of the node walked last

proc offset(w: Walker, m: Mark): int = offset(w.lineStarts, w.src.len, m)

proc scalarSpan(w: Walker, e: Event): NodeSpan =
  ## The scalar ``e`` as it is in the source: its properties, then its
  ## content.
  result = NodeSpan(kind: skScalar, start: w.offset(e.startPos))
  let stop = w.offset(e.endPos)
  result.content = contentAfterProps(w.src, result.start, stop)
  result.props = tokens(w.src, result.start, result.content)
  result.stop = trimEnd(w.src, result.content, stop)

proc walk(w: var Walker, path, parentPath: string, index: int, name: string,
    inFlow: bool, parentMapColumn, indicatorEnd: int): int =
  ## Records the node at ``w.i`` and its children under ``path`` (empty for
  ## nodes that no path names) and returns the end of its content.
  ## ``indicatorEnd`` is the offset after the ``:`` or ``-`` before the node,
  ## or -1. Leaves the node's digest in ``w.digest``.
  let e = w.events[w.i]
  inc(w.i)
  var t = NodeSpan(inFlow: inFlow, parentMapColumn: parentMapColumn,
      parentPath: parentPath, index: index, name: name)
  let anchor = e.anchorOf
  if anchor != yAnchorNone:
    t.anchor = $anchor
    w.anchors[$anchor] = path
    w.anchorNames.incl($anchor)
  var digest = fnvOffset
  case e.kind
  of yamlScalar:
    digest.mix("S")
    digest.mix($e.scalarProperties.tag)
    digest.mix(e.scalarContent)
    if w.offset(e.endPos) == w.offset(e.startPos) and
        anchor == yAnchorNone and
        e.scalarProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
      t.kind = skEmpty
      t.start = indicatorEnd
      t.content = indicatorEnd
      t.stop = indicatorEnd
    else:
      let s = w.scalarSpan(e)
      t.kind = skScalar
      t.start = s.start
      t.content = s.content
      t.props = s.props
      t.stop = s.stop
  of yamlAlias:
    t.kind = skAlias
    t.aliasOf = $e.aliasTarget
    if w.anchorDigests.hasKey($e.aliasTarget):
      digest = w.anchorDigests.getOrDefault($e.aliasTarget)
    else:
      digest.mix("*")
      digest.mix($e.aliasTarget)
    t.start = w.offset(e.startPos)
    t.content = t.start
    t.stop = w.offset(e.endPos)
    if path.len > 0 and w.anchors.hasKey($e.aliasTarget):
      w.doc.aliases[path] = w.anchors.getOrDefault($e.aliasTarget)
  of yamlStartMap, yamlStartSeq:
    let
      isMap = e.kind == yamlStartMap
      flow = (if isMap: e.mapStyle else: e.seqStyle) == csFlow
      startEnd = w.offset(e.endPos)
    digest.mix(if isMap: "M" else: "Q")
    digest.mix($(if isMap: e.mapProperties.tag else: e.seqProperties.tag))
    t.start = w.offset(e.startPos)
    if flow:
      t.kind = skFlow
      t.content = startEnd - 1
    else:
      t.kind = skBlock
      t.content = if isMap: startEnd else: startEnd - 1
    t.props = tokens(w.src, t.start, max(t.start, t.content))
    let childFlow = inFlow or flow
    var last = if isMap and not flow: t.content else: t.content + 1
    if isMap:
      let mapColumn = if flow: -1 else: columnOf(w.src, t.content)
      while w.events[w.i].kind != yamlEndMap:
        let key = w.events[w.i]
        var keyName = ""
        let named = path.len > 0 and key.kind == yamlScalar and
            YamlNode(kind: yScalar, tag: key.scalarProperties.tag,
                content: key.scalarContent).isStringKey
        if named: keyName = key.scalarContent
        let keyEnd = w.walk("", "", -1, "", childFlow, -1, -1)
        digest.mix(w.digest)
        var childPath = ""
        if named:
          childPath = path
          childPath.addNameSegment(keyName)
          w.doc.keys[childPath] = w.scalarSpan(key)
        let valueEnd = w.walk(childPath, path, -1, keyName, childFlow,
            mapColumn, after(w.src, keyEnd, ':'))
        digest.mix(w.digest)
        # an empty node with no indicator before it has no end of its own
        last = if valueEnd >= 0: valueEnd else: max(last, keyEnd)
    else:
      var index = 0
      while w.events[w.i].kind != yamlEndSeq:
        let indicator =
          if flow: -1
          elif index == 0: t.content + 1
          else: after(w.src, last, '-')
        let childPath = if path.len > 0: path & "[" & $index & "]" else: ""
        let itemEnd = w.walk(childPath, path, index, "", childFlow, -1,
            indicator)
        digest.mix(w.digest)
        if itemEnd >= 0: last = itemEnd
        inc(index)
    let endEvent = w.events[w.i]
    inc(w.i)
    t.stop = if flow: w.offset(endEvent.endPos) else: last
  else:
    raise newException(YamlSpanError, "unexpected event " & $e.kind)
  if anchor != yAnchorNone: w.anchorDigests[$anchor] = digest
  t.digest = digest
  w.digest = digest
  if path.len > 0: w.doc.nodes[path] = t
  result = t.stop

# Sources

proc sourceSpans*(source: string, events: seq[Event],
    starts: seq[YamlDocumentStart] = @[]): SourceSpans
    {.raises: [YamlSpanError].} =
  ## The spans of ``source``, whose events, from ``yamlStartStream`` on, are
  ## ``events``. ``starts`` are the document starts the parser reported, one
  ## per document; without them, ``start`` of each document holds its
  ## ``yamlStartDoc`` position only and no document is ``selfContained``.
  var w = Walker(src: source, events: events, lineStarts: lineStarts(source))
  w.i = 1 # after yamlStartStream
  while w.events[w.i].kind == yamlStartDoc:
    let
      number = result.documents.len
      docStart = w.offset(w.events[w.i].endPos)
    w.doc = DocumentSpans()
    if number < starts.len:
      let start = starts[number]
      w.doc.start = start
      w.doc.selfContained = start.globals.len == 0 and
          (start.offset >= source.len or source[start.offset] != '%')
    else:
      w.doc.start = YamlDocumentStart(offset: w.offset(w.events[w.i].startPos),
          line: w.events[w.i].startPos.line, index: number)
    inc(w.i)
    w.anchors.clear()
    w.anchorDigests.clear()
    discard w.walk("$", "", -1, "", false, -1, docStart)
    inc(w.i) # yamlEndDoc
    result.documents.add(w.doc)
  result.anchorNames = w.anchorNames

proc parsedEvents*(source: string, json = false):
    tuple[events: seq[Event], starts: seq[YamlDocumentStart]]
    {.raises: [YamlParserError, YamlStreamError].} =
  ## The events of ``source`` and the start of each of its documents. With
  ## ``json``, ``source`` is JSON or JSONC, whose comments are ignored.
  var parser = initYamlParser()
  var s = parser.parse(if json: stripJsonComments(source) else: source)
  try:
    for e in s:
      result.events.add(e)
      if e.kind == yamlStartDoc: result.starts.add(s.documentStart)
  except ValueError:
    # documentStart of a stream from parse does not fail
    raise newException(YamlStreamError, getCurrentExceptionMsg())

proc sourceSpans*(source: string, json = false): SourceSpans
    {.raises: [YamlParserError, YamlStreamError, YamlSpanError].} =
  ## The spans of ``source``, parsed; ``json`` is as for `parsedEvents`.
  let (events, starts) = parsedEvents(source, json)
  sourceSpans(source, events, starts)

# Paths through aliases

proc resolve*(doc: DocumentSpans, path: string):
    tuple[path: string, span: NodeSpan] {.raises: [YamlSpanError].} =
  ## The node of the source that ``path`` names, and its path; a path
  ## through an alias names the node below its anchored node. Raises
  ## ``YamlSpanError``, whose message says why, if no node of the source is
  ## there.
  var current = path
  for _ in 0 .. 64:
    if doc.nodes.hasKey(current):
      try: return (current, doc.nodes[current])
      except KeyError: discard
    var prefix = ""
    for alias in doc.aliases.keys:
      if alias.len > prefix.len and current.len > alias.len and
          current.startsWith(alias) and current[alias.len] == '[':
        prefix = alias
    if prefix.len == 0:
      raise newException(YamlSpanMissing, "it is not in the source")
    let anchored = doc.aliases.getOrDefault(prefix)
    if anchored.len == 0:
      raise newException(YamlSpanError,
          "it leads through an alias of a node that no path names")
    current = anchored & current[prefix.len .. ^1]
  raise newException(YamlSpanError, "its aliases do not end")
