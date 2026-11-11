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
## `setMember` and `removeMember` edit the member that a path of keys names,
## as a program changes a setting in a config file that a person edits too:
## a missing member is added with the mappings it needs, and a removed one
## takes the comments about it along.
##
## .. code-block:: nim
##   setMember("# head\n", ["files", "save-delay"], "10") ==
##       "# head\nfiles:\n  save-delay: 10\n"
##   removeMember("# head\nfiles:\n  save-delay: 10\n",
##       ["files", "save-delay"]) == "# head\n"
##
## The edited text is parsed again and must have the documents that
## assigning to (or renaming in) the parsed source gives; otherwise
## `YamlEditError` is raised.
##
## Where each node is in the text comes from `yaml/spans <spans.html>`_.

import std/[algorithm, strutils, tables, sets, options, streams]
import data, dom, hints, jsonpath, loading, native, parser, presenter, spans,
    stream, source, memory
import private/[jsonmodel, refidentity, charcopy]

type
  YamlEditError* = object of ValueError
    ## Raised when an assignment cannot be written into the source text.

  Target = NodeSpan

  Document = object
    ## A document of the source: where its nodes are, and its graph, which
    ## is edited the way the text is supposed to be.
    spans: DocumentSpans
    root: YamlNode

  Edit = tuple[first, last: int, text: string]

  Chosen = object
    path: string
    target: Target
    edits: seq[Edit]
    first, last: int # the source range of all edits

  Operation = enum
    ## What is being done, for messages.
    opAssign = "assign to", opRename = "rename", opSet = "set",
    opRemove = "remove"

proc fail(path, reason: string, op = opAssign) {.noreturn.} =
  raise newException(YamlEditError,
      "cannot " & $op & " " & path & " in place: " & reason)

proc fail(reason: string, op = opAssign) {.noreturn.} =
  let verb = if op == opAssign: "assign" else: $op
  raise newException(YamlEditError, "cannot " & verb & " in place: " & reason)

proc readEvents(text: string, json: bool,
    start = none(YamlDocumentStart)): seq[Event] =
  ## The events of ``text``; with ``start``, ``text`` is the source from
  ## that document start on.
  var parser = initYamlParser()
  let input = if json: stripJsonComments(text) else: text
  var s =
    if start.isSome: parser.parse(input, start.get())
    else: parser.parse(input)
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
  let
    spans = sourceSpans(source, events)
    roots = roots(events)
  for i, doc in spans.documents:
    result.docs.add(Document(spans: doc, root: roots[i]))
  result.anchorNames = spans.anchorNames

proc resolve(doc: Document, path: string, op = opAssign):
    tuple[path: string, target: Target] =
  ## The node of the source that ``path`` names; a path through an alias
  ## names the node of its anchor.
  try:
    let (resolved, span) = doc.spans.resolve(path)
    result = (resolved, span)
  except YamlSpanError as e: fail(path, e.msg, op)

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
  if t.kind == skScalar and not json and t.content < t.stop and
      src[t.content] in {'|', '>'}:
    let text = literalBlock(src, t, value, newline)
    if text.len > 0:
      result.add((t.content, t.stop, text))
      return
  if t.kind == skBlock and not json and
      options.quoting != sqJson and options.containers != cFlow and
      value.kind != yScalar:
    var lines = blockLines(valueEvents, options, taken)
    if lines.len > 0:
      var indentation = columnOf(src, t.content)
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
  of skEmpty:
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
  of skBlock:
    var colon = t.content
    while colon > 0 and src[colon - 1] in {' ', '\t', '\l', '\c'}: dec(colon)
    if t.props.len == 0 and colon > 0 and src[colon - 1] == ':':
      result.add((colon, t.stop, " " & text))
    else: result.add((t.content, t.stop, text))
  else: result.add((t.content, t.stop, text))

proc hasNil(node: YamlNode, visited: var HashSet[Identity]): bool =
  ## Whether the graph of ``node`` has a nil node, as an alias of an anchor
  ## that is not defined gives.
  if isNil(node): return true
  if visited.containsOrIncl(identity(node)): return false
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

