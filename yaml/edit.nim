#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ================
## Module yaml/edit
## ================
##
## Assigns a value to the nodes that a `JSONPath <jsonpath.html>`_ selects,
## by editing the source text: only the selected nodes are rewritten, so
## comments, blank lines, styles and the layout of everything else stay as
## they are.
##
## .. code-block:: nim
##   let (text, count) = assign("a: 1  # why\nb: [x]\n",
##       parseJsonPath("$.b[0]"), "{c: 2}")
##   # text == "a: 1  # why\nb: [{c: 2}]\n", count == 1
##
## A replaced node keeps its anchor, so that aliases of it see the new
## value, and loses its tag, which the value brings itself if it has one. A
## path that leads through an alias edits the anchored node; a path that
## ends at an alias replaces the alias. A block collection replaced by a
## collection is written in block style where it was, and a block scalar
## replaced by a quoted string of several lines as a literal block scalar,
## where it can be; any other value is written in a single line, in flow
## style.
##
## `rename` changes the keys of the members that a JSONPath selects in the
## same way: only the text of each key is rewritten, quoted where the new
## name would not read as a string otherwise, and its properties stay.
##
## The edited text is parsed again and must have the documents that
## assigning to (or renaming in) the parsed source gives; otherwise
## `YamlEditError` is raised.

import std/[algorithm, strutils, tables, sets, options]
import data, dom, hints, jsonpath, loading, native, parser, presenter, stream
import private/jsonmodel

type
  YamlEditError* = object of ValueError
    ## Raised when an assignment cannot be written into the source text.

  TargetKind = enum
    tkScalar, tkEmpty, tkAlias, tkFlow, tkBlock

  Token = tuple[first, last: int, tag: bool]

  Target = object
    ## A node of the source. Offsets are bytes; ``stop`` is exclusive and
    ## after the last character of content.
    kind: TargetKind
    start, content, stop: int
    props: seq[Token] # anchor and tag tokens before ``content``
    inFlow: bool
    parentMapColumn: int # of the block mapping the node is a value of, or -1
    parentPath: string
    index: int # in the parent sequence, or -1 for a member or the root
    name: string # in the parent mapping

  Document = object
    targets: Table[string, Target]
    keys: Table[string, Target] # path of a member -> its key
    aliases: Table[string, string] # path of an alias -> path of its anchor
    root: YamlNode

  Walker = object
    src: string
    lineStarts: seq[int]
    events: seq[Event]
    i: int
    doc: Document
    anchors: Table[string, string] # anchor -> path of its node
    anchorNames: HashSet[string]

  Edit = tuple[first, last: int, text: string]

  Chosen = object
    path: string
    target: Target
    edits: seq[Edit]
    first, last: int # the source range of all edits

  Operation = enum
    ## What is being done, for messages.
    opAssign = "assign to", opRename = "rename"

proc fail(path, reason: string, op = opAssign) {.noreturn.} =
  raise newException(YamlEditError,
      "cannot " & $op & " " & path & " in place: " & reason)

proc fail(reason: string, op = opAssign) {.noreturn.} =
  let verb = if op == opAssign: "assign" else: $op
  raise newException(YamlEditError, "cannot " & verb & " in place: " & reason)

proc offset(w: Walker, m: Mark): int =
  if m.line < 1: return 0
  if m.line > w.lineStarts.len: return w.src.len
  min(w.lineStarts[m.line - 1] + m.column - 1, w.src.len)

proc column(src: string, offset: int): int =
  ## Zero-based column of ``offset``.
  var i = offset
  while i > 0 and src[i - 1] != '\l': dec(i)
  offset - i

proc trimEnd(src: string, first, last: int): int =
  result = last
  while result > first and src[result - 1] in {' ', '\t', '\l', '\c'}:
    dec(result)

proc after(src: string, pos: int, indicator: char): int =
  ## The offset after ``indicator`` that follows ``pos`` across whitespace
  ## and comments, or -1.
  var i = pos
  while i < src.len:
    case src[i]
    of ' ', '\t', '\l', '\c': inc(i)
    of '#':
      while i < src.len and src[i] notin {'\l', '\c'}: inc(i)
    else: break
  if i < src.len and src[i] == indicator: i + 1 else: -1

