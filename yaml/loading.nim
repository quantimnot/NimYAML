#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===================
## Module yaml/loading
## ===================
##
## The loading API enables you to load a YAML character stream
## into native Nim value. Along with the dumping API, this
## forms the highest-level API of NimYAML.
##
## JSON is loaded like YAML, of which it is a subset. `loadJsonc`_ also
## loads JSONC, JSON with comments and trailing commas, and `loadJsonLines`_
## loads JSON Lines, one JSON value per line.

import std / [ streams, strutils ]
import native, parser, private/internal
export native, YamlConstructionError, YamlParserError

proc load*[K](input: Stream | string, target: var K)
    {.raises: [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads a Nim value from a YAML character stream.
  try:
    var
      parser = initYamlParser()
      events = parser.parse(input)
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
    else: internalError("Unexpected exception: " & $e.parent.name)

proc loadAs*[K](input: Stream | string): K {.raises:
    [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads the given YAML input to a value of the type K and returns it
  load(input, result)

proc loadMultiDoc*[K](input: Stream | string, target: var seq[K]) =
  var
    parser = initYamlParser()
    events = parser.parse(input)
    e = events.next()
  yAssert(e.kind == yamlStartStream)
  try:
    while events.peek().kind == yamlStartDoc:
      var item: K
      construct(events, item)
      target.add(item)
    e = events.next()
    yAssert(e.kind == yamlEndStream)
  except YamlConstructionError as e:
    discard events.getLastTokenContext(e.lineContent)
    raise e
  except YamlStreamError as e:
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)

proc stripJsonComments*(input: string): string {.raises: [YamlParserError].} =
  ## Returns ``input`` with every ``//`` line comment and ``/* */`` block
  ## comment outside of a string replaced by spaces. Line breaks are kept, so
  ## each position in the result is the same as in ``input``.
  ##
  ## Raises ``YamlParserError`` for a block comment that is not closed.
  result = input
  var
    i = 0
    line = 1
    lineStart = 0
  template blank(j: int) =
    if result[j] notin {'\l', '\c'}: result[j] = ' '
  while i < input.len:
    case input[i]
    of '\l':
      inc line
      lineStart = i + 1
      inc i
    of '"':
      inc i
      while i < input.len and input[i] notin {'"', '\l'}:
        if input[i] == '\\': inc i
        inc i
      if i < input.len and input[i] == '"': inc i
    of '/':
      if i + 1 < input.len and input[i + 1] == '/':
        while i < input.len and input[i] notin {'\l', '\c'}:
          blank(i)
          inc i
      elif i + 1 < input.len and input[i + 1] == '*':
        let
          start = Mark(line: line, column: i - lineStart + 1)
          startLineStart = lineStart
        blank(i)
        blank(i + 1)
        i += 2
        while i + 1 < input.len and not (input[i] == '*' and input[i + 1] == '/'):
          if input[i] == '\l':
            inc line
            lineStart = i + 1
          blank(i)
          inc i
        if i + 1 >= input.len:
          var lineEnd = startLineStart
          while lineEnd < input.len and input[lineEnd] notin {'\l', '\c'}:
            inc lineEnd
          raise (ref YamlParserError)(
            msg: "block comment is not closed", mark: start,
            lineContent: input[startLineStart ..< lineEnd] & "\n" &
              repeat(' ', start.column - 1) & "^")
        blank(i)
        blank(i + 1)
        i += 2
      else: inc i
    else: inc i

# streaming filters
#
# A filter stream reads its input in chunks and hands each character to its
# ``step``, which appends what replaces it to ``output``.

type
  FilterStream = ref object of StreamObj
    input: Stream
    chunk, output: string
    outPos: int
    ended: bool
    step: proc (f: FilterStream, c: char)
        {.nimcall, gcsafe, raises: [IOError], tags: [].}
    finish: proc (f: FilterStream)
        {.nimcall, gcsafe, raises: [IOError], tags: [].}

proc fill(f: FilterStream) {.raises: [IOError, OSError].} =
  ## Refills ``output`` with the replacement of the next chunk of input.
  f.output.setLen(0)
  f.outPos = 0
  while f.output.len == 0 and not f.ended:
    f.chunk.setLen(8192)
    let n = f.input.readDataStr(f.chunk, 0 ..< f.chunk.len)
    f.chunk.setLen(max(n, 0))
    if n <= 0:
      f.ended = true
      f.finish(f)
    for c in f.chunk: f.step(f, c)

proc filterReadStr(s: Stream, buffer: var string, slice: Slice[int]): int =
  let f = FilterStream(s)
  var i = slice.a
  while i <= slice.b:
    if f.outPos >= f.output.len:
      if f.ended: break
      f.fill()
      if f.outPos >= f.output.len: break
    let n = min(slice.b - i + 1, f.output.len - f.outPos)
    copyMem(addr buffer[i], addr f.output[f.outPos], n)
    f.outPos += n
    i += n
  i - slice.a

proc filterRead(s: Stream, buffer: pointer, bufLen: int): int =
  var str = newString(bufLen)
  result = filterReadStr(s, str, 0 ..< bufLen)
  if result > 0: copyMem(buffer, addr str[0], result)

proc filterAtEnd(s: Stream): bool =
  let f = FilterStream(s)
  f.outPos >= f.output.len and f.ended

proc initFilter(f: FilterStream, input: Stream) =
  f.input = input
  f.readDataStrImpl = filterReadStr
  f.readDataImpl = filterRead
  f.atEndImpl = filterAtEnd

type
  JsoncState = enum
    jsNormal, jsSlash, jsString, jsEscape, jsLine, jsBlock

  JsoncStripStream = ref object of FilterStream
    state: JsoncState
    line, column: int  # position of the next input character
    lineText: string   # the start of the current line, for error messages
    blockStart: Mark
    blockLine: string  # the start of the line where the open comment began
    star: bool         # the previous character of a block comment was '*'

const maxLineText = 4096

proc jsoncStep(f: FilterStream, c: char) =
  let j = JsoncStripStream(f)
  if j.lineText.len < maxLineText and c notin {'\l', '\c'}: j.lineText.add(c)
  case j.state
  of jsSlash:
    case c
    of '/':
      j.output.add("  ")
      j.state = jsLine
    of '*':
      j.output.add("  ")
      j.state = jsBlock
      j.star = false
      j.blockStart = Mark(line: j.line, column: j.column - 1)
      j.blockLine = j.lineText
    else:
      j.output.add('/')
      j.state = jsNormal
      if c == '"': j.state = jsString
      j.output.add(c)
  of jsNormal:
    case c
    of '"':
      j.output.add(c)
      j.state = jsString
    of '/': j.state = jsSlash
    else: j.output.add(c)
  of jsString:
    j.output.add(c)
    if c == '\\': j.state = jsEscape
    elif c in {'"', '\l'}: j.state = jsNormal
  of jsEscape:
    j.output.add(c)
    j.state = jsString
  of jsLine:
    if c in {'\l', '\c'}:
      j.output.add(c)
      j.state = jsNormal
    else: j.output.add(' ')
  of jsBlock:
    if j.blockStart.line == j.line and j.blockLine.len < maxLineText and
        c notin {'\l', '\c'}:
      j.blockLine.add(c)
    j.output.add(if c in {'\l', '\c'}: c else: ' ')
    if j.star and c == '/': j.state = jsNormal
    j.star = c == '*'
  if c == '\l':
    inc j.line
    j.column = 1
    j.lineText.setLen(0)
  else: inc j.column

proc jsoncFinish(f: FilterStream) =
  let j = JsoncStripStream(f)
  case j.state
  of jsSlash: j.output.add('/')
  of jsBlock:
    let e = (ref YamlParserError)(msg: "block comment is not closed",
        mark: j.blockStart, lineContent: j.blockLine & "\n" &
          repeat(' ', j.blockStart.column - 1) & "^")
    raise (ref IOError)(msg: e.msg, parent: e)
  else: discard

proc newJsonCommentStripStream*(input: Stream): Stream =
  ## A stream of ``input`` like `stripJsonComments`_ returns it: comments
  ## blanked by spaces, so that positions stay the same. It reads ``input``
  ## in chunks, so it works on input of any size. A block comment that is
  ## not closed makes reading raise an ``IOError`` whose ``parent`` is the
  ## ``YamlParserError`` that `stripJsonComments`_ raises.
  let j = JsoncStripStream(line: 1, column: 1, step: jsoncStep,
      finish: jsoncFinish)
  j.initFilter(input)
  j

type JsonLinesStream = ref object of FilterStream
  atLineStart: bool
  held: string # leading whitespace of the current line

proc jsonLinesStep(f: FilterStream, c: char) =
  let j = JsonLinesStream(f)
  if j.atLineStart:
    case c
    of ' ', '\t': j.held.add(c)
    of '\l', '\c':
      j.output.add(j.held)
      j.output.add(c)
      j.held.setLen(0)
    else:
      j.output.add("--- ")
      j.output.add(j.held)
      j.output.add(c)
      j.held.setLen(0)
      j.atLineStart = false
  else:
    j.output.add(c)
    if c in {'\l', '\c'}: j.atLineStart = true

proc jsonLinesFinish(f: FilterStream) =
  let j = JsonLinesStream(f)
  j.output.add(j.held)
  j.held.setLen(0)

proc newJsonLinesStream*(input: Stream): Stream =
  ## A stream of the JSON Lines ``input`` as YAML: each non-blank line
  ## starts a document with ``--- ``, so that lines keep their numbers.
  let j = JsonLinesStream(atLineStart: true, step: jsonLinesStep,
      finish: jsonLinesFinish)
  j.initFilter(input)
  j

proc loadJsonc*[K](input: Stream | string, target: var K)
    {.raises: [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads a Nim value from JSONC: JSON that may contain ``//`` and
  ## ``/* */`` comments and trailing commas in arrays and objects. Like
  ## `load`_, it accepts any YAML; comments are removed before parsing.
  ## Error positions refer to ``input``.
  when input is Stream:
    load(stripJsonComments(input.readAll()), target)
  else:
    load(stripJsonComments(input), target)

proc loadAsJsonc*[K](input: Stream | string): K {.raises:
    [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads the given JSONC input to a value of the type K and returns it.
  loadJsonc(input, result)

iterator jsonLines*[K](input: Stream | string): K {.raises:
    [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads a value of the type K from each line of JSON Lines input
  ## (``.jsonl``, also known as NDJSON) and yields it as soon as it has been
  ## read. Lines end with LF or CRLF; blank lines are skipped. Each line is
  ## loaded like the input of `load`_, so it may hold any single-line YAML.
  ## The ``line`` of an error's ``mark`` is that of the input.
  let s = when input is Stream: input else: newStringStream(input)
  var
    line: string
    lineNumber = 0
  while s.readLine(line):
    inc lineNumber
    if line.isEmptyOrWhitespace: continue
    var item: K
    try: load(line, item)
    except YamlParserError as e:
      e.mark.line = lineNumber
      raise e
    except YamlConstructionError as e:
      e.mark.line = lineNumber
      raise e
    yield item

proc loadJsonLines*[K](input: Stream | string, target: var seq[K]) {.raises:
    [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads a value of the type K from each line of JSON Lines input and adds
  ## them to ``target``. See `jsonLines`_.
  for item in jsonLines[K](input): target.add(item)