proc isNull(node: YamlNode): bool =
  node.kind == yScalar and node.tag in [yTagQuestionMark, yTagNull] and
      node.content in ["", "~", "null", "Null", "NULL"]

proc verify(text: string, json: bool, docs: seq[Document], op: Operation,
    start = none(YamlDocumentStart), emptied = -1) =
  ## Checks that ``text`` has the documents ``docs``, whose roots have been
  ## edited the way the text is supposed to have been. With ``start``,
  ## ``text`` is the source from that document start on. The document
  ## ``emptied``, whose root mapping has lost its last member, may also be
  ## gone or empty, as its text then has nothing but comments.
  var edited: seq[YamlNode]
  try: edited = roots(readEvents(text, json, start))
  except YamlParserError, YamlConstructionError:
    fail("the edited text is invalid: " & getCurrentExceptionMsg(), op)
  var docs = docs
  if emptied >= 0:
    if edited.len == docs.len - 1: docs.delete(emptied)
    elif edited.len == docs.len and edited[emptied].isNull:
      edited[emptied] = docs[emptied].root
  if edited.len != docs.len:
    fail("the edited text has other documents", op)
  for i, doc in docs:
    var visited: HashSet[Identity]
    if edited[i].hasNil(visited):
      fail("the edited text has an alias of an anchor it does not define",
          op)
    if not jsonEquals(edited[i], doc.root):
      fail("the edited text does not have the " & (case op
          of opAssign: "assigned values"
          of opRename: "renamed keys"
          of opSet: "value set"
          of opRemove: "member removed"), op)

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
    if k.c.target.kind == skAlias: root.setSlot(k.c, loadValue(value))
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

proc assignInRegion(region: string, events: seq[Event],
    start: YamlDocumentStart, path: JsonPath, value: string,
    newValue: YamlNode, valueEvents: seq[Event], options: PresentationOptions,
    json: bool, taken: HashSet[string], newline: string,
    budget: MemoryBudget): tuple[text: string, count: int] =
  ## `doAssign` for the one document whose text is ``region`` (see
  ## `regionSpans`).
  var root: YamlNode
  var charged = 0
  block:
    var s = newBufferYamlStream()
    for e in events: s.put(e)
    var stream = YamlStream(s)
    charged = construct(stream, root, budget)
  defer: budget.release(charged)
  let doc = Document(spans: regionSpans(region, events, start), root: root)
  var chosen: seq[tuple[doc: int, c: Chosen]]
  for found in doc.root.queryLocated(path):
    let (resolved, target) = doc.resolve(found.path)
    chosen.add((0, chosen(resolved, target, edits(region, target, newValue,
        valueEvents, options, json, taken, newline))))
  let kept = outermost(chosen)
  if kept.len == 0: return (region, 0)
  result = (applied(region, kept, opAssign), kept.len)
  for k in kept:
    if k.c.target.kind == skAlias: doc.root.setSlot(k.c, loadValue(value))
    else:
      for found in doc.root.queryLocated(parseJsonPath(k.c.path)):
        found.node[] = loadValue(value)[]
  verify(result.text, json, @[doc], opAssign, some(start))

proc copy(src: YamlSource, first, last: int64, output: Stream) =
  ## Writes the bytes ``first ..< last`` of ``src`` to ``output``.
  var
    buffer = newString(65536)
    pos = first
  while pos < last:
    let n = src.read(pos, buffer.toOpenArray(0, int(min(int64(buffer.len),
        last - pos)) - 1))
    if n <= 0: break
    output.writeChars(buffer, n)
    pos += n

