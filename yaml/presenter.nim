#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =====================
## Module yaml/presenter
## =====================
##
## This is the presenter API, used for generating YAML character streams.

import std / [streams, deques, strutils, options]
import data, taglib, stream, private/internal, hints, parser

type

  ContainerStyle* = enum
    ## How to serialize containers nodes.
    ##
    ## - ``cBlock`` writes all container nodes in block style,
    ##   i.e. indentation-based.
    ## - ``cFlow`` writes all container nodes in flow style,
    ##   i.e. JSON-like.
    ## - ``cMixed`` writes container nodes that only contain alias nodes
    ##   and short scalar nodes in flow style, all other container nodes
    ##   in block style.
    cBlock, cFlow, cMixed

  NewLineStyle* = enum
    ## What kind of newline sequence is used when presenting.
    ##
    ## - ``nlLF``: Use a single linefeed char as newline.
    ## - ``nlCRLF``: Use a sequence of carriage return and linefeed as
    ##   newline.
    ## - ``nlOSDefault``: Use the target operation system's default newline
    ##   sequence (CRLF on Windows, LF everywhere else).
    ## - ``nlNone``: Don't use newlines, write everything in one line.
    ##   forces ContainerStyle cFlow.
    nlLF, nlCRLF, nlOSDefault, nlNone

  OutputYamlVersion* = enum
    ## Specify which YAML version number the presenter shall emit. The
    ## presenter will always emit content that is valid YAML 1.1, but by
    ## default will write a directive ``%YAML 1.2``. For compatibility with
    ## other YAML implementations, it is possible to change this here.
    ##
    ## It is also possible to specify that the presenter shall not emit any
    ## YAML version. The generated content is then guaranteed to be valid
    ## YAML 1.1 and 1.2 (but not 1.0 or any newer YAML version).
    ##
    ## ``ovDocument`` writes the version each document's ``yamlStartDoc``
    ## event carries, if any; for parsed input that is the effective version,
    ## including one inherited from ``%GLOBAL YAML``.
    ov1_2, ov1_1, ovNone, ovDocument

  SchemaDirectiveStyle* = enum
    ## Whether and how to write the schema a document declares (the
    ## effective ``%SCHEMA`` of its ``yamlStartDoc`` event):
    ## - ``sdNone``: Don't write it.
    ## - ``sdDirective``: As a ``%SCHEMA`` directive. Other YAML processors
    ##   ignore it.
    ## - ``sdModeline``: As a ``# yaml-language-server: $schema=`` comment,
    ##   which editors understand; as a directive if there are several
    ##   schemas, since a modeline names one.
    sdNone, sdDirective, sdModeline

  ScalarQuotingStyle* = enum
    ## Specifies whether scalars should forcibly be double-quoted.
    ## - ``sqUnset``: Quote where necessary
    ## - ``sqDouble``: Force double-quoted style for every scalar
    ## - ``sqJson``: Force JSON-compatible double-quoted style for every scalar
    ##   except for scalars of other JSON types (bool, int, double)
    sqUnset, sqDouble, sqJson

  DirectivesEndStyle* = enum
    ## Whether to write a directives end marker '---'
    ## - ``deAlways``: Always write it.
    ## - ``deIfNecessary``: Write it if any directive has been written,
    ##   or if the root node has an explicit tag
    ## - ``deNever``: Don't write it. Suppresses output of directives
    deAlways, deIfNecessary, deNever

  CommentIndentation* = enum
    ## Where `transform` writes a comment that has a line of its own:
    ## - ``ciNode``: At the indentation of the node it precedes, or of the
    ##   collection it ends.
    ## - ``ciSource``: At its column in the input, as far as that attaches
    ##   it to the same node when the output is read again: before a node,
    ##   at most at the node's indentation; at the end of a collection, at
    ##   least at the collection's indentation and less than that of a
    ##   collection that ends along with it, and right after a block scalar
    ##   at the collection's indentation, so that it does not become content
    ##   of the scalar.
    ciNode = "node", ciSource = "source"

  CommentOptions* = object
    ## How `transform` keeps the comments of its input. A comment that
    ## follows content on its line stays at the end of the line of its node;
    ## a comment that has a line of its own stays before the node it
    ## precedes, or at the end of the collection or document it ends. A
    ## collection that holds a comment is written in block style. Comments
    ## are dropped from output without line breaks (``nlNone``) and from
    ## JSON output (``sqJson``), which have no room for them.
    keep*       : bool = false ## whether comments are kept
    indentation*: CommentIndentation = ciNode ## where comment lines are indented to
    gap*        : int = 2 ## spaces between content and a comment after it
    blankLines* : bool = true ## whether a blank line before or after a comment line is kept

  PresentationOptions* = object
    ## Options for generating a YAML character stream
    containers*     : ContainerStyle = cMixed ## how mappings and sequences are presented
    indentationStep*: int = 2 ## how many spaces a new level should be indented
    newlines*       : NewLineStyle = nlOSDefault ## kind of newline sequence to use
    outputVersion*  : OutputYamlVersion = ovNone ## whether to write the %YAML tag
    maxLineLength*  : Option[int] = some(80) ## max length of a line, including indentation
    directivesEnd*  : DirectivesEndStyle = deIfNecessary ## whether to write '---' after tags
    schemaDirective*: SchemaDirectiveStyle = sdNone ## whether to write the schema of each document
    suppressAttrs*  : bool = false ## whether to suppress all attributes on nodes
    quoting*        : ScalarQuotingStyle = sqUnset ## how scalars are quoted
    condenseFlow*   : bool = true ## whether non-nested flow containers use a single line
    explicitKeys*   : bool = false ## whether mapping keys should always use '?'
    comments*       : CommentOptions ## whether and how `transform` keeps comments

  YamlPresenterJsonError* = object of ValueError
    ## Exception that may be raised by the YAML presenter when it is
    ## instructed to output JSON, but is unable to do so. This may occur if:
    ##
    ## - The given `YamlStream <#YamlStream>`_ contains a map which has any
    ##   non-scalar type as key.
    ## - Any float scalar bears a ``NaN`` or positive/negative infinity value

  YamlPresenterOutputError* = object of ValueError
    ## Exception that may be raised by the YAML presenter. This occurs if
    ## writing character data to the output stream raises any exception.
    ## The error that has occurred is available from ``parent``.

  DumperState = enum
    dBlockExplicitMapKey, dBlockImplicitMapKey, dBlockMapValue,
    dBlockInlineMap, dBlockSequenceItem, dFlowImplicitMapKey, dFlowMapValue,
    dFlowExplicitMapKey, dFlowSequenceItem, dFlowMapStart, dFlowSequenceStart

  DumperLevel = tuple
    state: DumperState
    indentation: int
    singleLine: bool
    wroteAnything: bool

  Context = object
    target: Stream
    options: PresentationOptions
    handles: seq[tuple[handle, uriPrefix: string]]
    levels: seq[DumperLevel]
    needsWhitespace: int
    wroteDirectivesEnd: bool
    lastImplicitKeyLen: int
    cached: DeQue[Event]
    # comments, see `CommentOptions`. While ``commenting``, ``target``
    # buffers the current line, which `newline` writes to ``output`` along
    # with the comments before it, at its end and after it.
    commenting: bool
    output: Stream
    attached: seq[EventComments] # by index of the event in the stream
    eventIndex: int
    before, trailing: seq[KeptComment]
    # with the range of indentations that keep a comment where it is
    after: seq[tuple[comment: KeptComment, indentation, below: int]]
    # the indentation of the collection the previous event ended, if any
    lastClosed: int
    # a flow scalar is being written / the next line is in the body of a
    # block scalar
    inScalar, blockScalar: bool
    # the current line continues a scalar / is in the body of a block scalar
    continuation, bodyLine: bool
    lastWasBody, wroteLine, blankPending: bool

  KeptComment = object
    content: string
    column: int # in the input
    blankBefore, blankAfter: bool # the line before / after it is blank

  EventComments = object
    before, trailing, after: seq[KeptComment]

  ItemKind = enum
    ikCompactScalar, ikMultilineFlowScalar, ikBlockScalar, ikCollection

  MapParseState = enum
    mpInitial, mpKey, mpValue, mpNeedBlock