proc tokens(src: string, first, last: int): seq[Token] =
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

proc scalarTarget(w: Walker, e: Event): Target =
  ## The scalar ``e`` as it is in the source: its properties, then its
  ## content.
  result = Target(kind: tkScalar, start: w.offset(e.startPos))
  let stop = w.offset(e.endPos)
  result.content = contentAfterProps(w.src, result.start, stop)
  result.props = tokens(w.src, result.start, result.content)
  result.stop = trimEnd(w.src, result.content, stop)

proc walk(w: var Walker, path, parentPath: string, index: int, name: string,
    inFlow: bool, parentMapColumn, indicatorEnd: int): int =
  ## Indexes the node at ``w.i`` and its children under ``path`` (empty for
  ## nodes that no path names) and returns the end of its content.
  ## ``indicatorEnd`` is the offset after the ``:`` or ``-`` before the node,
  ## or -1.
  let e = w.events[w.i]
  inc(w.i)
  var t = Target(inFlow: inFlow, parentMapColumn: parentMapColumn,
      parentPath: parentPath, index: index, name: name)
  let anchor = e.anchorOf
  if anchor != yAnchorNone:
    w.anchors[$anchor] = path
    w.anchorNames.incl($anchor)
  case e.kind
  of yamlScalar:
    if w.offset(e.endPos) == w.offset(e.startPos) and
        anchor == yAnchorNone and
        e.scalarProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
      t.kind = tkEmpty
      t.start = indicatorEnd
      t.content = indicatorEnd
      t.stop = indicatorEnd
    else:
      let s = w.scalarTarget(e)
      t.kind = tkScalar
      t.start = s.start
      t.content = s.content
      t.props = s.props
      t.stop = s.stop
  of yamlAlias:
    t.kind = tkAlias
    t.start = w.offset(e.startPos)
    t.content = t.start
    t.stop = w.offset(e.endPos)
    if path.len > 0 and w.anchors.hasKey($e.aliasTarget):
      w.doc.aliases[path] = w.anchors[$e.aliasTarget]
  of yamlStartMap, yamlStartSeq:
    let
      isMap = e.kind == yamlStartMap
      flow = (if isMap: e.mapStyle else: e.seqStyle) == csFlow
      startEnd = w.offset(e.endPos)
    t.start = w.offset(e.startPos)
    if flow:
      t.kind = tkFlow
      t.content = startEnd - 1
    else:
      t.kind = tkBlock
      t.content = if isMap: startEnd else: startEnd - 1
    t.props = tokens(w.src, t.start, max(t.start, t.content))
    let childFlow = inFlow or flow
    var last = if isMap and not flow: t.content else: t.content + 1
    if isMap:
      let mapColumn = if flow: -1 else: column(w.src, t.content)
      while w.events[w.i].kind != yamlEndMap:
        let key = w.events[w.i]
        var keyName = ""
        let named = path.len > 0 and key.kind == yamlScalar and
            YamlNode(kind: yScalar, tag: key.scalarProperties.tag,
                content: key.scalarContent).isStringKey
        if named: keyName = key.scalarContent
        let keyEnd = w.walk("", "", -1, "", childFlow, -1, -1)
        var childPath = ""
        if named:
          childPath = path
          childPath.addNameSegment(keyName)
          w.doc.keys[childPath] = w.scalarTarget(key)
        last = w.walk(childPath, path, -1, keyName, childFlow, mapColumn,
            after(w.src, keyEnd, ':'))
    else:
      var index = 0
      while w.events[w.i].kind != yamlEndSeq:
        let indicator =
          if flow: -1
          elif index == 0: t.content + 1
          else: after(w.src, last, '-')
        let childPath = if path.len > 0: path & "[" & $index & "]" else: ""
        last = w.walk(childPath, path, index, "", childFlow, -1, indicator)
        inc(index)
    let endEvent = w.events[w.i]
    inc(w.i)
    t.stop = if flow: w.offset(endEvent.endPos) else: last
  else:
    raise newException(YamlEditError, "unexpected event " & $e.kind)
  if path.len > 0: w.doc.targets[path] = t
  result = t.stop