proc doAssign(src: YamlSource, path: JsonPath, value: string,
    output: Stream, options: PresentationOptions, json: bool,
    document: int): int =
  let newValue = loadValue(value)
  if newValue.kind == yMapping and json:
    for key in newValue.fields.keys:
      if key.kind != yScalar:
        raise newException(YamlEditError, "a JSON key must be a scalar")
  let valueEvents = valueEvents(value)
  proc events(): YamlStream =
    var parser = initYamlParser(budget = src.budget)
    if json: parser.parse(newJsonCommentStripStream(newSourceStream(src)))
    else: parser.parse(src)
  # the anchors of all documents, which new anchors avoid, and the line
  # breaks, as `assign` of a string finds them
  var taken: HashSet[string]
  var newline = "\l"
  block:
    for e in events():
      let anchor = case e.kind
        of yamlScalar: e.scalarProperties.anchor
        of yamlStartMap: e.mapProperties.anchor
        of yamlStartSeq: e.seqProperties.anchor
        else: yAnchorNone
      if anchor != yAnchorNone: taken.incl($anchor)
    let input = newSourceStream(src)
    var
      buffer = newString(65536)
      lastCr = false
    block scan:
      while true:
        let n = input.readDataStr(buffer, 0 ..< buffer.len)
        if n <= 0: break
        for i in 0 ..< n:
          if buffer[i] == '\l' and lastCr:
            newline = "\c\l"
            break scan
          lastCr = buffer[i] == '\c'
  # each document is edited in its region of the text, which reaches up to
  # the next document
  var
    s = events()
    written = 0'i64
    d = 0
  discard s.next() # yamlStartStream
  while s.peek().kind == yamlStartDoc:
    let start = s.documentStart
    var docEvents: seq[Event]
    var charged = 0
    while true:
      let e = s.next()
      let size = 64 + (if e.kind == yamlScalar: e.scalarContent.len else: 0)
      src.budget.reserve(size, "holding a document to assign to it")
      charged += size
      docEvents.add(e)
      if e.kind == yamlEndDoc: break
    let regionEnd =
      if s.peek().kind == yamlStartDoc: int64(s.documentStart.offset)
      else: src.size
    if document < 0 or d == document:
      src.budget.reserve(int(regionEnd - start.offset) * 2,
          "editing a document")
      charged += int(regionEnd - start.offset) * 2
      let region = src.slice(start.offset, regionEnd - 1)
      let (text, count) = assignInRegion(region, docEvents, start, path,
          value, newValue, valueEvents, options, json, taken, newline,
          src.budget)
      if count > 0:
        src.copy(written, start.offset, output)
        output.write(text)
        written = regionEnd
        result += count
    src.budget.release(charged)
    inc(d)
  src.copy(written, src.size, output)

proc assign*(src: YamlSource, path: JsonPath, value: string, output: Stream,
    options = PresentationOptions(), json = false, document = -1): int
    {.raises: [YamlEditError, YamlParserError, YamlConstructionError,
    YamlStreamError, IOError, OSError, YamlMemoryLimitError].} =
  ## Like `assign` of a string, for a source of any size: the edited text
  ## is written to ``output``, and the number of nodes assigned to is
  ## returned. Each document is edited and checked on its own, so one
  ## document and its text are held at a time; ``src`` is read more than
  ## once, so it must have random access (a stream is read into memory).
  if not src.randomAccess:
    let (text, count) = assign(src.readAll("assigning in " & src.name), path,
        value, options, json, document)
    output.write(text)
    return count
  try: result = doAssign(src, path, value, output, options, json, document)
  except YamlEditError as e: raise e
  except YamlParserError as e: raise e
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raise e
  except YamlMemoryLimitError as e: raise e
  except IOError as e: raise e
  except OSError as e: raise e
  except CatchableError:
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

proc keyText(name: string, options: PresentationOptions, json: bool,
    taken: HashSet[string]): string =
  ## The key ``name`` as text, quoted where it would not read as a string.
  ## A name like ``save-delay`` is written plain: the presenter quotes any
  ## scalar with a ``-`` or ``:`` in flow context, but between letters
  ## these are plain in flow and block context alike.
  if not json and name.len > 0 and name[0] notin {'-', '.', '/'} and
      guessType(name) == yTypeUnknown:
    var plain = true
    for c in name:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/'}:
        plain = false
        break
    if plain: return name
  render(@[scalarEvent(name, yTagExclamationMark, style = ssDoubleQuoted)],
      inlineOptions(options, json), json, true, taken)

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
    nameText = keyText(name, options, json, taken)
  var chosen: seq[tuple[doc: int, c: Chosen]]
  for d, doc in docs:
    if document >= 0 and d != document: continue
    for found in doc.root.queryLocated(path):
      let (resolved, target) = doc.resolve(found.path, opRename)
      if target.index >= 0 or target.parentPath.len == 0:
        fail(found.path, "it is not a member of a mapping", opRename)
      if target.name == name: continue
      if not doc.spans.keys.hasKey(resolved):
        fail(found.path, "its key is not in the source", opRename)
      let key = doc.spans.keys[resolved]
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