proc level(ctx: var Context): var DumperLevel = ctx.levels[^1]

proc level(ctx: Context): DumperLevel = ctx.levels[^1]

proc state(ctx: Context): DumperState = ctx.level.state

proc `state=`(ctx: var Context, v: DumperState) =
  ctx.level.state = v

proc isFlow(state: DumperState): bool =
  result = state in [
    dFlowImplicitMapKey, dFlowMapValue,
    dFlowExplicitMapKey, dFlowSequenceItem,
    dFlowMapStart, dFlowSequenceStart
  ]

proc indentation(ctx: Context): int =
  result = if ctx.levels.len == 0: 0 else: ctx.level.indentation

proc searchHandle(ctx: Context, tag: string):
    tuple[handle: string, len: int] {.raises: [].} =
  ## search in the registered tag handles for one whose prefix matches the start
  ## of the given tag. If multiple registered handles match, the one with the
  ## longest prefix is returned. If no registered handle matches, ("", 0) is
  ## returned.
  result.len = 0
  for item in ctx.handles:
    if item.uriPrefix.len > result.len:
      if tag.startsWith(item.uriPrefix):
        result.len = item.uriPrefix.len
        result.handle = item.handle

proc inspect(
  scalar      : string,
  indentation : int,
  words, lines: var seq[tuple[start, finish: int]],
  multiLine   : var bool,
  lineLength  : Option[int],
  inFlow      : bool,
  proposed    : ScalarStyle,
): ScalarStyle {.raises: [].} =
  ## inspects the given scalar and returns the style in which it should be
  ## presented. fills information in words, lines and multiLine that can be
  ## used later for presenting it:
  ##
  ##  * words will contain substring boundaries of parts of the string that
  ##    are separated by exactly one, not more, spaces. occurrences of multiple
  ##    spaces will become part of a single word. This is used for folded block
  ##    scalars, which can only break at single spaces.
  ##  * lines will contain substring boundaries of parts of the string that
  ##    can be emitted as lines within a literal block scalar.
  ##  * multiLine is set to true for double quoted scalars iff the scalar will
  ##    be written on multiple lines. important when using the scalar as block
  ##    mapping key. Will not be set for other styles since single quoted and
  ##    plain scalars always occupy only one line, and block scalars always
  ##    occupy multiple.
  ##
  ## The proposed style will take precedence over other decisions and will be
  ## returned if possible. a proposed folded style will decay into a literal
  ## style if folded style is not possible but literal is. Otherwise, if the
  ## proposed style is not a valid style, it is ignored.
  ##
  ## A proposed style of ssAny is not valid and is therefore always ignored.
  ## This proc will never emit ssAny.
  ##
  ## This inspector will not always allow a style that would be possible.
  ## For example, the presenter is currently unable to emit multi-line plain
  ## scalars, therefore multi-line string will never yield ssPlain. Similarly,
  ## ssFolded will never be returned if there are more-indented lines.
  lines.setLen(0)
  words.setLen(0)
  var
    inLine = false
    inWord = false
    multipleSpaces = true
    curWord, curLine: tuple[start, finish: int]
    canUseFolded = not inFlow
    canUseLiteral = not inFlow
    canUsePlain = scalar.len > 0 and
        scalar[0] notin {'@', '`', '|', '>', '&', '*', '!', ' ', '\t'} and
        (not lineLength.isSome or scalar.len <= indentation + lineLength.get())
    canUseSingleQuoted = true
    curDqLen = indentation + 2
  for i, c in scalar:
    case c
    of ' ':
      if inWord:
        if not multipleSpaces:
          curWord.finish = i - 1
          inWord = false
      else:
        multipleSpaces = true
        inWord = true
        if not inLine:
          inLine = true
          curLine.start = i
          # space at beginning of line will preserve previous and next
          # line break. that is currently too complex to handle.
          canUseFolded = false
      inc(curDqLen)
    of '\l':
      canUsePlain = false     # we don't use multiline plain scalars
      canUseSingleQuoted = false
      if inWord:
        curWord.finish = i - 1
        if lineLength.isSome and
            curWord.finish - curWord.start + 1 > lineLength.get() - indentation:
          multiLine = lineLength.isSome and curDqLen > lineLength.get()
          return ssDoubleQuoted
        words.add(curWord)
        inWord = false
      if inLine and scalar[i - 1] in ['\t', ' ']:
        # cannot use block scalars if line ends with space
        canUseLiteral = false
        canUseFolded = false
      curWord.start = i + 1
      multipleSpaces = true
      if not inLine: curLine.start = i
      inLine = false
      curLine.finish = i - 1
      if lineLength.isSome and
         curLine.finish - curLine.start + 1 > lineLength.get() - indentation:
        canUseLiteral = false
      lines.add(curLine)
      inc(curDqLen, 2)
    else:
      inc(curDqLen, if c in {'"', '\\', '\t', '\''}: 2 else: 1)

      if c in {'{', '}', '[', ']', ',', '#', '-', ':', '?', '%', '"', '\''}:
        canUsePlain = false
      elif c.ord < 32:
        canUsePlain = false
        canUseSingleQuoted = false
      if not inLine:
        curLine.start = i
        inLine = true
        # like a space, a tab at the beginning of a line makes it
        # more indented
        if c == '\t': canUseFolded = false
      if not inWord:
        if not multipleSpaces:
          if lineLength.isSome and
              curWord.finish - curWord.start + 1 > lineLength.get() - indentation:
            multiLine = lineLength.isSome and curDqLen > lineLength.get()
            return ssDoubleQuoted
          words.add(curWord)
        curWord.start = i
        inWord = true
        multipleSpaces = false
  if inWord:
    curWord.finish = scalar.len - 1
    if lineLength.isSome and
        curWord.finish - curWord.start + 1 > lineLength.get() - indentation:
      multiLine = lineLength.isSome and curDqLen > lineLength.get()
      return ssDoubleQuoted
    words.add(curWord)
  if inLine:
    if scalar[^1] in ['\t', ' ']:
      canUseLiteral = false
      canUseFolded = false
      canUsePlain = false
    curLine.finish = scalar.len - 1
    if lineLength.isSome and
       curLine.finish - curLine.start + 1 > lineLength.get() - indentation:
      canUseLiteral = false
    lines.add(curLine)
  if lineLength.isSome and curDqLen > lineLength.get():
    canUseSingleQuoted = false

  case proposed
  of ssLiteral:
    if canUseLiteral: return ssLiteral
  of ssFolded:
    if canUseFolded: return ssFolded
    elif canUseLiteral: return ssLiteral
  of ssPlain:
    if canUsePlain: return ssPlain
  of ssSingleQuoted:
    if canUseSingleQuoted: return ssSingleQuoted
  of ssDoubleQuoted:
    multiLine = lineLength.isSome and curDqLen > lineLength.get()
    return ssDoubleQuoted
  else: discard

  if lineLength.isNone or scalar.len <= lineLength.get() - indentation:
    result = if canUsePlain: ssPlain else: ssDoubleQuoted
  elif canUseLiteral: result = ssLiteral
  elif canUseFolded: result = ssFolded
  elif canUsePlain: result = ssPlain
  else: result = ssDoubleQuoted
  if result == ssDoubleQuoted:
    multiLine = lineLength.isSome and curDqLen > lineLength.get()