proc readEvents(text: string, json: bool): seq[Event] =
  var parser = initYamlParser()
  var s = parser.parse(if json: stripJsonComments(text) else: text)
  for e in s: result.add(e)

proc roots(events: seq[Event]): seq[YamlNode] =
  var s = newBufferYamlStream()
  for e in events: s.put(e)
  var stream = YamlStream(s)
  discard stream.next() # yamlStartStream
  while stream.peek().kind == yamlStartDoc:
    var root: YamlNode
    construct(stream, root)
    result.add(root)

proc index(source: string, events: seq[Event]): tuple[docs: seq[Document],
    anchorNames: HashSet[string]] =
  var w = Walker(src: source, events: events, lineStarts: @[0])
  for i, c in source:
    if c == '\l': w.lineStarts.add(i + 1)
  let roots = roots(events)
  w.i = 1 # after yamlStartStream
  while w.events[w.i].kind == yamlStartDoc:
    let docStart = w.offset(w.events[w.i].endPos)
    inc(w.i)
    w.doc = Document(root: roots[result.docs.len])
    w.anchors.clear()
    discard w.walk("$", "", -1, "", false, -1, docStart)
    inc(w.i) # yamlEndDoc
    result.docs.add(w.doc)
  result.anchorNames = w.anchorNames

proc resolve(doc: Document, path: string, op = opAssign):
    tuple[path: string, target: Target] =
  ## The node of the source that ``path`` names; a path through an alias
  ## names the node of its anchor.
  var current = path
  for _ in 0 .. 64:
    if doc.targets.hasKey(current): return (current, doc.targets[current])
    var prefix = ""
    for alias in doc.aliases.keys:
      if alias.len > prefix.len and current.len > alias.len and
          current.startsWith(alias) and current[alias.len] == '[':
        prefix = alias
    if prefix.len == 0: fail(path, "it is not in the source", op)
    let anchored = doc.aliases[prefix]
    if anchored.len == 0:
      fail(path, "it leads through an alias of a node that no path names",
          op)
    current = anchored & current[prefix.len .. ^1]
  fail(path, "its aliases do not end", op)

# rendering values

proc loadValue(value: string): YamlNode =
  try: load(value, result)
  except YamlParserError, YamlConstructionError, IOError, OSError:
    raise newException(YamlEditError,
        "invalid value: " & getCurrentExceptionMsg())

proc valueEvents(value: string): seq[Event] =
  ## The events of the root node of ``value``, which `loadValue` accepted;
  ## unlike a ``YamlNode``, they keep the order of mapping keys.
  var parser = initYamlParser()
  var depth = 0
  try:
    for e in parser.parse(value):
      case e.kind
      of yamlStartDoc: inc(depth)
      of yamlEndDoc: return
      of yamlStartStream, yamlEndStream: discard
      else:
        if depth == 1: result.add(e)
  except YamlStreamError:
    raise newException(YamlEditError,
        "invalid value: " & getCurrentExceptionMsg())

proc render(value: seq[Event], options: PresentationOptions, json, wrap: bool,
    taken: HashSet[string]): string =
  ## The node of the events ``value`` as text, without a final line break.
  ## With ``wrap``, it is written as the item of a flow sequence, so that it
  ## is valid in flow context too. Anchors that ``taken`` has are renamed.
  var
    renamed: Table[string, string]
    events = newBufferYamlStream()
  events.put(startStreamEvent())
  events.put(startDocEvent())
  if wrap: events.put(startSeqEvent())
  try:
    for e in value:
      var e = e.normalized(json)
      # The presenter writes a scalar tagged ``!`` plain wherever it can, but
      # a quoted ``"1"`` written plain would be an integer
      if e.kind == yamlScalar and not json and
          e.scalarProperties.tag == yTagExclamationMark and
          guessType(e.scalarContent) notin {yTypeUnknown, yTypeTimestamp}:
        e.scalarStyle = ssDoubleQuoted
      template rename(a: var Anchor) =
        if a != yAnchorNone and $a in taken:
          if not renamed.hasKey($a):
            var n = 1
            while ($a & $n) in taken: inc(n)
            renamed[$a] = $a & $n
          a = Anchor(renamed[$a])
      case e.kind
      of yamlScalar: rename(e.scalarProperties.anchor)
      of yamlStartMap: rename(e.mapProperties.anchor)
      of yamlStartSeq: rename(e.seqProperties.anchor)
      of yamlAlias: rename(e.aliasTarget)
      else: discard
      events.put(e)
    if wrap: events.put(endSeqEvent())
    events.put(endDocEvent())
    events.put(endStreamEvent())
    result = present(events, options).strip(leading = false)
  except YamlPresenterJsonError,
      YamlPresenterOutputError, YamlStreamError:
    raise newException(YamlEditError,
        "cannot write the value: " & getCurrentExceptionMsg())
  if wrap:
    if not (result.startsWith("[") and result.endsWith("]")):
      raise newException(YamlEditError, "cannot write the value in a line")
    result = result[1 .. ^2].strip()