# setting and removing members
#
# `setMember` and `removeMember` edit the member that a path of keys names,
# the way a program changes a setting in a config file that a person edits
# too. A member that is there is assigned to, as `assign` does; one that is
# not is written after the last member of the deepest mapping of the path
# that is, with any mappings in between created in block style, so that the
# text grows the way a person would write it. Removing takes the lines of a
# member, and with them the comments about it: those directly above it, and
# those below it that are indented deeper than its key.

proc memberPath(keys: openArray[string], n: int): string =
  ## The Normalized Path of the member that the first ``n`` keys name.
  result = "$"
  for i in 0 ..< n: result.addNameSegment(keys[i])

proc lineStart(src: string, pos: int): int =
  result = pos
  while result > 0 and src[result - 1] != '\l': dec(result)

proc nextLine(src: string, pos: int): int =
  ## The start of the line after the one ``pos`` is on, or the end of
  ## ``src``.
  result = pos
  while result < src.len and src[result] != '\l': inc(result)
  if result < src.len: inc(result)

proc isBlank(src: string, first, last: int): bool =
  for i in first ..< last:
    if src[i] notin {' ', '\t'}: return false
  true

proc isCommentLine(src: string, first: int): bool =
  ## Whether the line that begins at ``first`` has nothing but a comment.
  var i = first
  while i < src.len and src[i] in {' ', '\t'}: inc(i)
  i < src.len and src[i] == '#'

proc insertLines(src, text, newline: string, at: int): Edit =
  ## Inserts the lines ``text`` at ``at``: the start of a line, or the end
  ## of ``src``, which may lack a final line break.
  if at >= src.len and src.len > 0 and src[^1] != '\l':
    (at, at, newline & text)
  else: (at, at, text & newline)

proc applyEdits(src: string, edits: seq[Edit], op: Operation): string =
  var edits = edits
  edits.sort(proc(a, b: Edit): int = cmp(b.first, a.first))
  result = src
  var bound = src.len + 1
  for e in edits:
    if e.last > bound: fail("the edits overlap", op)
    result = result[0 ..< e.first] & e.text & result[e.last .. ^1]
    bound = e.first


proc nestedEvents(keys: openArray[string], value: seq[Event]): seq[Event] =
  ## The events of ``value`` within a mapping for each of ``keys``.
  for k in keys:
    result.add(startMapEvent())
    result.add(scalarEvent(k, yTagExclamationMark, style = ssDoubleQuoted))
  result.add(value)
  for k in keys: result.add(endMapEvent())

proc nestedNode(keys: openArray[string], value: YamlNode): YamlNode =
  result = value
  for i in countdown(keys.high, 0):
    result = newYamlNode([(newYamlNode(keys[i], yTagExclamationMark),
        result)])

proc blockMember(keys: openArray[string], value: YamlNode,
    valueEvents: seq[Event], options: PresentationOptions,
    taken: HashSet[string], column: int, newline: string): string =
  ## The member ``keys[0]`` in block style at ``column``, with a block
  ## mapping for each further key and ``value`` in the last one.
  let step = max(options.indentationStep, 1)
  for i, k in keys:
    if i > 0: result.add(newline)
    result.add(repeat(' ', column + i * step) &
        keyText(k, options, false, taken) & ":")
  var lines: seq[string]
  if value.kind != yScalar and options.quoting != sqJson and
      options.containers != cFlow:
    lines = blockLines(valueEvents, options, taken)
  if lines.len == 0:
    result.add(" " & render(valueEvents, inlineOptions(options, false),
        false, true, taken))
  else:
    let indentation = column + keys.len * step
    for line in lines:
      result.add(newline)
      if line.len > 0: result.add(repeat(' ', indentation) & line)