proc append(ctx: var Context, val: string | char) {.inline.} =
  if ctx.needsWhitespace > 0:
    ctx.target.write(repeat(' ', ctx.needsWhitespace))
    ctx.needsWhitespace = 0
  ctx.target.write(val)
  if ctx.levels.len > 0: ctx.level.wroteAnything = true

proc whitespace(ctx: var Context, single: bool = false) {.inline.} =
  if single or ctx.options.indentationStep == 1: ctx.needsWhitespace = 1
  else: ctx.needsWhitespace = ctx.options.indentationStep - 1

proc lineBreak(ctx: Context): string =
  case ctx.options.newlines
  of nlCRLF: "\c\l"
  of nlLF: "\l"
  else: "\n"

proc commentIndentation(ctx: Context, c: KeptComment, node: int,
    ending = false, below = int.high): int =
  ## The indentation of a comment line, of a comment before a node at
  ## ``node`` or, if ``ending``, at the end of a collection at ``node``.
  ## Comments are attached by their indentation, so with ``ciSource``, it
  ## is kept within the indentations that attach it to the same node again:
  ## at most ``node`` before a node, and between ``node`` and ``below`` (the
  ## indentation of a collection that ends along with it, exclusive) at the
  ## end of a collection.
  case ctx.options.comments.indentation
  of ciNode: node
  of ciSource:
    if not ending: min(c.column - 1, node)
    # more would make it content of the block scalar before it
    elif ctx.lastWasBody: node
    else: max(node, min(c.column - 1, below - 1))

proc writeOutput(ctx: var Context, line: string, blankBefore = false,
    blankAfter = false) =
  ## Writes a line to ``output``, with a blank line before it if one is
  ## pending. Blank lines next to comments are only written between lines.
  if not ctx.options.comments.blankLines: ctx.blankPending = false
  elif blankBefore and ctx.wroteLine: ctx.blankPending = true
  if ctx.blankPending: ctx.output.write(ctx.lineBreak)
  ctx.output.write(line)
  ctx.output.write(ctx.lineBreak)
  ctx.wroteLine = true
  ctx.blankPending = blankAfter

proc writeComment(ctx: var Context, c: KeptComment, indentation: int) =
  ctx.writeOutput(repeat(' ', indentation) & '#' & c.content, c.blankBefore,
      c.blankAfter)
  ctx.lastWasBody = false

proc ownLine(c: KeptComment): KeptComment =
  ## A comment that followed content, to write on a line of its own.
  result = c
  result.column = 1

proc flushLine(ctx: var Context, final = false) =
  ## Writes the current line and the comments around it. A line inside a
  ## scalar takes no comments; they wait for the next line that can.
  let buffer = StringStream(ctx.target)
  let text = buffer.data
  buffer.data.setLen(0)
  buffer.setPosition(0)
  var indentation = 0
  while indentation < text.len and text[indentation] == ' ': inc(indentation)
  let
    hasContent = indentation < text.len
    insideScalar = ctx.inScalar or ctx.blockScalar
  if not ctx.continuation and (hasContent or final):
    for c in ctx.before: ctx.writeComment(c, ctx.commentIndentation(c, indentation))
    ctx.before.setLen(0)
  var line = text
  # the header line of a block scalar takes a comment, its body does not
  if hasContent and not ctx.inScalar and not ctx.bodyLine and
      ctx.trailing.len > 0:
    # without a space before it, a # does not start a comment
    line.add(repeat(' ', max(1, ctx.options.comments.gap)) & '#' &
        ctx.trailing[0].content)
    for i in countdown(ctx.trailing.high, 1):
      ctx.after.insert((ctx.trailing[i].ownLine, indentation, int.high), 0)
    ctx.trailing.setLen(0)
  if not final or hasContent:
    if hasContent or ctx.continuation:
      # an empty line inside a scalar is content
      ctx.writeOutput(line)
    else:
      ctx.output.write(ctx.lineBreak)
      ctx.blankPending = false
    ctx.lastWasBody = ctx.bodyLine
  if final:
    for c in ctx.trailing: ctx.after.add((c.ownLine, 0, int.high))
    ctx.trailing.setLen(0)
  if not insideScalar:
    for (c, i, below) in ctx.after:
      ctx.writeComment(c, ctx.commentIndentation(c, i, true, below))
    ctx.after.setLen(0)
  ctx.continuation = insideScalar
  ctx.bodyLine = ctx.blockScalar

proc newline(ctx: var Context) {.inline.} =
  if ctx.commenting: ctx.flushLine()
  else: ctx.target.write(ctx.lineBreak)
  ctx.needsWhitespace = 0
  if ctx.levels.len > 0: ctx.level.wroteAnything = true

proc writeDoubleQuoted(
  ctx   : var Context,
  scalar: string,
): int {.raises: [YamlPresenterOutputError].} =
  let indentation = ctx.indentation + ctx.options.indentationStep
  var curPos = indentation
  let t = ctx.target
  try:
    result = 2
    ctx.append('"')
    curPos.inc()
    ctx.inScalar = true
    for i, c in scalar:
      var nextLength = 1
      case c
      of '"', '\l', '\t', '\\':
        nextLength = 2
      else:
        if ord(c) < 32:
          nextLength = 4

      if ctx.options.maxLineLength.isSome and
         (curPos + nextLength >= ctx.options.maxLineLength.get() or
          curPos + nextLength == ctx.options.maxLineLength.get() - 1 and i == scalar.len - 2):
        t.write('\\')
        ctx.newline()
        t.write(repeat(' ', indentation))
        result.inc(2 + indentation)
        curPos = indentation
        if c == ' ':
          t.write('\\')
          curPos.inc()
          result.inc()
      else:
        curPos.inc(nextLength)
        result.inc(nextLength)
      case c
      of '"': t.write("\\\"")
      of '\l': t.write("\\n")
      of '\t': t.write("\\t")
      of '\\': t.write("\\\\")
      else:
        if ord(c) < 32: t.write("\\x" & toHex(ord(c), 2))
        else: t.write(c)
    t.write('"')
    ctx.inScalar = false
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = ce
    raise e