proc inlineOptions(options: PresentationOptions,
    json: bool): PresentationOptions =
  ## Options for a value in a line; directives are not written, but tag
  ## shorthands need ``deIfNecessary``.
  if json:
    result = PresentationOptions(containers: cFlow, suppressAttrs: true,
        directivesEnd: deIfNecessary, quoting: sqJson, condenseFlow: false)
  else:
    result = PresentationOptions(containers: cFlow, condenseFlow: true,
        directivesEnd: deIfNecessary, quoting: options.quoting)
  result.newlines = nlNone
  result.maxLineLength = none(int)

proc blockLines(value: seq[Event], options: PresentationOptions,
    taken: HashSet[string]): seq[string] =
  ## ``value`` in block style, or nothing if it fits in a line anyway.
  var options = options
  options.newlines = nlLF
  options.directivesEnd = deIfNecessary
  let text = render(value, options, false, false, taken)
  if text.startsWith("---") or '\l' notin text: return
  text.split('\l')

proc literalBlock(src: string, t: Target, value: YamlNode,
    newline: string): string =
  ## The string ``value`` as a literal block scalar in place of the block
  ## scalar ``t``, with its indentation and header comment, or nothing if
  ## the value needs what this does not write: an indentation indicator (a
  ## first line that starts with a space), keeping trailing line breaks, or
  ## characters a block scalar cannot hold. A multi-line text edited in
  ## place should not turn into one long quoted line.
  if value.kind != yScalar or value.tag != yTagExclamationMark or
      '\l' notin value.content: return
  var body = value.content
  var chomping = "-"
  if body.endsWith('\l'):
    body.setLen(body.len - 1)
    chomping = ""
  if body.len == 0 or body.endsWith('\l') or body[0] in {' ', '\t', '\l'}:
    return
  for c in body:
    if c < ' ' and c notin {'\t', '\l'} or c == '\x7F': return
  # the header: the indicator, its own indicators, then the rest of the line
  var i = t.content + 1
  while i < t.stop and src[i] in {'0'..'9', '+', '-'}:
    if src[i] == '+': return # the source keeps its trailing line breaks
    inc(i)
  var headerEnd = i
  while headerEnd < src.len and src[headerEnd] notin {'\l', '\c'}:
    inc(headerEnd)
  if headerEnd >= t.stop: return
  # the indentation of the first line of content
  var lineStart = headerEnd
  var indentation = -1
  while lineStart < t.stop:
    while lineStart < t.stop and src[lineStart] in {'\l', '\c'}: inc(lineStart)
    var j = lineStart
    while j < t.stop and src[j] == ' ': inc(j)
    if j < t.stop and src[j] notin {'\l', '\c'}:
      indentation = j - lineStart
      break
    lineStart = j
  if indentation <= 0: return
  result = "|" & chomping & src[i ..< headerEnd]
  for line in body.split('\l'):
    result.add(newline)
    if line.len > 0: result.add(repeat(' ', indentation) & line)

# editing