proc members(doc: Document, parentPath: string):
    seq[tuple[key, value: Target]] =
  ## The members of the mapping at ``parentPath`` that paths name.
  for path, span in doc.spans.nodes.pairs:
    if span.parentPath == parentPath and span.index < 0 and
        doc.spans.keys.hasKey(path):
      result.add((doc.spans.keys.getOrDefault(path), span))

proc flowInsert(src: string, doc: Document, parentPath: string,
    parent: Target, member, newline: string): seq[Edit] =
  ## Inserts ``member`` after the last member of the flow mapping
  ## ``parent``: on a line of its own if that member has one.
  let close = parent.stop - 1 # the ``}``
  var
    lastEnd = -1
    lastKey = -1
  for (key, value) in doc.members(parentPath):
    let stop = max(key.stop, value.stop)
    if stop > lastEnd: (lastEnd, lastKey) = (stop, key.start)
  if lastEnd < 0:
    return @[(parent.content + 1, parent.content + 1, member)]
  var j = lastEnd
  while j < close and src[j] in {' ', '\t'}: inc(j)
  let comma = j < close and src[j] == ','
  if comma: inc(j)
  if '\l' in src[j ..< close]:
    let at = nextLine(src, j)
    result.add((at, at, repeat(' ', columnOf(src, lastKey)) & member &
        (if comma: "," else: "") & newline))
    if not comma: result.add((lastEnd, lastEnd, ","))
  elif comma: result.add((j, j, " " & member & ","))
  else: result.add((lastEnd, lastEnd, ", " & member))

proc doSet(source: string, keys: seq[string], value: string,
    options: PresentationOptions, json: bool, document: int): string =
  if keys.len == 0: fail("the path names no member", opSet)
  let
    newValue = loadValue(value)
    valueEvents = valueEvents(value)
    events = readEvents(source, json)
    (docs, taken) = index(source, events)
    newline = if "\c\l" in source: "\c\l" else: "\l"
    inline = inlineOptions(options, json)
  if docs.len == 0:
    # nothing but comments: the member goes after them
    if document > 0: fail("the source has no document " & $document, opSet)
    let text =
      if json:
        render(nestedEvents(keys, valueEvents), inline, json, true, taken)
      else:
        blockMember(keys, newValue, valueEvents, options, taken, 0, newline)
    result = applyEdits(source,
        @[insertLines(source, text, newline, source.len)], opSet)
    verify(result, json, @[Document(root: nestedNode(keys, newValue))], opSet)
    return
  if document >= docs.len:
    fail("the source has no document " & $document, opSet)
  let
    d = max(document, 0)
    doc = docs[d]
  # the deepest member of the path that is there
  var
    node = doc.root
    depth = 0
  while depth < keys.len and node.kind == yMapping:
    let key = node.stringKey(keys[depth])
    if key.isNil: break
    node = node.fields[key]
    inc(depth)
  if depth == keys.len:
    return assign(source, parseJsonPath(memberPath(keys, depth)), value,
        options, json, d).text
  let
    rest = keys[depth .. ^1]
    (parentPath, parent) = doc.resolve(memberPath(keys, depth), opSet)
  var edits: seq[Edit]
  if node.kind == yMapping:
    case parent.kind
    of skBlock:
      let text = blockMember(rest, newValue, valueEvents, options, taken,
          columnOf(source, parent.content), newline)
      edits.add(insertLines(source, text, newline,
          nextLine(source, parent.stop)))
    of skFlow:
      let member = keyText(rest[0], options, json, taken) & ": " &
          render(nestedEvents(rest[1 .. ^1], valueEvents), inline, json, true,
              taken)
      edits.add(flowInsert(source, doc, parentPath, parent, member, newline))
    else: fail(memberPath(keys, depth), "its text is not a mapping", opSet)
    node.fields[newYamlNode(rest[0], yTagExclamationMark)] =
        nestedNode(rest[1 .. ^1], newValue)
  elif node.isNull and parent.kind in {skEmpty, skScalar} and
      parent.props.len == 0 and not parent.inFlow and
      parent.parentMapColumn >= 0 and not json:
    # an empty or null value of a block mapping: a block mapping takes its
    # place, on the lines after its key
    if parent.kind == skScalar:
      var first = parent.content
      while first > 0 and source[first - 1] in {' ', '\t'}: dec(first)
      edits.add((first, parent.stop, ""))
    let text = blockMember(rest, newValue, valueEvents, options, taken,
        parent.parentMapColumn + max(options.indentationStep, 1), newline)
    edits.add(insertLines(source, text, newline,
        nextLine(source, parent.stop)))
    node[] = nestedNode(rest, newValue)[]
  elif node.isNull:
    # a null in a flow collection, with properties, or the root
    return assign(source, parseJsonPath(memberPath(keys, depth)),
        render(nestedEvents(rest, valueEvents), inline, json, true, taken),
        options, json, d).text
  else:
    fail(memberPath(keys, keys.len),
        memberPath(keys, depth) & " is not a mapping", opSet)
  result = applyEdits(source, edits, opSet)
  verify(result, json, docs, opSet)