proc writeDoubleQuotedJson(
  ctx   : var Context,
  scalar: string,
): int {.raises: [YamlPresenterOutputError].} =
  let t = ctx.target
  try:
    ctx.append('"')
    result = 2
    for c in scalar:
      case c
      of '"':
        t.write("\\\"")
        result.inc(2)
      of '\\':
        t.write("\\\\")
        result.inc(2)
      of '\l':
        t.write("\\n")
        result.inc(2)
      of '\t':
        t.write("\\t")
        result.inc(2)
      of '\f':
        t.write("\\f")
        result.inc(2)
      of '\b':
        t.write("\\b")
        result.inc(2)
      else:
        if ord(c) < 32:
          t.write("\\u" & toHex(ord(c), 4))
          result.inc(4)
        else:
          t.write(c)
          result.inc()
    t.write('"')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeSingleQuoted(
  ctx   : var Context,
  scalar: string,
): int {.raises: [YamlPresenterOutputError].} =
  let t = ctx.target
  try:
    # writing \39 instead of \' because my syntax highlighter is dumb
    ctx.append('\39')
    result = 2
    for c in scalar:
      if c == '\39':
        t.write("''")
        result.inc(2)
      else:
        t.write(c)
        result.inc()
    ctx.append('\39')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeLiteral(
  ctx   : var Context,
  scalar: string,
  lines : seq[tuple[start, finish: int]],
) {.raises: [YamlPresenterOutputError].} =
  var indentation = ctx.indentation
  if ctx.levels.len > 0: inc(indentation, ctx.options.indentationStep)
  let t = ctx.target
  try:
    ctx.append('|')
    if scalar[^1] != '\l': t.write('-')
    if scalar[0] in [' ', '\t']: t.write($ctx.options.indentationStep)
    ctx.blockScalar = true
    for line in lines:
      ctx.newline()
      t.write(repeat(' ', indentation))
      if line.finish >= line.start:
        t.write(scalar[line.start .. line.finish])
    ctx.blockScalar = false
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = ce
    raise e

proc writeFolded(
  ctx   : var Context,
  scalar: string,
  words : seq[tuple[start, finish: int]],
) {.raises: [YamlPresenterOutputError].} =
  let t = ctx.target
  let indentation = ctx.indentation + ctx.options.indentationStep
  let lineLength = (
    if ctx.options.maxLineLength.isSome:
      ctx.options.maxLineLength.get() else: 1024)
  try:
    ctx.append('>')
    if scalar[^1] != '\l': t.write('-')
    if scalar[0] in [' ', '\t']: t.write($ctx.options.indentationStep)
    var curPos = lineLength
    ctx.blockScalar = true
    for word in words:
      if word.start > 0 and scalar[word.start - 1] == '\l':
        ctx.newline()
        ctx.newline()
        t.write(repeat(' ', indentation))
        curPos = indentation
      elif curPos + (word.finish - word.start + 1) > lineLength:
        ctx.newline()
        t.write(repeat(' ', indentation))
        curPos = indentation
      else:
        t.write(' ')
        curPos.inc()
      t.write(scalar[word.start .. word.finish])
      curPos += word.finish - word.start + 1
    ctx.blockScalar = false
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = ce
    raise e

template safeWrite(ctx: var Context, s: string or char) =
  try: ctx.append(s)
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

template safeNewline(c: var Context) =
  try: ctx.newline()
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

proc startItem(
  ctx : var Context,
  kind: ItemKind,
) {.raises: [YamlPresenterOutputError].} =
  if ctx.levels.len == 0:
    if kind == ikBlockScalar:
      if not ctx.wroteDirectivesEnd:
        ctx.wroteDirectivesEnd = true
        ctx.safeWrite("---")
        ctx.whitespace(true)
    return
  let t = ctx.target
  try:
    case ctx.state
    of dBlockMapValue:
      if ctx.level.wroteAnything or ctx.options.indentationStep < 2:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      else:
        ctx.level.wroteAnything = true
      if kind != ikCompactScalar or ctx.options.explicitKeys:
        ctx.append('?')
        ctx.whitespace()
        ctx.state = dBlockExplicitMapKey
      else: ctx.state = dBlockImplicitMapKey
    of dBlockInlineMap:
      if kind != ikCompactScalar or ctx.options.explicitKeys:
        ctx.append('?')
        ctx.whitespace()
        ctx.state = dBlockExplicitMapKey
      else: ctx.state = dBlockImplicitMapKey
    of dBlockExplicitMapKey:
      ctx.newline()
      t.write(repeat(' ', ctx.indentation))
      t.write(':')
      ctx.whitespace()
      ctx.state = dBlockMapValue
    of dBlockImplicitMapKey:
      ctx.append(':')
      ctx.whitespace(true)
      ctx.state = dBlockMapValue
    of dFlowExplicitMapKey:
      if ctx.options.newlines != nlNone:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      ctx.append(':')
      ctx.whitespace()
      ctx.state = dFlowMapValue
    of dFlowMapValue:
      ctx.append(',')
      ctx.whitespace(true)
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      if kind == ikCompactScalar and not ctx.options.explicitKeys:
        ctx.state = dFlowImplicitMapKey
      else:
        t.write('?')
        ctx.whitespace()
        ctx.state = dFlowExplicitMapKey
    of dFlowMapStart:
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      if kind == ikCompactScalar and not ctx.options.explicitKeys:
        ctx.state = dFlowImplicitMapKey
      else:
        ctx.append('?')
        ctx.whitespace()
        ctx.state = dFlowExplicitMapKey
    of dFlowImplicitMapKey:
      ctx.append(':')
      ctx.whitespace(true)
      ctx.state = dFlowMapValue
    of dBlockSequenceItem:
      if ctx.level.wroteAnything or ctx.options.indentationStep < 2:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      else:
        ctx.level.wroteAnything = true
      ctx.append('-')
      ctx.whitespace()
    of dFlowSequenceStart:
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      ctx.state = dFlowSequenceItem
    of dFlowSequenceItem:
      ctx.append(',')
      ctx.whitespace(true)
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

proc writeTagAndAnchor(
  ctx  : var Context,
  props: Properties,
): bool {.raises: [YamlPresenterOutputError].} =
  if ctx.options.suppressAttrs: return false
  let t = ctx.target
  result = false
  try:
    if props.tag notin [yTagQuestionMark, yTagExclamationMark]:
      let tagUri = $props.tag
      let (handle, length) = ctx.searchHandle(tagUri)
      if length > 0:
        ctx.append(handle)
        t.write(tagUri[length..tagUri.high])
        ctx.whitespace(true)
      else:
        ctx.append("!<")
        t.write(tagUri)
        t.write('>')
        ctx.whitespace(true)
      result = true
    if props.anchor != yAnchorNone:
      ctx.append("&")
      t.write($props.anchor)
      ctx.whitespace(true)
      result = true
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

proc takeBefore(ctx: var Context, trailing = true) =
  ## Takes the comments to write before the line of the current event and
  ## at its end. Called once the event's line has been started.
  if ctx.commenting:
    ctx.before.add(ctx.attached[ctx.eventIndex].before)
    if trailing: ctx.trailing.add(ctx.attached[ctx.eventIndex].trailing)

proc takeTrailing(ctx: var Context) =
  if ctx.commenting: ctx.trailing.add(ctx.attached[ctx.eventIndex].trailing)