proc edits(src: string, t: Target, value: YamlNode, valueEvents: seq[Event],
    options: PresentationOptions, json: bool, taken: HashSet[string],
    newline: string): seq[Edit] =
  for token in t.props:
    if not token.tag: continue
    var (first, last) = (token.first, token.last)
    while last < src.len and src[last] in {' ', '\t'}: inc(last)
    if last >= src.len or src[last] in {'\l', '\c'}:
      while first > 0 and src[first - 1] in {' ', '\t'}: dec(first)
    result.add((first, last, ""))
  if t.kind == tkScalar and not json and t.content < t.stop and
      src[t.content] in {'|', '>'}:
    let text = literalBlock(src, t, value, newline)
    if text.len > 0:
      result.add((t.content, t.stop, text))
      return
  if t.kind == tkBlock and not json and
      options.quoting != sqJson and options.containers != cFlow and
      value.kind != yScalar:
    var lines = blockLines(valueEvents, options, taken)
    if lines.len > 0:
      var indentation = column(src, t.content)
      var first = ""
      if t.parentMapColumn >= 0 and indentation <= t.parentMapColumn and
          value.kind == yMapping:
        first = repeat(' ', options.indentationStep)
        indentation += options.indentationStep
      var text = first & lines[0]
      for line in lines[1 .. ^1]:
        text.add(newline)
        if line.len > 0: text.add(repeat(' ', indentation) & line)
      result.add((t.content, t.stop, text))
      return
  let text = render(valueEvents, inlineOptions(options, json), json, true,
      taken)
  case t.kind
  of tkEmpty:
    if t.content < 0: raise newException(YamlEditError, "no place for a value")
    # after the indicator: the rest of its line, if blank, or before what is
    # there, like a comment
    var at = t.content
    while at > 0 and src[at - 1] in {' ', '\t'}: dec(at)
    var lineEnd = at
    while lineEnd < src.len and src[lineEnd] in {' ', '\t'}: inc(lineEnd)
    let prefix = if at == 0 or src[at - 1] in {'\l', '\c'}: "" else: " "
    if lineEnd >= src.len or src[lineEnd] in {'\l', '\c'}:
      result.add((at, lineEnd, prefix & text))
    else: result.add((at, at, prefix & text))
  of tkBlock:
    var colon = t.content
    while colon > 0 and src[colon - 1] in {' ', '\t', '\l', '\c'}: dec(colon)
    if t.props.len == 0 and colon > 0 and src[colon - 1] == ':':
      result.add((colon, t.stop, " " & text))
    else: result.add((t.content, t.stop, text))
  else: result.add((t.content, t.stop, text))

proc hasNil(node: YamlNode, visited: var HashSet[pointer]): bool =
  ## Whether the graph of ``node`` has a nil node, as an alias of an anchor
  ## that is not defined gives.
  if isNil(node): return true
  if visited.containsOrIncl(cast[pointer](node)): return false
  case node.kind
  of yScalar: false
  of ySequence:
    for item in node.elems:
      if item.hasNil(visited): return true
    false
  of yMapping:
    for key, value in node.fields.pairs:
      if key.hasNil(visited) or value.hasNil(visited): return true
    false

proc setSlot(root: YamlNode, c: Chosen, value: YamlNode) =
  ## Puts ``value`` where the alias ``c`` is in the graph of ``root``.
  let parents = root.queryLocated(parseJsonPath(c.target.parentPath))
  if parents.len != 1: fail(c.path, "its parent is not in the document")
  let parent = parents[0].node
  if c.target.index >= 0:
    parent.elems[c.target.index] = value
    return
  for tag in [yTagExclamationMark, yTagString, yTagQuestionMark]:
    let key = YamlNode(kind: yScalar, tag: tag, content: c.target.name)
    if parent.fields.hasKey(key) and key.isStringKey:
      parent.fields[key] = value
      return
  fail(c.path, "its key is not in the document")

proc chosen(path: string, target: Target, edits: seq[Edit]): Chosen =
  result = Chosen(path: path, target: target, edits: edits,
      first: edits[0].first, last: edits[0].last)
  for e in edits:
    result.first = min(result.first, e.first)
    result.last = max(result.last, e.last)