proc doRemove(source: string, keys: seq[string], json: bool,
    document: int): string =
  if keys.len == 0: fail("the path names no member", opRemove)
  let
    events = readEvents(source, json)
    (docs, _) = index(source, events)
    d = max(document, 0)
  if d >= docs.len: return source
  let doc = docs[d]
  var
    parents: seq[YamlNode]
    node = doc.root
  for k in keys:
    if node.kind != yMapping: return source
    let key = node.stringKey(k)
    if key.isNil: return source
    parents.add(node)
    node = node.fields[key]
  # a mapping that would be left empty goes too, up to the root
  var n = keys.len
  while n > 1 and parents[n - 1].fields.len == 1: dec(n)
  let
    path = memberPath(keys, n)
    (resolved, value) = doc.resolve(path, opRemove)
  if not doc.spans.keys.hasKey(resolved):
    fail(path, "its key is not in the source", opRemove)
  let
    key = doc.spans.keys.getOrDefault(resolved)
    (_, parent) = doc.resolve(value.parentPath, opRemove)
    last = max(key.stop, value.stop)
  var edits: seq[Edit]
  case parent.kind
  of skBlock:
    let ls = lineStart(source, key.start)
    if not isBlank(source, ls, key.start):
      fail(path, "its key does not begin a line", opRemove)
    let column = key.start - ls
    var stop = nextLine(source, last)
    # the comments below it that are indented deeper than its key
    while stop < source.len and isCommentLine(source, stop):
      var i = stop
      while source[i] in {' ', '\t'}: inc(i)
      if i - stop <= column: break
      stop = nextLine(source, i)
    # the comments directly above it and not indented deeper (those are
    # about the member before), but not those above the first member of the
    # root, which may be the head of the file (a modeline, say)
    var firstOfRoot = value.parentPath == "$"
    if firstOfRoot:
      for (other, _) in doc.members(value.parentPath):
        if other.start < key.start: firstOfRoot = false
    var first = ls
    if not firstOfRoot:
      while first > 0:
        let previous = lineStart(source, first - 1)
        if not isCommentLine(source, previous): break
        var i = previous
        while source[i] in {' ', '\t'}: inc(i)
        if i - previous > column: break
        first = previous
    edits.add((first, stop, ""))
  of skFlow:
    var j = last
    while j < source.len and source[j] in {' ', '\t'}: inc(j)
    if j < source.len and source[j] == ',':
      inc(j)
      while j < source.len and source[j] in {' ', '\t'}: inc(j)
      let ls = lineStart(source, key.start)
      if isBlank(source, ls, key.start) and
          (j >= source.len or source[j] in {'\l', '\c'}):
        edits.add((ls, nextLine(source, j), "")) # the member's line
      else: edits.add((key.start, j, ""))
    else:
      # the last member: the comma before it goes
      var p = key.start
      while p > 0 and source[p - 1] in {' ', '\t', '\l', '\c'}: dec(p)
      if p > 0 and source[p - 1] == ',': edits.add((p - 1, last, ""))
      else: edits.add((key.start, last, ""))
  else: fail(path, "its mapping is not in the source", opRemove)
  result = applyEdits(source, edits, opRemove)
  let
    mapping = parents[n - 1]
    emptied = if n == 1 and mapping.fields.len == 1: d else: -1
  mapping.fields.del(mapping.stringKey(keys[n - 1]))
  verify(result, json, docs, opRemove, emptied = emptied)