proc takeAfter(ctx: var Context, indentation: int, trailing = true) =
  ## Takes the comments that end the collection or document the current
  ## event ends, to write at ``indentation`` after the current line.
  if ctx.commenting:
    if trailing: ctx.trailing.add(ctx.attached[ctx.eventIndex].trailing)
    for c in ctx.attached[ctx.eventIndex].after:
      ctx.after.add((c, indentation, ctx.lastClosed))

proc endIndentation(ctx: Context, level: DumperLevel): int =
  ## The indentation of comments that end the collection of ``level``.
  if level.state.isFlow: max(0, level.indentation - ctx.options.indentationStep)
  else: level.indentation

proc nextItem(
  c: var Deque,
  s: YamlStream,
): Event {.raises: [YamlStreamError].} =
  if c.len > 0:
    try: result = c.popFirst
    except IndexDefect: internalError("Unexpected IndexError")
  else:
    result = s.next()

const maxSingleLineLookahead = 65536
  ## characters of a collection the presenter looks at to decide whether it
  ## fits into a single line; a longer one is written in block style

proc checkSingleLine(
  ctx    : var Context,
  s      : YamlStream,
  item   : Event,
  mapping: bool
): (bool, MapParseState)  =
  let style = if mapping: item.mapStyle else: item.seqStyle
  if ctx.options.newlines == nlNone: return (true, mpInitial)
  if not ctx.options.condenseFlow: return (false, mpNeedBlock)
  if (ctx.levels.len > 0 and ctx.state.isFlow) or style == csFlow or
       (style == csAny and ctx.options.containers != cBlock):
    result[1] = mpInitial
    var
      length = 0
      tooLong = false
    while not mapping or result[1] != mpNeedBlock:
      let next = s.next()
      ctx.cached.addLast(next)
      case next.kind
      of yamlScalar:
        length += 2 + next.scalarContent.len
        if next.scalarStyle in [ssFolded, ssLiteral]:
          length = high(int)
          result[1] = mpNeedBlock
          break
        case result[1]
        of mpInitial: result[1] = mpKey
        of mpKey: result[1] = mpValue
        else: result[1] = mpNeedBlock
      of yamlAlias:
        length += 6
        case result[1]
        of mpInitial: result[1] = mpKey
        of mpKey: result[1] = mpValue
        else: result[1] = mpNeedBlock
      of yamlEndSeq, yamlEndMap: break
      else:
        length = high(int)
        result[1] = mpNeedBlock
        break
      # The events looked at are held until written; a collection too long
      # for a line is not looked at further. A sequence is too long once it
      # exceeds the line; a mapping needs its parse state, so it is looked
      # at up to maxSingleLineLookahead characters, then written in block
      # style.
      if length > maxSingleLineLookahead:
        tooLong = true
        result[1] = mpNeedBlock
        break
      if not mapping and ctx.options.maxLineLength.isSome and
          length >= ctx.options.maxLineLength.get() - ctx.indentation - 2:
        tooLong = true
        break
    result[0] = not tooLong and (not mapping or result[1] != mpNeedBlock) and
      (ctx.options.maxLineLength.isNone or
      length < ctx.options.maxLineLength.get() - ctx.indentation - 2)
  else: result = (false, mpNeedBlock)