proc outermost(chosen: seq[tuple[doc: int, c: Chosen]]):
    seq[tuple[doc: int, c: Chosen]] =
  ## ``chosen`` without the nodes that are within another one that is
  ## replaced, which need no edit of their own, and without repetitions, as
  ## paths through aliases give.
  for i, a in chosen:
    var inside = false
    for j, b in chosen:
      if i == j: continue
      let
        same = a.c.first == b.c.first and a.c.last == b.c.last
        within = b.c.first <= a.c.first and a.c.last <= b.c.last and
            b.c.last > b.c.first
      if (same and j < i) or (within and not same):
        inside = true
        break
    if not inside: result.add(a)

proc applied(source: string, kept: seq[tuple[doc: int, c: Chosen]],
    op: Operation): string =
  var all: seq[Edit]
  for k in kept: all.add(k.c.edits)
  all.sort(proc(a, b: Edit): int = cmp(b.first, a.first))
  result = source
  var bound = source.len + 1
  for e in all:
    if e.last > bound:
      fail("the selected nodes overlap", op)
    result = result[0 ..< e.first] & e.text & result[e.last .. ^1]
    bound = e.first

proc verify(text: string, json: bool, docs: seq[Document], op: Operation) =
  ## Checks that ``text`` has the documents ``docs``, whose roots have been
  ## edited the way the text is supposed to have been.
  var edited: seq[YamlNode]
  try: edited = roots(readEvents(text, json))
  except YamlParserError, YamlConstructionError:
    fail("the edited text is invalid: " & getCurrentExceptionMsg(), op)
  if edited.len != docs.len:
    fail("the edited text has other documents", op)
  for i, doc in docs:
    var visited: HashSet[pointer]
    if edited[i].hasNil(visited):
      fail("the edited text has an alias of an anchor it does not define",
          op)
    if not jsonEquals(edited[i], doc.root):
      fail("the edited text does not have the " &
          (if op == opAssign: "assigned values" else: "renamed keys"), op)

proc doAssign(source: string, path: JsonPath, value: string,
    options: PresentationOptions, json: bool, document: int):
    tuple[text: string, count: int] =
  let newValue = loadValue(value)
  if newValue.kind == yMapping and json:
    for key in newValue.fields.keys:
      if key.kind != yScalar:
        raise newException(YamlEditError, "a JSON key must be a scalar")
  let
    valueEvents = valueEvents(value)
    events = readEvents(source, json)
    (docs, taken) = index(source, events)
    newline = if "\c\l" in source: "\c\l" else: "\l"
  var chosen: seq[tuple[doc: int, c: Chosen]]
  for d, doc in docs:
    if document >= 0 and d != document: continue
    for found in doc.root.queryLocated(path):
      let (resolved, target) = doc.resolve(found.path)
      chosen.add((d, chosen(resolved, target, edits(source, target, newValue,
          valueEvents, options, json, taken, newline))))
  let kept = outermost(chosen)
  if kept.len == 0: return (source, 0)
  result = (applied(source, kept, opAssign), kept.len)
  # what the edited text must be: the source with the values assigned
  for k in kept:
    let root = docs[k.doc].root
    if k.c.target.kind == tkAlias: root.setSlot(k.c, loadValue(value))
    else:
      for found in root.queryLocated(parseJsonPath(k.c.path)):
        found.node[] = loadValue(value)[]
  verify(result.text, json, docs, opAssign)

proc assign*(source: string, path: JsonPath, value: string,
    options = PresentationOptions(), json = false, document = -1):
    tuple[text: string, count: int] {.raises: [YamlEditError,
    YamlParserError, YamlConstructionError, YamlStreamError].} =
  ## Assigns ``value``, a YAML document, to each node of ``source`` that
  ## ``path`` selects and returns the edited text with the number of nodes
  ## assigned to. A block collection replaced by a collection is written
  ## with ``options``. With ``json``, ``source`` is JSON or JSONC and values
  ## are written as JSON. With a ``document`` index, only that document of
  ## ``source`` is edited.
  ##
  ## Raises ``YamlEditError`` for an invalid ``value`` and for assignments
  ## that cannot be written into the text, ``YamlParserError`` for an invalid
  ## ``source``.
  try: result = doAssign(source, path, value, options, json, document)
  except YamlEditError as e: raise e
  except YamlParserError as e: raise e
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raise e
  except CatchableError:
    # Normalized Paths are valid queries, and the paths looked up are those
    # the index has
    raise newException(YamlEditError,
        "internal error: " & getCurrentExceptionMsg())

