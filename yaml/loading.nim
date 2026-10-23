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