proc doPresent(
  ctx: var Context,
  s  : YamlStream,
) {.raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlStreamError
].} =
  var unclosedDoc = false
  ctx.cached = initDeQue[Event]()
  ctx.wroteDirectivesEnd = false
  ctx.eventIndex = -1
  while true:
    let item = nextItem(ctx.cached, s)
    inc(ctx.eventIndex)
    if item.kind notin {yamlEndMap, yamlEndSeq}: ctx.lastClosed = int.high
    case item.kind
    of yamlStartStream: discard
    of yamlEndStream:
      ctx.takeAfter(0)
      break
    of yamlStartDoc:
      if unclosedDoc:
        ctx.safeWrite("...")
        ctx.safeNewline()
      # the directives come before the line of the document start
      ctx.takeBefore(trailing = false)
      ctx.wroteDirectivesEnd =
        item.explicitDirectivesEnd or ctx.options.directivesEnd == deAlways or (
        ctx.options.directivesEnd != deNever and not s.peek().emptyProperties())

      if ctx.options.directivesEnd != deNever:
        resetHandles(ctx.handles)
        for v in item.handles:
          discard registerHandle(ctx.handles, v.handle, v.uriPrefix)

        try:
          case ctx.options.outputVersion
          of ov1_2:
              ctx.target.write("%YAML 1.2")
              ctx.newline()
              ctx.wroteDirectivesEnd = true
          of ov1_1:
              ctx.target.write("%YAML 1.1")
              ctx.newline()
              ctx.wroteDirectivesEnd = true
          of ovDocument:
            if item.version.len > 0:
              ctx.target.write("%YAML " & item.version)
              ctx.newline()
              ctx.wroteDirectivesEnd = true
          of ovNone: discard
          let schemas = item.directives.schemas
          if schemas.len > 0:
            case ctx.options.schemaDirective
            of sdNone: discard
            of sdModeline:
              if schemas.len == 1:
                ctx.target.write("# yaml-language-server: $schema=" &
                    schemas[0])
                ctx.newline()
              else:
                ctx.target.write("%SCHEMA " & schemas.join(" "))
                ctx.newline()
                ctx.wroteDirectivesEnd = true
            of sdDirective:
              ctx.target.write("%SCHEMA " & schemas.join(" "))
              ctx.newline()
              ctx.wroteDirectivesEnd = true
          for v in ctx.handles:
            if v.handle == "!":
              if v.uriPrefix != "!":
                ctx.target.write("%TAG ! " & v.uriPrefix)
                ctx.newline()
                ctx.wroteDirectivesEnd = true
            elif v.handle == "!!":
              if v.uriPrefix != yamlTagRepositoryPrefix:
                ctx.target.write("%TAG !! " & v.uriPrefix)
                ctx.newline()
                ctx.wroteDirectivesEnd = true
            else:
              ctx.target.write("%TAG " & v.handle & ' ' & v.uriPrefix)
              ctx.newline()
              ctx.wroteDirectivesEnd = true
        except CatchableError as ce:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = ce
          raise e
      ctx.takeTrailing()
      if ctx.wroteDirectivesEnd:
        ctx.safeWrite("---")
        ctx.whitespace(true)
    of yamlScalar:
      var
        words, lines: seq[tuple[start, finish: int]]
        scalarStyle = ssAny
        multiLine = false
        needsNextLine = false
      if ctx.options.quoting in [sqUnset, sqDouble]:
        words = @[]
        lines = @[]
        if ctx.levels.len > 0 and ctx.state == dBlockImplicitMapKey:
          if ctx.commenting and ctx.attached[ctx.eventIndex].before.len > 0:
            # the comments before a value go between it and its key
            needsNextLine = true
          elif ctx.options.maxLineLength.isNone or
              ctx.indentation + ctx.options.indentationStep + ctx.lastImplicitKeyLen + 4 <
              ctx.options.maxLineLength.get():
            scalarStyle = item.scalarContent.inspect(
              ctx.indentation + ctx.options.indentationStep + ctx.lastImplicitKeyLen + 2,
              words, lines, multiLine,
              ctx.options.maxLineLength, ctx.levels.len > 0 and ctx.state.isFlow, item.scalarStyle)
            case scalarStyle
            of ssPlain, ssSingleQuoted: discard
            of ssDoubleQuoted:
              if multiLine:
                multiLine = false
                scalarStyle = ssAny
                needsNextLine = true
            else:
              scalarStyle = ssAny
              needsNextLine = true
          else: needsNextLine = true
        if scalarStyle == ssAny:
          scalarStyle = item.scalarContent.inspect(
            ctx.indentation + ctx.options.indentationStep, words, lines, multiLine,
            ctx.options.maxLineLength, ctx.levels.len > 0 and ctx.state.isFlow, item.scalarStyle)
      ctx.startItem(case scalarStyle
        of ssLiteral, ssFolded: ikBlockScalar
        of ssDoubleQuoted:
          if multiLine: ikMultilineFlowScalar else: ikCompactScalar
        else: ikCompactScalar)
      let nextLine = ctx.levels.len > 0 and needsNextLine and
          scalarStyle in [ssDoubleQuoted, ssSingleQuoted, ssPlain]
      if not nextLine: ctx.takeBefore()
      discard ctx.writeTagAndAnchor(item.scalarProperties)
      if ctx.levels.len == 0:
        if ctx.wroteDirectivesEnd and scalarStyle notin [ssLiteral, ssFolded]: ctx.safeNewline()
      elif nextLine:
        ctx.safeNewline()
        ctx.safeWrite(repeat(' ', ctx.indentation + ctx.options.indentationStep))
        ctx.takeBefore()
      case ctx.options.quoting
      of sqJson:
        var hint = yTypeUnknown
        # keys are always strings in JSON; values and items may be keywords
        # and numbers
        if ctx.levels.len == 0 or ctx.state notin {dBlockExplicitMapKey,
            dBlockImplicitMapKey, dFlowImplicitMapKey, dFlowExplicitMapKey}:
          hint = guessType(item.scalarContent)
        let tag = item.scalarProperties.tag
        if tag in [yTagQuestionMark, yTagBoolean] and
            hint in {yTypeBoolTrue, yTypeBoolFalse}:
          ctx.safeWrite(if hint == yTypeBoolTrue: "true" else: "false")
        elif tag in [yTagQuestionMark, yTagNull] and
            hint == yTypeNull:
          ctx.safeWrite("null")
        elif tag in [yTagQuestionMark, yTagInteger,
            yTagNimInt8, yTagNimInt16, yTagNimInt32, yTagNimInt64,
            yTagNimUInt8, yTagNimUInt16, yTagNimUInt32, yTagNimUInt64] and
            hint == yTypeInteger:
          ctx.safeWrite(item.scalarContent)
        elif tag in [yTagQuestionMark, yTagFloat, yTagNimFloat32,
            yTagNimFloat64] and hint in {yTypeFloatInf, yTypeFloatNaN}:
          raise newException(YamlPresenterJsonError,
              "Infinity and not-a-number values cannot be presented as JSON!")
        elif tag in [yTagQuestionMark, yTagFloat] and
            hint == yTypeFloat:
          ctx.safeWrite(item.scalarContent)
        else:
          ctx.lastImplicitKeyLen = ctx.writeDoubleQuotedJson(item.scalarContent)
      of sqDouble:
        ctx.lastImplicitKeyLen = ctx.writeDoubleQuoted(item.scalarContent)
      else:
        case scalarStyle
        of ssLiteral: ctx.writeLiteral(item.scalarContent, lines)
        of ssFolded: ctx.writeFolded(item.scalarContent, words)
        of ssPlain:
          ctx.safeWrite(item.scalarContent)
          ctx.lastImplicitKeyLen = item.scalarContent.len
        of ssSingleQuoted:
          ctx.lastImplicitKeyLen = ctx.writeSingleQuoted(item.scalarContent)
        of ssDoubleQuoted:
          ctx.lastImplicitKeyLen = ctx.writeDoubleQuoted(item.scalarContent)
        else: discard # ssAny, can never happen
    of yamlAlias:
      if ctx.options.quoting == sqJson:
        raise newException(YamlPresenterJsonError,
                           "Alias not allowed in JSON output")
      yAssert ctx.levels.len > 0
      ctx.startItem(ikCompactScalar)
      ctx.takeBefore()
      try:
        ctx.append('*')
        ctx.target.write($item.aliasTarget)
      except CatchableError as ce:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = ce
        raise e
    of yamlStartSeq:
      let (singleLine, _) = ctx.checkSingleLine(s, item, false)
      var nextState: DumperState
      if (ctx.levels.len > 0 and ctx.state.isFlow) or item.seqStyle == csFlow:
        nextState = dFlowSequenceStart
      elif item.seqStyle == csBlock:
        let next = s.peek()
        nextState = if next.kind == yamlEndSeq: dFlowSequenceStart else: dBlockSequenceItem
      else:
        case ctx.options.containers
        of cMixed:
          nextState = if singleLine: dFlowSequenceStart else: dBlockSequenceItem
        of cFlow: nextState = dFlowSequenceStart
        of cBlock:
          let next = s.peek()
          nextState = if next.kind == yamlEndSeq: dFlowSequenceStart else: dBlockSequenceItem

      var indentation = 0
      var wroteAnything = false
      if ctx.levels.len > 0: wroteAnything = ctx.state == dBlockImplicitMapKey

      if ctx.levels.len == 0:
        if nextState == dFlowSequenceStart:
          indentation = ctx.options.indentationStep
      else:
        ctx.startItem(ikCollection)
        indentation = ctx.indentation + ctx.options.indentationStep
        if nextState.isFlow and not ctx.state.isFlow:
          inc(indentation, ctx.options.indentationStep)
      ctx.takeBefore()

      let wroteAttrs = ctx.writeTagAndAnchor(item.seqProperties)
      if wroteAttrs or (ctx.wroteDirectivesEnd and ctx.levels.len == 0):
        wroteAnything = true

      if nextState == dFlowSequenceStart:
        if ctx.levels.len == 0:
          if wroteAttrs or ctx.wroteDirectivesEnd: ctx.safeNewline()
        ctx.safeWrite('[')

      ctx.levels.add (nextState, indentation, singleLine, wroteAnything)
    of yamlStartMap:
      let (singleLine, mps) = ctx.checkSingleLine(s, item, true)
      var nextState: DumperState
      if (ctx.levels.len > 0 and ctx.state.isFlow) or item.mapStyle == csFlow:
        nextState = dFlowMapStart
      elif item.mapStyle == csBlock:
        let next = s.peek()
        nextState = if next.kind == yamlEndMap: dFlowMapStart else: dBlockMapValue
      else:
        case ctx.options.containers
        of cMixed:
          if mps == mpNeedBlock:
            nextState = dBlockMapValue
          elif ctx.levels.len == 0 or ctx.state == dBlockSequenceItem and item.emptyProperties:
            nextState = dBlockInlineMap
          else:
            nextState = dFlowMapStart
        of cFlow: nextState = dFlowMapStart
        of cBlock:
          let next = s.peek()
          if next.kind == yamlEndMap: nextState = dFlowMapStart
          else: nextState = dBlockMapValue

      var indentation = 0
      var wroteAnything = false
      if ctx.levels.len > 0: wroteAnything = ctx.state == dBlockImplicitMapKey

      if ctx.levels.len == 0:
        if nextState == dFlowMapStart:
          indentation = ctx.options.indentationStep
      else:
        ctx.startItem(ikCollection)
        indentation = ctx.indentation + ctx.options.indentationStep
        if nextState.isFlow and not ctx.state.isFlow:
          inc(indentation, ctx.options.indentationStep)
      ctx.takeBefore()

      let wroteAttrs = ctx.writeTagAndAnchor(item.properties)
      if wroteAttrs or (ctx.wroteDirectivesEnd and ctx.levels.len == 0):
        wroteAnything = true

      if nextState == dFlowMapStart:
        if ctx.levels.len == 0:
          if wroteAttrs or ctx.wroteDirectivesEnd: ctx.safeNewline()
        ctx.safeWrite('{')

      ctx.levels.add (nextState, indentation, singleLine, wroteAnything)
    of yamlEndSeq:
      yAssert ctx.levels.len > 0
      let level = ctx.levels.pop()
      case level.state
      of dFlowSequenceItem:
        try:
          if not level.singleLine:
            ctx.newline()
            ctx.target.write(repeat(' ', level.indentation - ctx.options.indentationStep))
          ctx.target.write(']')
        except CatchableError as ce:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = ce
          raise e
      of dFlowSequenceStart: ctx.safeWrite(']')
      of dBlockSequenceItem: discard
      else: internalError("Invalid popped level")
      ctx.takeAfter(ctx.endIndentation(level))
      ctx.lastClosed = ctx.endIndentation(level)
    of yamlEndMap:
      yAssert ctx.levels.len > 0
      let level = ctx.levels.pop()
      case level.state
      of dFlowMapValue:
        try:
          if not level.singleLine:
            ctx.safeNewline()
            ctx.target.write(repeat(' ', level.indentation - ctx.options.indentationStep))
          ctx.append('}')
        except CatchableError as ce:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = ce
          raise e
      of dFlowMapStart: ctx.safeWrite('}')
      of dBlockMapValue, dBlockInlineMap: discard
      else: internalError("Invalid level: " & $level)
      ctx.takeAfter(ctx.endIndentation(level))
      ctx.lastClosed = ctx.endIndentation(level)
    of yamlEndDoc:
      ctx.takeAfter(0, trailing = false)
      ctx.safeNewline()
      if item.explicitDocumentEnd:
        ctx.safeWrite("...")
        ctx.takeTrailing()
        ctx.safeNewline()
      else:
        ctx.takeTrailing()
        unclosedDoc = true
  if ctx.commenting:
    try: ctx.flushLine(final = true)
    except CatchableError as ce:
      var e = newException(YamlPresenterOutputError, "")
      e.parent = ce
      raise e