# renaming
#
# A key is a scalar, so renaming one replaces its content in the source with
# the new name, written like a value in a flow sequence: it is then valid in
# flow and block context alike, and quoted wherever a plain scalar would not
# be a string (``1``, ``true``, ``a: b``). The new name is given the
# non-specific tag ``!`` of quoted scalars for this; the key keeps its own
# properties, since a ``!!str`` on it says nothing the new name contradicts.

proc stringKey(parent: YamlNode, name: string): YamlNode =
  ## The key of ``parent`` that names the member ``name``, or nil.
  for key in parent.fields.keys:
    if key.isStringKey and key.content == name: return key

proc doRename(source: string, path: JsonPath, name: string,
    options: PresentationOptions, json: bool, document: int):
    tuple[text: string, count: int] =
  let
    events = readEvents(source, json)
    (docs, taken) = index(source, events)
    nameText = render(@[scalarEvent(name, yTagExclamationMark,
        style = ssDoubleQuoted)], inlineOptions(options, json), json, true,
        taken)
  var chosen: seq[tuple[doc: int, c: Chosen]]
  for d, doc in docs:
    if document >= 0 and d != document: continue
    for found in doc.root.queryLocated(path):
      let (resolved, target) = doc.resolve(found.path, opRename)
      if target.index >= 0 or target.parentPath.len == 0:
        fail(found.path, "it is not a member of a mapping", opRename)
      if target.name == name: continue
      if not doc.keys.hasKey(resolved):
        fail(found.path, "its key is not in the source", opRename)
      let key = doc.keys[resolved]
      chosen.add((d, chosen(resolved, target,
          @[(key.content, key.stop, nameText)])))
  let kept = outermost(chosen)
  if kept.len == 0: return (source, 0)
  result = (applied(source, kept, opRename), kept.len)
  # what the edited text must be: the source with the keys renamed. The
  # mappings are looked up before any is changed, since renaming one
  # changes the paths of the others below it.
  var renames: seq[tuple[parent, key: YamlNode]]
  for k in kept:
    let parents = docs[k.doc].root.queryLocated(
        parseJsonPath(k.c.target.parentPath))
    if parents.len != 1: fail(k.c.path, "its mapping is not in the document",
        opRename)
    let key = parents[0].node.stringKey(k.c.target.name)
    if key.isNil: fail(k.c.path, "its key is not in the document", opRename)
    renames.add((parents[0].node, key))
  for (parent, key) in renames:
    if not parent.stringKey(name).isNil:
      fail("the mapping of " & $path & " already has a member " & name,
          opRename)
    let value = parent.fields[key]
    parent.fields.del(key)
    parent.fields[YamlNode(kind: yScalar, tag: yTagExclamationMark,
        content: name)] = value
  verify(result.text, json, docs, opRename)

proc rename*(source: string, path: JsonPath, name: string,
    options = PresentationOptions(), json = false, document = -1):
    tuple[text: string, count: int] {.raises: [YamlEditError,
    YamlParserError, YamlConstructionError, YamlStreamError].} =
  ## Renames each member of ``source`` that ``path`` selects to ``name``
  ## and returns the edited text with the number of keys rewritten; members
  ## that have that name already are left alone. ``options`` are those of
  ## the value of `assign`, whose quoting they set; ``json`` and
  ## ``document`` are as for `assign`.
  ##
  ## Raises ``YamlEditError`` if ``path`` selects a node that is not a
  ## member of a mapping or the mapping has a member ``name`` already, and
  ## ``YamlParserError`` for an invalid ``source``.
  try: result = doRename(source, path, name, options, json, document)
  except YamlEditError as e: raise e
  except YamlParserError as e: raise e
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raise e
  except CatchableError:
    raise newException(YamlEditError,
        "internal error: " & getCurrentExceptionMsg())