proc raiseCause(e: ref YamlStreamError) {.noreturn, raises: [
    YamlParserError, YamlConstructionError, YamlStreamError].} =
  ## Raises the error of the parser, or of constructing a node, that the
  ## stream error ``e`` wraps, as it has the position in the source.
  var cause: ref Exception = e
  while not cause.parent.isNil and cause of YamlStreamError:
    cause = cause.parent
  if cause of YamlParserError: raise (ref YamlParserError)(cause)
  elif cause of YamlConstructionError: raise (ref YamlConstructionError)(cause)
  else: raise e

proc setMember*(source: string, keys: openArray[string], value: string,
    options = PresentationOptions(), json = false, document = 0): string
    {.raises: [YamlEditError, YamlParserError, YamlConstructionError,
    YamlStreamError].} =
  ## Sets the member that ``keys`` name, one key per level, to ``value``, a
  ## YAML document, and returns the edited text. A member that is there is
  ## assigned to, as by `assign`. One that is not is added after the last
  ## member of the deepest mapping of the path that is there, with the
  ## mappings missing in between: in block style, at that mapping's
  ## indentation (or in its flow style). A null on the path is replaced by
  ## a mapping, and a text without a document, empty or only comments, gets
  ## the member after its comments:
  ##
  ## .. code-block:: nim
  ##   setMember("# head\n", ["files", "save-delay"], "10") ==
  ##       "# head\nfiles:\n  save-delay: 10\n"
  ##
  ## ``options`` say how a new collection is written and how far a new
  ## level is indented; ``json`` is as for `assign`. Only the ``document``
  ## with that index is edited.
  ##
  ## Raises ``YamlEditError`` if a node on the path is not a mapping or
  ## ``value`` is invalid, and ``YamlParserError`` (or
  ## ``YamlConstructionError``, for a duplicate key) with its position if
  ## ``source`` is invalid.
  try: result = doSet(source, @keys, value, options, json, document)
  except YamlEditError as e: raise e
  except YamlParserError as e: raise e
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raiseCause(e)
  except CatchableError:
    raise newException(YamlEditError,
        "internal error: " & getCurrentExceptionMsg())

proc setMember*(source: string, path: JsonPath, value: string,
    options = PresentationOptions(), json = false, document = 0): string
    {.raises: [YamlEditError, YamlParserError, YamlConstructionError,
    YamlStreamError, YamlJsonPathError].} =
  ## `setMember` at a path of member names, like ``$.files['save-delay']``
  ## (see `memberNames <jsonpath.html#memberNames,JsonPath>`_).
  setMember(source, path.memberNames, value, options, json, document)

proc removeMember*(source: string, keys: openArray[string], json = false,
    document = 0): string {.raises: [YamlEditError, YamlParserError,
    YamlConstructionError, YamlStreamError].} =
  ## Removes the member that ``keys`` name, one key per level, and returns
  ## the edited text. The lines of the member go, with the comment lines
  ## directly above it, which are about it, and those below it that are
  ## indented deeper than its key; but the comments above the first member
  ## of the root stay, as they may be the head of the file. A mapping left
  ## empty is removed too, all the way up to the root. A member of a flow
  ## mapping goes with its comma. Without such a member, ``source`` is
  ## returned as it is. Only the ``document`` with that index is edited.
  ##
  ## Raises ``YamlParserError`` (or ``YamlConstructionError``, for a
  ## duplicate key) with its position if ``source`` is invalid, and
  ## ``YamlEditError`` if the member cannot be removed in place.
  try: result = doRemove(source, @keys, json, document)
  except YamlEditError as e: raise e
  except YamlParserError as e: raise e
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raiseCause(e)
  except CatchableError:
    raise newException(YamlEditError,
        "internal error: " & getCurrentExceptionMsg())

proc removeMember*(source: string, path: JsonPath, json = false,
    document = 0): string {.raises: [YamlEditError, YamlParserError,
    YamlConstructionError, YamlStreamError, YamlJsonPathError].} =
  ## `removeMember` at a path of member names.
  removeMember(source, path.memberNames, json, document)