proc present*(
  s      : YamlStream,
  target : Stream,
  options: PresentationOptions = PresentationOptions(),
) {.raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlStreamError
].} =
  ## Convert ``s`` to a YAML character stream and write it to ``target``.
  var c = Context(target: target, options: options)
  doPresent(c, s)

proc present*(
  s      : YamlStream,
  options: PresentationOptions = PresentationOptions(),
): string {.raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlStreamError
].} =
  ## Convert ``s`` to a YAML character stream and return it as string.

  var
    ss = newStringStream()
    c = Context(target: ss, options: options)
  doPresent(c, s)
  return ss.data

proc normalized*(event: Event, resolveToCoreYamlTags: bool): Event =
  ## ``event`` with its presentation style left to the presenter and, with
  ## ``resolveToCoreYamlTags``, its non-specific tag resolved.
  result = event
  case result.kind
  of yamlStartStream, yamlEndStream, yamlStartDoc, yamlEndDoc, yamlEndMap, yamlAlias, yamlEndSeq:
    discard
  of yamlStartMap:
    result.mapStyle = csAny
    if resolveToCoreYamlTags:
      if result.mapProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
        result.mapProperties.tag = yTagMapping
  of yamlStartSeq:
    result.seqStyle = csAny
    if resolveToCoreYamlTags:
      if result.seqProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
        result.seqProperties.tag = yTagSequence
  of yamlScalar:
    result.scalarStyle = ssAny
    if resolveToCoreYamlTags:
      if result.scalarProperties.tag == yTagQuestionMark:
        case guessType(result.scalarContent)
        of yTypeInteger: result.scalarProperties.tag = yTagInteger
        of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
          result.scalarProperties.tag = yTagFloat
        of yTypeBoolTrue, yTypeBoolFalse: result.scalarProperties.tag = yTagBoolean
        of yTypeNull: result.scalarProperties.tag = yTagNull
        of yTypeTimestamp: result.scalarProperties.tag = yTagTimestamp
        of yTypeUnknown: result.scalarProperties.tag = yTagString
      elif result.scalarProperties.tag == yTagExclamationMark:
        result.scalarProperties.tag = yTagString

# Comments are attached to the events of their input by position:
#
# - A comment after content on its line goes with the last event that starts
#   (or, for a multi-line flow scalar, ends) on that line, and is written at
#   the end of the line of that event. On a line without an event, like that
#   of a directive, it is treated like a comment on a line of its own.
# - A comment on a line of its own ends the innermost collection that closes
#   after it and that it is indented into, or the document or stream that
#   ends after it. It is written after the last line of that.
# - Any other comment on a line of its own goes with the node after it and
#   is written before the line of that node. A node that starts a block
#   collection hands it to the first node in it.

proc precedes(a, b: Mark): bool =
  a.line < b.line or a.line == b.line and a.column < b.column

proc isBlock(event: Event): bool =
  event.kind in {yamlStartMap, yamlStartSeq} and event.collectionStyle != csFlow

proc blockIndentations(events: seq[Event], lines: seq[string]): seq[int] =
  ## For each event that ends a collection, the indentation of that
  ## collection; -1 for one that every comment until its end is in: a flow
  ## collection, a document, the stream.
  result = newSeq[int](events.len)
  var
    starts: seq[int] # the starts of the collections the event is in
    indentation = newSeq[int](events.len)
  proc column(i: int, ownKey = true): int =
    # the column of the node that event ``i`` starts. The start of a block
    # collection is not where its first node is, but the indicator before
    # its first child is, if any. A mapping that is the first key of a
    # mapping does not own the `?` before its first key.
    let event = events[i]
    if not event.isBlock or i + 1 >= events.len or
        events[i + 1].kind in {yamlEndMap, yamlEndSeq}:
      return int(event.startPos.column)
    let first = column(i + 1)
    let indicator = if event.kind == yamlStartSeq: '-' else: '?'
    if (ownKey or indicator == '-') and events[i + 1].startPos.line <= lines.len:
      let line = lines[events[i + 1].startPos.line - 1]
      var c = min(first - 2, line.len - 1)
      while c >= 0 and line[c] in {' ', '\t'}: dec(c)
      if c >= 0 and line[c] == indicator: return c + 1
    if event.kind == yamlStartMap: return first
    # an item on a line after its `-`
    if event.startPos.line <= lines.len:
      for c, ch in lines[event.startPos.line - 1]:
        if ch notin {' ', '\t'}: return c + 1
    int(event.startPos.column)
  for i, event in events:
    case event.kind
    of yamlStartMap, yamlStartSeq:
      if not event.isBlock: indentation[i] = -1
      else:
        indentation[i] = column(i, ownKey = starts.len == 0 or
            starts[^1] != i - 1 or events[starts[^1]].kind != yamlStartMap) - 1
        # a sequence that is not indented in its mapping ends with the
        # mapping's indentation
        if event.kind == yamlStartSeq and starts.len > 0 and
            events[starts[^1]].kind == yamlStartMap and
            indentation[starts[^1]] == indentation[i]:
          inc(indentation[i])
      starts.add(i)
    of yamlEndMap, yamlEndSeq:
      if starts.len > 0: result[i] = indentation[starts.pop()]
    of yamlEndDoc, yamlEndStream: result[i] = -1
    else: discard

proc attachComments(events: seq[Event], comments: seq[Comment],
    source: string): seq[EventComments] =
  result = newSeq[EventComments](events.len)
  var lines: seq[string]
  for line in source.splitLines: lines.add(line)
  proc blank(line: int): bool =
    line >= 1 and line <= lines.len and lines[line - 1].strip.len == 0
  let indentations = blockIndentations(events, lines)
  # the start of a block collection is not where its first node is, and an
  # empty node is where the next content is, not after its key or `-`
  var positions = newSeq[Mark](events.len)
  for i in countdown(events.high, 0):
    positions[i] =
      if events[i].isBlock and i < events.high and
          events[i + 1].kind notin {yamlEndMap, yamlEndSeq}: positions[i + 1]
      elif events[i].kind == yamlScalar and i > 0 and
          events[i].startPos == events[i].endPos: events[i - 1].endPos
      else: events[i].startPos
  var
    next = 0 # the first event that starts after the current comment
    # comments between the same events keep their order, so a comment goes
    # with no earlier event than the comment before it
    gap, lastTarget = -1
  for c in comments:
    while next < events.len and not c.startPos.precedes(positions[next]):
      inc(next)
    var kept = KeptComment(content: c.content.strip(leading = false),
        column: int(c.startPos.column))
    if c.trailing:
      let line = c.startPos.line
      if next > 1 and (positions[next - 1].line == line or
          events[next - 1].endPos.line == line):
        result[next - 1].trailing.add(kept)
        continue
      # a line without an event of its own, like that of a directive
    kept.blankBefore = blank(c.startPos.line - 1)
    kept.blankAfter = blank(c.startPos.line + 1)
    var target = if gap == next: max(next, lastTarget) else: next
    while target < events.len and events[target].kind in
        {yamlEndMap, yamlEndSeq, yamlEndDoc, yamlEndStream}:
      if indentations[target] <= kept.column - 1: break
      inc(target)
    if target >= events.len: continue
    gap = next
    lastTarget = target
    if events[target].kind in {yamlEndMap, yamlEndSeq, yamlEndDoc, yamlEndStream}:
      result[target].after.add(kept)
    else: result[target].before.add(kept)
  for i in 0 ..< events.len - 1:
    if events[i].isBlock and result[i].before.len > 0 and
        events[i + 1].kind notin {yamlEndMap, yamlEndSeq}:
      result[i + 1].before = result[i].before & result[i + 1].before
      result[i].before.setLen(0)

proc hasComments(comments: EventComments): bool =
  comments.before.len + comments.trailing.len + comments.after.len > 0

proc keepsComments*(options: PresentationOptions): bool =
  ## Whether `transform` keeps comments with ``options``: if they ask for it
  ## and the output has room for comments, see `CommentOptions`.
  options.comments.keep and options.newlines != nlNone and
      options.quoting != sqJson

proc doTransform(
  ctx  : var Context,
  input: Stream,
  resolveToCoreYamlTags: bool,
) =
  let keepComments = ctx.options.keepsComments
  var parser: YamlParser
  parser.init(keepComments = keepComments)
  var source: string
  if keepComments: source = input.readAll()
  var events =
    if keepComments: parser.parse(source)
    else: parser.parse(input)
  try:
    var bys: YamlStream = newBufferYamlStream()
    if keepComments:
      var buffered: seq[Event]
      for e in events: buffered.add(e)
      var comments: seq[Comment]
      # internalError is empty in release builds, so it cannot end a
      # try expression
      try: comments = events.comments
      except ValueError: internalError("transform parses its own input")
      if comments.len > 0:
        ctx.attached = attachComments(buffered, comments, source)
        ctx.commenting = true
        ctx.output = ctx.target
        ctx.target = newStringStream()
      # a collection that holds a comment cannot be written in a single line
      var
        starts: seq[int]
        commented = newSeq[bool](buffered.len)
      for i, e in buffered:
        let here = ctx.commenting and ctx.attached[i].hasComments
        case e.kind
        of yamlEndMap, yamlEndSeq:
          # a comment at the end of the line of the end is outside
          let start = starts.pop()
          if here and ctx.attached[i].after.len > 0: commented[start] = true
          if commented[start] or here:
            if starts.len > 0: commented[starts[^1]] = true
        else:
          if here and starts.len > 0: commented[starts[^1]] = true
          if e.kind in {yamlStartMap, yamlStartSeq}: starts.add(i)
      for i, e in buffered:
        var event = e.normalized(resolveToCoreYamlTags)
        if commented[i]:
          if event.kind == yamlStartMap: event.mapStyle = csBlock
          else: event.seqStyle = csBlock
        BufferYamlStream(bys).put(event)
    else:
      for e in events:
        BufferYamlStream(bys).put(e.normalized(resolveToCoreYamlTags))
    doPresent(ctx, bys)
  except YamlStreamError as e:
    var curE: ref Exception = e
    while curE.parent of YamlStreamError: curE = curE.parent
    if curE.parent of IOError: raise (ref IOError)(curE.parent)
    elif curE.parent of OSError: raise (ref OSError)(curE.parent)
    elif curE.parent of YamlParserError: raise (ref YamlParserError)(curE.parent)
    else: internalError("Unexpected exception: " & curE.parent.repr)

proc genInput(input: Stream): Stream = input
proc genInput(input: string): Stream = newStringStream(input)

proc transform*(
  input  : Stream | string,
  output : Stream,
  options: PresentationOptions = PresentationOptions(),
  resolveToCoreYamlTags: bool = false,
) {.raises: [
  IOError, OSError, YamlParserError, YamlPresenterJsonError,
  YamlPresenterOutputError
].} =
  ## Parse ``input`` as YAML character stream and then dump it to ``output``
  ## using the given presentation options.
  ## If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  ## The comments of ``input`` are kept if ``options.comments`` says so,
  ## see `CommentOptions`.
  var c = Context(target: output, options: options)
  doTransform(c, genInput(input), resolveToCoreYamlTags)

proc transform*(
  input  : Stream | string,
  options: PresentationOptions = PresentationOptions(),
  resolveToCoreYamlTags: bool = false,
): string {.raises: [
  IOError, OSError, YamlParserError, YamlPresenterJsonError,
  YamlPresenterOutputError
].} =
  ## Parse ``input`` as YAML character stream and then dump it
  ## using the given presentation options. Returns the resulting string.
  ## If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  ## The comments of ``input`` are kept if ``options.comments`` says so,
  ## see `CommentOptions`.
  var
    ss = newStringStream()
    c = Context(target: ss, options: options)
  doTransform(c, genInput(input), resolveToCoreYamlTags)
  return ss.data
