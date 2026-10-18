#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import streams, strutils, unicode
import ../data
when defined(yamlDebug):
  import terminal
  export terminal

type
  ScalarKind = enum
    skNone, skPlain, skSingleQuoted, skDoubleQuoted, skBlock,
    skLineEnd # not a scalar: waiting for the end of the current line

  ScalarContext = object
    ## what the lexer is reading, for the completion gate.
    kind: ScalarKind
    # absolute offset of the first content character
    contentStart: int
    # plain: the indentation a continuation line must exceed.
    # block: the content indentation, 0 while not yet known.
    indentation: int
    inFlow: bool

  CompletionGate = object
    ## After an attempt ran out of input inside a scalar, the gate scans only
    ## newly fed input for anything that could end the scalar (or make it
    ## invalid). Until it finds something, a new attempt would just run out
    ## of input again, so it is skipped. This makes feeding a large scalar in
    ## small chunks linear instead of quadratic.
    ##
    ## The gate is conservative: it may allow an attempt that runs out of
    ## input again, but it must never hold back an attempt that would
    ## succeed. ``finish`` disables it.
    armed: bool
    ctx: ScalarContext
    # absolute offset of the next character to scan
    scanPos: int
    atLineStart, prevSpace: bool
    col: int

  SourceBuffer = ref object
    ## Input characters. Data is only ever appended to the buffer, except by
    ## ``compact`` which drops consumed input between parser events.
    data: string
    # refill backend. nil for string and feed input.
    stream: Stream
    # no more data will be appended. reading past the end yields EndOfFile.
    final: bool
    # a read went past the end of a non-final buffer without a stream to
    # refill from. All results computed since the flag was reset are
    # based on a fake EndOfFile and must be discarded.
    starved: bool
    # error raised by ``stream`` while refilling
    error: ref CatchableError
    # offset of data[0] in the whole input. Grows when input is compacted.
    base: int
    # scalar currently being read, and its value at the first starvation of
    # the current attempt. Kept here so that it survives a rollback.
    scalar, starvedScalar: ScalarContext
    gate: CompletionGate
    gateDisabled: bool

  Source = object
    buf: SourceBuffer
    bufpos, lineNumber, lineStart: int
    # bufpos from which on compaction is attempted
    compactAt: int

  Lexer* = object
    cur*: Token
    curStartPos*, curEndPos*: Mark
    flowDepth*: int
    # recently read scalar or URI, if any
    evaluated*: string
    # internals
    indentation: int
    source: Source
    tokenStart: int
    state, lineStartState, jsonEnablingState: State
    c: char
    seenMultiline: bool
    # indentation of recently started set of node properties.
    # necessary for implicit keys with properties.
    propertyIndentation: int

  LexerError* = object of ValueError
    line*, column*: Positive
    lineContent*: string

  State = proc(lex: var Lexer): bool {.gcSafe, nimcall, raises: [LexerError].}

  Token* {.pure.} = enum
    YamlDirective,    # `%YAML`
    TagDirective,     # `%TAG`
    UnknownDirective, # any directive but `%YAML` and `%TAG`
    DirectiveParam,   # parameters of %YAML and unknown directives
    EmptyLine,        # for line folding in multiline plain scalars
    DirectivesEnd,    # explicit `---`
    DocumentEnd,      # explicit `...`
    StreamEnd,        # end of input
    Indentation,      # beginning of non-empty line
    Plain, SingleQuoted, DoubleQuoted, Literal, Folded,
    SeqItemInd,       # block sequence item indicator `- `
    MapKeyInd,        # block mapping key indicator `? `
    MapValueInd       # block mapping value indicator `: `
    MapStart, MapEnd, SeqStart, SeqEnd, SeqSep # {}[],
    TagHandle,        # a handle of a tag, e.g. `!!` of `!!str`
    Suffix,           # suffix of a tag shorthand, e.g. `str` of `!!str`.
                        # also used for the URI of the %TAG directive
    VerbatimTag,      # a verbatim tag, e.g. `!<tag:yaml.org,2002:str>`
    Anchor,           # anchor property of a node, e.g. `&anchor`
    Alias             # alias node, e.g. `*alias`

  ChompType* = enum
    ctKeep, ctClip, ctStrip

  LineStartType = enum
    lsDirectivesEndMarker, lsDocumentEndMarker, lsComment,
    lsNewline, lsStreamEnd, lsContent

# consts

const
  EndOfFile      = '\0'
  space          = {' ', '\t'}
  lineEnd        = {'\l', '\c', EndOfFile}
  spaceOrLineEnd = {' ', '\t', '\l', '\c', EndOfFile}
  commentOrLineEnd = {'\l', '\c', EndOfFile, '#'}
  digits         = {'0'..'9'}
  flowIndicators = {'[', ']', '{', '}', ','}
  uriChars       = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':',
      '@', '&', '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')'}
  tagShorthandChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}
  nodePropertyKind* = {Token.TagHandle, Token.VerbatimTag, Token.Anchor}
  scalarTokenKind* = {Token.Plain, Token.SingleQuoted, Token.DoubleQuoted,
                     Token.Literal, Token.Folded}

  UTF8NextLine           = toUTF8(0x85.Rune)
  UTF8NonBreakingSpace   = toUTF8(0xA0.Rune)
  UTF8LineSeparator      = toUTF8(0x2028.Rune)
  UTF8ParagraphSeparator = toUTF8(0x2029.Rune)

  UnknownIndentation* = int.low

  sourceChunkSize = 8192
  compactThreshold = 65536

# source buffer

proc fetch(b: SourceBuffer, i: int): char {.noinline, raises: [].} =
  while i >= b.data.len and not b.final:
    if b.stream.isNil:
      if not b.starved:
        b.starved = true
        b.starvedScalar = b.scalar
      return EndOfFile
    let oldLen = b.data.len
    b.data.setLen(oldLen + sourceChunkSize)
    var n = 0
    try:
      n = b.stream.readDataStr(b.data, oldLen ..< oldLen + sourceChunkSize)
    except CatchableError as ce:
      b.error = ce
    b.data.setLen(oldLen + n)
    if n <= 0: b.final = true
  result = if i < b.data.len: b.data[i] else: EndOfFile

proc `[]`(b: SourceBuffer, i: int): char {.inline, raises: [].} =
  if i < b.data.len: b.data[i] else: b.fetch(i)

proc `[]`(b: SourceBuffer, s: HSlice[int, int]): string {.raises: [].} =
  # after restoring a checkpoint, the buffer may not yet hold characters
  # that were read before the checkpoint, so a slice can reach past the
  # data like a single read can. Characters past the end of final input
  # only exist as EndOfFile and are never part of a lexeme.
  if s.b >= b.data.len: discard b.fetch(s.b)
  let last = min(s.b, b.data.len - 1)
  # a starved slice may start past the data; its result is discarded.
  if s.a > last: "" else: b.data[s.a .. last]

proc handleCR(s: var Source, pos: int): int {.raises: [].} =
  inc(s.lineNumber)
  result = pos + 1
  if s.buf[result] == '\l': inc(result)
  s.lineStart = result

proc handleLF(s: var Source, pos: int): int {.raises: [].} =
  inc(s.lineNumber)
  result = pos + 1
  s.lineStart = result

proc getColNumber(s: Source, pos: int): int {.raises: [].} =
  result = abs(pos - s.lineStart)

proc getCurrentLine(s: Source, marker: bool = true): string {.raises: [].} =
  # never starves the buffer: this is only used for diagnostics.
  result = ""
  var i = s.lineStart
  while true:
    let c =
      if i < s.buf.data.len: s.buf.data[i]
      elif not s.buf.stream.isNil: s.buf.fetch(i)
      else: EndOfFile
    if c in {'\c', '\l', EndOfFile}: break
    result.add(c)
    inc(i)
  result.add("\n")
  if marker:
    result.add(spaces(s.getColNumber(s.bufpos)) & "^\n")

proc currentIndentation*(lex: Lexer): int =
  return lex.source.getColNumber(lex.source.bufpos) - 1

proc recentIndentation*(lex: Lexer): int =
  return lex.indentation

# lexer source handling

proc advance(lex: var Lexer, step: int = 1) {.inline.} =
  lex.c = lex.source.buf[lex.source.bufpos]
  lex.source.bufpos.inc(step)

template checkStreamError(lex: var Lexer) =
  if not lex.source.buf.error.isNil:
    raise generateError(lex, "")

template lexCR(lex: var Lexer) =
  lex.source.bufpos = lex.source.handleCR(lex.source.bufpos - 1)
  lex.advance()
  lex.checkStreamError()

template lexLF(lex: var Lexer) =
  lex.source.bufpos = lex.source.handleLF(lex.source.bufpos - 1)
  lex.advance()
  lex.checkStreamError()

template lineNumber(lex: Lexer): Positive =
  lex.source.lineNumber

template columnNumber(lex: Lexer): Positive =
  lex.source.getColNumber(lex.source.bufpos)

template currentLine(lex: Lexer): string =
  lex.source.getCurrentLine(true)

proc isPlainSafe(lex: Lexer): bool {.inline.} =
  case lex.source.buf[lex.source.bufpos]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = lex.flowDepth == 0
  else: result = true

# lexer states

{.push gcSafe.}
# `raises` cannot be pushed.
proc outsideDoc(lex: var Lexer): bool {.raises: [].}
proc yamlVersion(lex: var Lexer): bool {.raises: LexerError.}
proc tagShorthand(lex: var Lexer): bool {.raises: LexerError.}
proc tagUri(lex: var Lexer): bool {.raises: LexerError.}
proc unknownDirParams(lex: var Lexer): bool {.raises: [].}
proc expectLineEnd(lex: var Lexer): bool {.raises: LexerError.}
proc lineStart(lex: var Lexer): bool {.raises: LexerError.}
proc flowLineStart(lex: var Lexer): bool {.raises: LexerError.}
proc flowLineIndentation(lex: var Lexer): bool {.raises: LexerError.}
proc insideLine(lex: var Lexer): bool {.raises: LexerError.}
proc indentationSettingToken(lex: var Lexer): bool {.raises: LexerError.}
proc afterToken(lex: var Lexer): bool {.raises: LexerError.}
proc beforeIndentationSettingToken(lex: var Lexer): bool {.raises: LexerError.}
proc afterJsonEnablingToken(lex: var Lexer): bool {.raises: LexerError.}
proc lineIndentation(lex: var Lexer): bool {.raises: [].}
proc lineDirEnd(lex: var Lexer): bool {.raises: [].}
proc lineDocEnd(lex: var Lexer): bool {.raises: [].}
proc atSuffix(lex: var Lexer): bool {.raises: [LexerError].}
proc streamEnd(lex: var Lexer): bool {.raises: [].}
{.pop.}

# helpers

template debug*(message: string) =
  when defined(yamlDebug):
    when nimvm:
      echo "yamlDebug: ", message
    else:
      try: styledWriteLine(stdout, fgBlue, message)
      except ValueError, IOError: discard

proc generateError(lex: Lexer, message: string):
    ref LexerError {.raises: [].} =
  # a failed refill makes the input look truncated. Whatever error that
  # provokes, the stream error is the actual cause.
  let streamError = lex.source.buf.error
  result = (ref LexerError)(
    msg: (if streamError.isNil: message
          else: "Encountered stream error: " & streamError.msg),
    parent: streamError, line: lex.lineNumber(), column: lex.columnNumber(),
    lineContent: lex.currentLine())

template beginScalar(lex: var Lexer, k: ScalarKind, contentStartPos, indent: int) =
  # tells the completion gate what is being read. Positions are buffer
  # indexes; ``indent`` is described at ``ScalarContext.indentation``.
  lex.source.buf.scalar = ScalarContext(kind: k,
      contentStart: lex.source.buf.base + contentStartPos,
      indentation: indent, inFlow: lex.flowDepth > 0)

proc startToken(lex: var Lexer) {.inline.} =
  lex.curStartPos = Mark(line: lex.lineNumber(), column: lex.columnNumber())
  lex.tokenStart = lex.source.bufpos

proc endToken(lex: var Lexer) {.inline.} =
  lex.curEndPos = Mark(line: lex.lineNumber(), column: lex.columnNumber())

proc readNumericSubtoken(lex: var Lexer) {.inline.} =
  if lex.c notin digits:
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  while true:
    lex.advance()
    if lex.c notin digits: break

proc isDirectivesEnd(lex: var Lexer): bool =
  var peek = lex.source.bufpos
  if lex.source.buf[peek] == '-':
    peek += 1
    if lex.source.buf[peek] == '-':
      peek += 1
      if lex.source.buf[peek] in spaceOrLineEnd:
        lex.source.bufpos = peek
        lex.advance()
        return true
  return false

proc isDocumentEnd(lex: var Lexer): bool =
  var peek = lex.source.bufpos
  if lex.source.buf[peek] == '.':
    peek += 1
    if lex.source.buf[peek] == '.':
      peek += 1
      if lex.source.buf[peek] in spaceOrLineEnd:
        lex.source.bufpos = peek
        lex.advance()
        return true
  return false

proc readHexSequence(lex: var Lexer, len: int) =
  var charPos = 0
  for i in countup(0, len-1):
    lex.advance()
    let digitPosition = len - i - 1
    case lex.c
    of lineEnd:
      raise lex.generateError("Unfinished unicode escape sequence")
    of '0'..'9':
      charPos = charPos or (int(lex.c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
      charPos = charPos or (int(lex.c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
      charPos = charPos or (int(lex.c) - 0x57) shl (digitPosition * 4)
    else:
      raise lex.generateError("Invalid character in hex escape sequence: " &
          escape("" & lex.c))
  lex.evaluated.add(toUTF8(Rune(charPos)))

proc readURI(lex: var Lexer, verbatim: bool) =
  lex.evaluated.setLen(0)
  let endWithSpace = lex.c != '<'
  let restricted = lex.flowDepth > 0 and not verbatim
  var literalStart: int
  if endWithSpace:
    if not restricted and lex.c in {'[', ']', ','}:
      raise lex.generateError("Flow indicator cannot start tag prefix")
    literalStart = lex.source.bufpos - 1
  else:
    literalStart = lex.source.bufpos
    lex.advance()
  while true:
    case lex.c
    of spaceOrLineEnd:
      if endWithSpace:
        lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
        break
      raise lex.generateError("Unclosed verbatim tag")
    of '%':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.readHexSequence(2)
      literalStart = lex.source.bufpos
    of uriChars: discard
    of '[', ']', ',':
      if restricted:
        lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
        break
    of '!':
      if restricted:
        raise lex.generateError("Illegal '!' in tag suffix")
    of '>':
      if endWithSpace:
        raise lex.generateError("Illegal character in URI: `>`")
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      break
    else:
      raise lex.generateError("Illegal character in URI: " & escape("" & lex.c))
    lex.advance()

proc endLine(lex: var Lexer) =
  while true:
    case lex.c
    of '\l':
      lex.lexLF()
      lex.state = lex.lineStartState
      break
    of '\c':
      lex.lexCR()
      lex.state = lex.lineStartState
      break
    of EndOfFile:
      lex.state = streamEnd
      break
    of '#':
      while true:
        lex.advance()
        if lex.c in lineEnd: break
    else: discard

proc startLine(lex: var Lexer): LineStartType =
  case lex.c
  of '-':
    return if lex.isDirectivesEnd(): lsDirectivesEndMarker
           else: lsContent
  of '.':
    return if lex.isDocumentEnd(): lsDocumentEndMarker
           else: lsContent
  else:
    while lex.c == ' ': lex.advance()
    if lex.c == '\t':
      var peek = lex.source.bufpos
      while lex.source.buf[peek] in space:
        peek += 1
      if lex.source.buf[peek] in commentOrLineEnd:
        lex.source.bufpos = peek + 1
        lex.c = lex.source.buf[peek]
      else:
        return lsContent
    return case lex.c
    of '#': lsComment
    of '\l', '\c': lsNewline
    of EndOfFile: lsStreamEnd
    else: lsContent

proc readPlainScalar(lex: var Lexer) =
  lex.evaluated.setLen(0)
  let afterNewlineState = if lex.flowDepth == 0: lineIndentation
                          else: flowLineIndentation
  var lineStartPos: int
  lex.seenMultiline = false
  lex.startToken()
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  lex.cur = Token.Plain
  lex.beginScalar(skPlain, lex.source.bufpos - 1, lex.indentation)
  block multilineLoop:
    while true:
      lineStartPos = lex.source.bufpos - 1
      block inlineLoop:
        while true:
          lex.advance()
          case lex.c
          of space:
            lex.endToken()
            let spaceStart = lex.source.bufpos - 2
            block spaceLoop:
              while true:
                lex.advance()
                case lex.c
                of '\l', '\c':
                  lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                  break inlineLoop
                of EndOfFile:
                  lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                  lex.state = streamEnd
                  break multilineLoop
                of '#':
                  lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                  lex.state = expectLineEnd
                  break multilineLoop
                of ':':
                  if not lex.isPlainSafe():
                    lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                    lex.state = insideLine
                    break multilineLoop
                  break spaceLoop
                of flowIndicators:
                  if lex.flowDepth > 0:
                    lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                    lex.state = insideLine
                    break multilineLoop
                  break spaceLoop
                of space: discard
                else: break spaceLoop
          of ':':
            if not lex.isPlainSafe():
              lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
              lex.endToken()
              lex.state = insideLine
              break multilineLoop
          of flowIndicators:
            if lex.flowDepth > 0:
              lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
              lex.endToken()
              lex.state = insideLine
              break multilineLoop
          of '\l', '\c':
            lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
            lex.endToken()
            break inlineLoop
          of EndOfFile:
            lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
            if lex.currentIndentation() > 0:
              lex.endToken()
            lex.state = streamEnd
            break multilineLoop
          else: discard
      lex.endLine()
      var newlines = 1
      block newlineLoop:
        while true:
          case lex.startLine()
          of lsContent:
            if lex.currentIndentation() <= lex.indentation:
              lex.state = afterNewlineState
              break multilineLoop
            if lex.c == '\t':
              while lex.c in space: lex.advance()
              case lex.c:
              of '#':
                lex.endLine()
                lex.state = lineStart
                break multilineLoop
              of '\l', '\c':
                lex.endLine()
                newlines += 1
                continue
              else: discard
            break newlineLoop
          of lsDirectivesEndMarker:
            lex.state = lineDirEnd
            break multilineLoop
          of lsDocumentEndMarker:
            lex.state = lineDocEnd
            break multilineLoop
          of lsStreamEnd:
            break multilineLoop
          of lsComment:
            lex.endLine()
            lex.state = lineStart
            break multilineLoop
          of lsNewline: lex.endLine()
          newlines += 1
      while lex.c in space: lex.advance()
      if (lex.c == ':' and not lex.isPlainSafe()) or
         lex.c == '#' or (lex.c in flowIndicators and
         lex.flowDepth > 0):
        lex.state = afterNewlineState
        break multilineLoop
      lex.seenMultiline = true
      if newlines == 1: lex.evaluated.add(' ')
      else:
        for i in countup(2, newlines): lex.evaluated.add('\l')

proc streamEndAfterBlock(lex: var Lexer) =
  if lex.currentIndentation() != 0:
    lex.endToken()
    lex.curEndPos.column -= 1

proc dirEndFollows(lex: Lexer): bool =
  return lex.c == '-' and lex.source.buf[lex.source.bufpos] == '-' and
      lex.source.buf[lex.source.bufpos+1] == '-'

proc docEndFollows(lex: Lexer): bool =
  return lex.c == '.' and lex.source.buf[lex.source.bufpos] == '.' and
      lex.source.buf[lex.source.bufpos+1] == '.'

proc readBlockScalar(lex: var Lexer) =
  var
    chomp = ctClip
    indent = 0
    separationLines = 0
    contentStart: int
    hasBody = true
  lex.startToken()
  lex.cur = if lex.c == '>': Token.Folded else: Token.Literal
  lex.evaluated.setLen(0)

  # header
  while true:
    lex.advance()
    case lex.c
    of '+':
      if chomp != ctClip:
        raise lex.generateError("Multiple chomping indicators")
      chomp = ctKeep
    of '-':
      if chomp != ctClip:
        raise lex.generateError("Multiple chomping indicators")
      chomp = ctStrip
    of '1' .. '9':
      if indent != 0:
        raise lex.generateError("Multiple indentation indicators")
      indent = max(0, lex.indentation) + int(lex.c) - int('0')
    of ' ':
      while true:
        lex.advance()
        if lex.c != ' ': break
      if lex.c notin commentOrLineEnd:
        raise lex.generateError("Illegal character after block scalar header: " &
            escape("" & lex.c))
      break
    of EndOfFile:
      hasBody = false
      break
    of '\l', '\c': break
    else:
      raise lex.generateError("Illegal character in block scalar header: " &
          escape("" & lex.c))
  lex.endLine()
  lex.beginScalar(skBlock, lex.source.bufpos - 1, if indent == 0: -1 else: indent)

  block body:
    # determining indentation and leading empty lines
    var
      maxLeadingSpaces = 0
      moreIndented = false
    while true:
      if indent == 0:
        while lex.c == ' ': lex.advance()
      else:
        maxLeadingSpaces = lex.currentIndentation() + indent
        while lex.c == ' ' and lex.currentIndentation() < maxLeadingSpaces:
          lex.advance()
      case lex.c
      of '\l', '\c':
        lex.endToken()
        maxLeadingSpaces = max(maxLeadingSpaces, lex.currentIndentation())
        lex.endLine()
        separationLines += 1
      of EndOfFile:
        lex.state = streamEnd
        lex.streamEndAfterBlock()
        if lex.source.getColNumber(lex.source.bufpos) > 1 and hasBody: separationLines += 1
        break body
      else:
        if indent == 0:
          indent = lex.currentIndentation()
          lex.source.buf.scalar.indentation = indent
          if indent <= lex.indentation or
              (indent == 0 and (lex.dirEndFollows() or lex.docEndFollows())):
            lex.state = lineIndentation
            break body
          elif indent < maxLeadingSpaces:
            raise lex.generateError("Leading all-spaces line contains too many spaces")
        elif lex.currentIndentation() < indent: break body
        if lex.cur == Token.Folded and lex.c in space:
          moreIndented = true
        break
    for i in countup(0, separationLines - 1):
      lex.evaluated.add('\l')
    separationLines = if moreIndented: 1 else: 0

    block content:
      while true:
        contentStart = lex.source.bufpos - 1
        while lex.c notin lineEnd: lex.advance()
        lex.evaluated.add(lex.source.buf[contentStart .. lex.source.bufpos - 2])
        if lex.c == EndOfFile:
          lex.state = streamEnd
          lex.streamEndAfterBlock()
          break body
        separationLines += 1
        lex.endToken()
        lex.endLine()

        let oldMoreIndented = moreIndented
        # empty lines and indentation of next line
        moreIndented = false
        while true:
          while lex.c == ' ' and lex.currentIndentation() < indent:
            lex.advance()
          case lex.c
          of '\l', '\c':
            lex.endToken()
            separationLines += 1
            lex.endLine()
          of EndOfFile:
            lex.state = streamEnd
            lex.streamEndAfterBlock()
            break body
          else:
            if lex.currentIndentation() < indent or
                (indent == 0 and (lex.dirEndFollows() or lex.docEndFollows())):
              break content
            if lex.cur == Token.Folded and lex.c in space:
              moreIndented = true
              if not oldMoreIndented:
                separationLines += 1
            break

        # line folding
        if lex.cur == Token.Literal:
          for i in countup(0, separationLines - 1):
            lex.evaluated.add('\l')
        elif separationLines == 1:
          lex.evaluated.add(' ')
        else:
          for i in countup(0, separationLines - 2):
            lex.evaluated.add('\l')
        separationLines = if moreIndented: 1 else: 0

    let markerFollows = lex.currentIndentation() == 0 and
        (lex.dirEndFollows() or lex.docEndFollows())
    if lex.c == '#':
      lex.state = expectLineEnd
    elif lex.currentIndentation() > lex.indentation and not markerFollows:
      raise lex.generateError("This line #" & $lex.curStartPos.line & " at " & escape("" & lex.c) & " is less indented than necessary")
    elif lex.currentIndentation() == 0:
      lex.state = lineStart
    else:
      lex.state = lineIndentation

  lex.endToken()

  case chomp
  of ctStrip: discard
  of ctClip:
    if len(lex.evaluated) > 0: lex.evaluated.add('\l')
  of ctKeep:
    for i in countup(0, separationLines - 1):
      lex.evaluated.add('\l')

proc processQuotedWhitespace(lex: var Lexer, initial: int) =
  var newlines = initial
  let firstSpace = lex.source.bufpos - 1
  while true:
    case lex.c
    of ' ', '\t': discard
    of '\l':
      lex.lexLF()
      break
    of '\c':
      lex.lexCR()
      break
    else:
      lex.evaluated.add(lex.source.buf[firstSpace..lex.source.bufpos - 2])
      return
    lex.advance()
  lex.seenMultiline = true
  while true:
    case lex.startLine()
    of lsContent, lsComment:
      while lex.c in space: lex.advance()
      if lex.c in {'\l', '\c'}:
        lex.endLine()
      else: break
    of lsDirectivesEndMarker:
      raise lex.generateError("Illegal `---` within quoted scalar")
    of lsDocumentEndMarker:
      raise lex.generateError("Illegal `...` within quoted scalar")
    of lsNewline: lex.endLine()
    of lsStreamEnd:
      raise lex.generateError("Unclosed quoted string")
    newlines += 1
  if newlines == 0: discard
  elif newlines == 1: lex.evaluated.add(' ')
  else:
    for i in countup(2, newlines): lex.evaluated.add('\l')

proc readSingleQuotedScalar(lex: var Lexer) =
  lex.seenMultiline = false
  lex.startToken()
  lex.evaluated.setLen(0)
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  var literalStart = lex.source.bufpos
  lex.beginScalar(skSingleQuoted, literalStart, 0)
  lex.advance()
  while true:
    case lex.c
    of EndOfFile:
      raise lex.generateError("Unclosed quoted string")
    of '\'':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      if lex.c == '\'':
        lex.evaluated.add('\'')
        literalStart = lex.source.bufpos
        lex.advance()
      else: break
    of ' ', '\t', '\l', '\c':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.processQuotedWhitespace(1)
      literalStart = lex.source.bufpos - 1
    else:
      lex.advance()
  lex.endToken()
  lex.cur = Token.SingleQuoted

proc readDoubleQuotedScalar(lex: var Lexer) =
  lex.seenMultiline = false
  lex.startToken()
  lex.evaluated.setLen(0)
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  var literalStart = lex.source.bufpos
  lex.beginScalar(skDoubleQuoted, literalStart, 0)
  lex.advance()
  while true:
    case lex.c
    of EndOfFile:
      raise lex.generateError("Unclosed quoted string")
    of '\\':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      literalStart = lex.source.bufpos
      case lex.c
      of '0': lex.evaluated.add('\0')
      of 'a': lex.evaluated.add('\a')
      of 'b': lex.evaluated.add('\b')
      of 't', '\t': lex.evaluated.add('\t')
      of 'n': lex.evaluated.add('\l')
      of 'v': lex.evaluated.add('\v')
      of 'f': lex.evaluated.add('\f')
      of 'r': lex.evaluated.add('\c')
      of 'e': lex.evaluated.add('\e')
      of ' ': lex.evaluated.add(' ')
      of '"': lex.evaluated.add('"')
      of '/': lex.evaluated.add('/')
      of '\\':lex.evaluated.add('\\')
      of 'N': lex.evaluated.add(UTF8NextLine)
      of '_': lex.evaluated.add(UTF8NonBreakingSpace)
      of 'L': lex.evaluated.add(UTF8LineSeparator)
      of 'P': lex.evaluated.add(UTF8ParagraphSeparator)
      of 'x':
        lex.readHexSequence(2)
        literalStart = lex.source.bufpos
      of 'u':
        lex.readHexSequence(4)
        literalStart = lex.source.bufpos
      of 'U':
        lex.readHexSequence(8)
        literalStart = lex.source.bufpos
      of '\l', '\c':
        lex.processQuotedWhitespace(0)
        literalStart = lex.source.bufpos - 1
        continue
      else:
        raise lex.generateError("Illegal character in escape sequence: " & escape("" & lex.c))
    of '"':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      break
    of ' ', '\t', '\l', '\c':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.processQuotedWhitespace(1)
      literalStart = lex.source.bufpos - 1
      continue
    else: discard
    lex.advance()
  lex.advance()
  lex.endToken()
  lex.cur = Token.DoubleQuoted

proc basicInit(lex: var Lexer) =
  lex.state = outsideDoc
  lex.flowDepth = 0
  lex.lineStartState = outsideDoc
  lex.jsonEnablingState = afterToken
  lex.propertyIndentation = -1
  lex.evaluated = ""
  lex.advance()

# interface

proc lastScalarWasMultiline*(lex: Lexer): bool =
  result = lex.seenMultiline

proc shortLexeme*(lex: Lexer): string =
  return lex.source.buf[lex.tokenStart..lex.source.bufpos-2]

proc fullLexeme*(lex: Lexer): string =
  return lex.source.buf[lex.tokenStart - 1..lex.source.bufpos-2]

proc currentLine*(lex: Lexer): string =
  return lex.source.getCurrentLine(false)

proc next*(lex: var Lexer) {.raises: [LexerError].}=
  lex.source.buf.scalar.kind = skNone
  while not lex.state(lex): discard
  lex.checkStreamError()
  debug("lexer -> [" & $lex.curStartPos.line & "," & $lex.curStartPos.column &
      "-" & $lex.curEndPos.line & "," & $lex.curEndPos.column & "] " & $lex.cur)

proc init*(lex: var Lexer, source: Stream) {.raises: [IOError, OSError].} =
  lex.source = Source(buf: SourceBuffer(stream: source), lineNumber: 1,
                      compactAt: compactThreshold)
  lex.basicInit()

proc init*(lex: var Lexer, source: string) {.raises: [].} =
  lex.source = Source(buf: SourceBuffer(data: source, final: true),
                      lineNumber: 1, compactAt: int.high) # in memory anyway
  lex.basicInit()

proc initFeed*(lex: var Lexer) {.raises: [].} =
  ## Initializes the lexer for input that is supplied via ``feed``.
  ## ``start`` must be called before the first token is read; since it
  ## reads the first character, it is subject to starvation like ``next``.
  lex.source = Source(buf: SourceBuffer(), lineNumber: 1,
                      compactAt: compactThreshold)

proc start*(lex: var Lexer) {.raises: [].} =
  lex.basicInit()

proc feed*(lex: var Lexer, data: openArray[char]) {.raises: [ValueError].} =
  ## Appends input. Raises ``ValueError`` after ``finish``.
  if lex.source.buf.final:
    raise newException(ValueError, "cannot feed input after finish")
  let oldLen = lex.source.buf.data.len
  lex.source.buf.data.setLen(oldLen + data.len)
  if data.len > 0:
    copyMem(addr lex.source.buf.data[oldLen], unsafeAddr data[0], data.len)

proc finish*(lex: var Lexer) {.raises: [].} =
  ## Signals that no more input will be fed.
  lex.source.buf.final = true

proc inputFinished*(lex: Lexer): bool {.raises: [].} =
  lex.source.buf.final

proc starved*(lex: Lexer): bool {.raises: [].} =
  ## ``true`` if a read went past the available input since the last call
  ## to ``resetStarved``.
  lex.source.buf.starved

proc resetStarved*(lex: var Lexer) {.raises: [].} =
  lex.source.buf.starved = false

proc retainedStart(lex: Lexer): int {.raises: [].} =
  # first buffer index that the lexer may still access between tokens:
  # the current line (for error messages), the current character and the
  # most recent token (for its lexeme).
  result = min(lex.source.lineStart, lex.source.bufpos - 1)
  if lex.tokenStart > 0: result = min(result, lex.tokenStart - 1)
  result = max(result, 0)

proc compactBuffer(lex: var Lexer) {.noinline, raises: [].} =
  let b = lex.source.buf
  let keep = lex.retainedStart()
  if keep < compactThreshold or keep * 2 < b.data.len:
    lex.source.compactAt = lex.source.bufpos + compactThreshold div 4
    return
  let rest = b.data.len - keep
  if rest > 0: moveMem(addr b.data[0], addr b.data[keep], rest)
  b.data.setLen(rest)
  b.base += keep
  lex.source.bufpos -= keep
  lex.source.lineStart -= keep
  lex.tokenStart = max(0, lex.tokenStart - keep)
  lex.source.compactAt = lex.source.bufpos + compactThreshold div 4

proc compact*(lex: var Lexer, allowFeed = false) {.inline, raises: [].} =
  ## Drops consumed input from the buffer. Must only be called between
  ## tokens, never while a token is being read.
  ##
  ## Compacting a non-final feed buffer shifts the buffer under any lexer
  ## state saved for rollback, so it is skipped unless ``allowFeed`` is set,
  ## which the caller may only do when no such state is held.
  if lex.source.bufpos >= lex.source.compactAt and
      (allowFeed or lex.source.buf.final or not lex.source.buf.stream.isNil):
    lex.compactBuffer()

proc bufferedLen*(lex: Lexer): int {.raises: [].} =
  ## Number of input characters currently held in the buffer.
  lex.source.buf.data.len

proc lineComplete*(lex: Lexer): bool {.raises: [].} =
  ## ``true`` if the buffer holds the current line up to its terminator, or
  ## if no more input will arrive.
  if lex.source.buf.final: return true
  for i in lex.source.lineStart ..< lex.source.buf.data.len:
    if lex.source.buf.data[i] in {'\l', '\c'}: return true
  return false

# completion gate

proc armGate*(lex: var Lexer, waitForLineEnd = false) {.raises: [].} =
  ## Called after an attempt was rolled back because it ran out of input.
  ## Arms the gate if the attempt ran out of input inside a scalar, or, with
  ## ``waitForLineEnd``, if it raised an error in a line that is not complete
  ## yet. The lexer may be in any state; only the buffer is used.
  let b = lex.source.buf
  b.gate.armed = false
  if b.gateDisabled or b.final: return
  let starvePos = b.base + b.data.len
  var g = CompletionGate(armed: true)
  if waitForLineEnd:
    g.ctx = ScalarContext(kind: skLineEnd)
    g.scanPos = starvePos
    b.gate = g
    return
  if not b.starved or b.starvedScalar.kind == skNone: return
  g.ctx = b.starvedScalar
  template at(abs: int): char = b.data[abs - b.base]
  let contentStart = max(g.ctx.contentStart, b.base)
  # rescan the last few characters if they may belong to a construct that
  # continues after them: an escape sequence, a quote that might be doubled,
  # or a colon whose meaning depends on the next character.
  var scanStart = starvePos
  case g.ctx.kind
  of skDoubleQuoted:
    var i = starvePos - 1
    while i >= contentStart and i >= starvePos - 10 and at(i) != '\\': dec(i)
    if i >= contentStart and i >= starvePos - 10:
      # start at the beginning of the backslash run, so that escapes are
      # paired correctly. Give up on absurdly long runs.
      while i > contentStart and at(i - 1) == '\\' and starvePos - i < 64:
        dec(i)
      if i > contentStart and at(i - 1) == '\\': return
      scanStart = i
    elif starvePos > contentStart and at(starvePos - 1) == '"':
      # the scalar has ended; the reader ran out of input looking past it
      scanStart = starvePos - 1
  of skSingleQuoted:
    while scanStart > contentStart and at(scanStart - 1) == '\'': dec(scanStart)
  of skPlain:
    if scanStart > contentStart and at(scanStart - 1) == ':': dec(scanStart)
  else: discard
  # find out whether scanStart is at the start of a line, apart from spaces.
  var lineStart = scanStart
  while lineStart > contentStart and at(lineStart - 1) notin {'\l', '\c'}:
    dec(lineStart)
  g.atLineStart = lineStart > contentStart or
      (lineStart == contentStart and g.ctx.kind == skBlock)
  if g.atLineStart:
    for i in lineStart ..< scanStart:
      if at(i) != ' ':
        # the line's first characters may still be under consideration
        # (e.g. whether `-` starts a `---` marker), so check the line start
        # again if they are only a few characters back.
        if scanStart - i <= 4: scanStart = lineStart
        elif g.ctx.kind == skPlain and at(i) == '\t':
          # for a line starting with a tab, the lexer looks ahead over any
          # whitespace to see whether the line is empty or a comment.
          var onlySpace = true
          for j in i ..< scanStart:
            if at(j) notin {' ', '\t'}:
              onlySpace = false
              break
          if onlySpace: scanStart = lineStart
          else: g.atLineStart = false
        else: g.atLineStart = false
        break
  if g.ctx.kind == skPlain:
    # a comment line ends a plain scalar; the reader then consumes the comment
    # and the line break after it. Wait for the line break, and if the reader
    # then needs the character after it, just retry.
    proc startsWithComment(b: SourceBuffer, first, last: int): bool =
      for i in first ..< last:
        case b.data[i - b.base]
        of ' ', '\t': discard
        of '#': return true
        else: return false
      return false
    if lineStart > contentStart and b.startsWithComment(lineStart, starvePos):
      b.gate = CompletionGate(armed: true,
          ctx: ScalarContext(kind: skLineEnd), scanPos: starvePos)
      return
    if lineStart > contentStart:
      var prevEnd = lineStart - 1
      if prevEnd > contentStart and at(prevEnd) == '\l' and
          at(prevEnd - 1) == '\c':
        dec(prevEnd)
      var prevStart = prevEnd
      while prevStart > contentStart and at(prevStart - 1) notin {'\l', '\c'}:
        dec(prevStart)
      if prevStart > contentStart and b.startsWithComment(prevStart, prevEnd):
        return
  g.col = scanStart - lineStart
  g.prevSpace = scanStart == lineStart or at(scanStart - 1) in {' ', '\t'}
  g.scanPos = scanStart
  b.gate = g

proc gateBlocks*(lex: var Lexer): bool {.raises: [].} =
  ## ``true`` if the input fed since the gate was armed cannot complete the
  ## scalar, so that a new attempt would run out of input again. Scans only
  ## input it has not scanned before.
  let b = lex.source.buf
  template g: untyped = b.gate
  if not g.armed: return false
  if b.final:
    g.armed = false
    return false
  var i = g.scanPos - b.base
  let data = addr b.data
  template trigger() =
    g.armed = false
    return false
  while i < data[].len:
    let c = data[][i]
    if c in {'\l', '\c'}:
      if g.ctx.kind == skLineEnd: trigger()
      g.atLineStart = true
      g.col = 0
      g.prevSpace = true
      inc(i)
      continue
    if g.atLineStart:
      if c == ' ':
        inc(g.col)
        inc(i)
        continue
      # a document marker `---` or `...` at column 0 ends every scalar
      # (decided character by character, like isDirectivesEnd; block scalars
      # use dirEndFollows/docEndFollows, which do not look at the character
      # after the marker)
      var marker = false
      if g.col == 0 and c in {'-', '.'}:
        var needMore = false
        marker = true
        for k in 1 .. (if g.ctx.kind == skBlock: 2 else: 3):
          if i + k >= data[].len:
            needMore = true
            break
          let d = data[][i + k]
          if (k < 3 and d != c) or (k == 3 and d notin {' ', '\t', '\l', '\c'}):
            marker = false
            break
        if needMore: break # state unchanged: look at this line start again
      g.atLineStart = false
      case g.ctx.kind
      of skPlain:
        # a continuation line must be more indented and must not start with
        # a comment or a tab. In flow context, lines are not checked further.
        if marker or c in {'\t', '#'} or g.ctx.inFlow or
            g.col <= g.ctx.indentation:
          trigger()
      of skSingleQuoted, skDoubleQuoted:
        if marker: trigger()
      of skBlock:
        if marker or g.ctx.indentation < 0 or g.col < g.ctx.indentation:
          trigger()
        inc(i)
        continue
      else: discard
    case g.ctx.kind
    of skPlain:
      if c == ':':
        # like isPlainSafe: a colon ends the scalar if followed by
        # whitespace, or by a flow indicator in flow context
        if i + 1 >= data[].len: break # need the next character
        let next = data[][i + 1]
        if next in {' ', '\t', '\l', '\c'} or
            (g.ctx.inFlow and next in flowIndicators):
          trigger()
      elif (c == '#' and g.prevSpace) or
          (g.ctx.inFlow and c in flowIndicators):
        trigger()
      g.prevSpace = c in {' ', '\t'}
      inc(i)
    of skDoubleQuoted:
      case c
      of '"': trigger()
      of '\\':
        if i + 1 >= data[].len: break # need the escaped character
        case data[][i + 1]
        of '0', 'a', 'b', 't', '\t', 'n', 'v', 'f', 'r', 'e', ' ', '"', '/',
           '\\', 'N', '_', 'L', 'P':
          i += 2
        of '\l', '\c':
          inc(i) # escaped line break, handled as line break
        of 'x', 'u', 'U':
          let digits = case data[][i + 1]
                       of 'x': 2
                       of 'u': 4
                       else: 8
          if i + 1 + digits >= data[].len: break # need all digits
          for j in i + 2 .. i + 1 + digits:
            if data[][j] notin {'0'..'9', 'a'..'f', 'A'..'F'}: trigger()
          i += 2 + digits
        else: trigger() # invalid escape: the attempt will raise an error
      else: inc(i)
    of skSingleQuoted:
      if c == '\'':
        if i + 1 >= data[].len: break # might be a doubled quote
        if data[][i + 1] != '\'': trigger()
        i += 2
      else: inc(i)
    of skBlock, skLineEnd, skNone: inc(i)
  g.scanPos = b.base + i
  return true

proc `completionGate=`*(lex: var Lexer, enabled: bool) {.raises: [].} =
  ## Enables or disables the completion gate (for testing).
  lex.source.buf.gateDisabled = not enabled
  if not enabled: lex.source.buf.gate.armed = false

# checkpoints

type
  LexerCheckpoint* = object
    ## Plain-data copy of the lexer state between two tokens. Positions are
    ## relative to ``offset``, the absolute input offset from which input
    ## must be supplied when restoring.
    offset*: int
    cur*: int
    curStartLine*, curStartColumn*, curEndLine*, curEndColumn*: int
    flowDepth*: int
    evaluated*: string
    indentation*: int
    bufpos*, lineNumber*, lineStart*, tokenStart*: int
    state*, lineStartState*, jsonEnablingState*: int
    c*: int
    seenMultiline*: bool
    propertyIndentation*: int

proc lexerStates(): array[19, State] {.raises: [].} =
  # the position of a state in this list is its checkpoint id. Append only.
  [State(outsideDoc), yamlVersion, tagShorthand, tagUri, unknownDirParams,
   expectLineEnd, lineStart, flowLineStart, flowLineIndentation, insideLine,
   indentationSettingToken, afterToken, beforeIndentationSettingToken,
   afterJsonEnablingToken, lineIndentation, lineDirEnd, lineDocEnd, atSuffix,
   streamEnd]

proc stateId(s: State): int {.raises: [ValueError].} =
  let states = lexerStates()
  for i, candidate in states:
    if candidate == s: return i
  raise newException(ValueError, "lexer is in a state without checkpoint id")

proc stateById(id: int): State {.raises: [ValueError].} =
  let states = lexerStates()
  if id < 0 or id > states.high:
    raise newException(ValueError, "invalid lexer state in checkpoint")
  states[id]

proc checkpoint*(lex: Lexer): LexerCheckpoint {.raises: [ValueError].} =
  ## Captures the lexer state. Must only be called between tokens.
  if not lex.source.buf.error.isNil:
    raise newException(ValueError, "cannot checkpoint after a stream error")
  let keep = lex.retainedStart()
  result = LexerCheckpoint(
    offset: lex.source.buf.base + keep,
    cur: ord(lex.cur),
    curStartLine: lex.curStartPos.line, curStartColumn: lex.curStartPos.column,
    curEndLine: lex.curEndPos.line, curEndColumn: lex.curEndPos.column,
    flowDepth: lex.flowDepth, evaluated: lex.evaluated,
    indentation: lex.indentation,
    bufpos: lex.source.bufpos - keep, lineNumber: lex.source.lineNumber,
    lineStart: lex.source.lineStart - keep,
    tokenStart: max(0, lex.tokenStart - keep),
    state: stateId(lex.state), lineStartState: stateId(lex.lineStartState),
    jsonEnablingState: stateId(lex.jsonEnablingState),
    c: ord(lex.c), seenMultiline: lex.seenMultiline,
    propertyIndentation: lex.propertyIndentation)

proc restore(lex: var Lexer, cp: LexerCheckpoint, buf: SourceBuffer, compactAt: int)
    {.raises: [ValueError].} =
  if cp.offset < 0 or cp.bufpos < 1 or cp.lineStart < 0 or cp.tokenStart < 0 or
      cp.lineNumber < 1 or cp.cur < ord(Token.low) or cp.cur > ord(Token.high) or
      cp.c < 0 or cp.c > 255 or cp.curStartLine < 1 or cp.curStartColumn < 1 or
      cp.curEndLine < 1 or cp.curEndColumn < 1 or cp.flowDepth < 0:
    raise newException(ValueError, "invalid lexer checkpoint")
  buf.base = cp.offset
  lex.source = Source(buf: buf, bufpos: cp.bufpos, lineNumber: cp.lineNumber,
                      lineStart: cp.lineStart, compactAt: compactAt)
  lex.cur = Token(cp.cur)
  lex.curStartPos = Mark(line: cp.curStartLine, column: cp.curStartColumn)
  lex.curEndPos = Mark(line: cp.curEndLine, column: cp.curEndColumn)
  lex.flowDepth = cp.flowDepth
  lex.evaluated = cp.evaluated
  lex.indentation = cp.indentation
  lex.tokenStart = cp.tokenStart
  lex.state = stateById(cp.state)
  lex.lineStartState = stateById(cp.lineStartState)
  lex.jsonEnablingState = stateById(cp.jsonEnablingState)
  lex.c = char(cp.c)
  lex.seenMultiline = cp.seenMultiline
  lex.propertyIndentation = cp.propertyIndentation

proc restore*(lex: var Lexer, cp: LexerCheckpoint, source: Stream)
    {.raises: [ValueError].} =
  ## Restores a checkpoint. ``source`` must deliver the input from
  ## ``cp.offset`` on.
  lex.restore(cp, SourceBuffer(stream: source), compactThreshold)

proc restore*(lex: var Lexer, cp: LexerCheckpoint, source: string)
    {.raises: [ValueError].} =
  ## Restores a checkpoint. ``source`` must be the input from ``cp.offset``
  ## on.
  lex.restore(cp, SourceBuffer(data: source, final: true), int.high)

proc restoreFeed*(lex: var Lexer, cp: LexerCheckpoint) {.raises: [ValueError].} =
  ## Restores a checkpoint for input that is supplied via ``feed``, starting
  ## at ``cp.offset``.
  lex.restore(cp, SourceBuffer(), compactThreshold)

# states

proc outsideDoc(lex: var Lexer): bool =
  case lex.c
  of '%':
    lex.startToken()
    while true:
      lex.advance()
      if lex.c in spaceOrLineEnd: break
    lex.endToken()
    let name = lex.shortLexeme()
    case name
    of "YAML":
      lex.state = yamlVersion
      lex.cur = Token.YamlDirective
    of "TAG":
      lex.state = tagShorthand
      lex.cur = Token.TagDirective
    else:
      lex.state = unknownDirParams
      lex.cur = Token.UnknownDirective
      lex.evaluated.setLen(0)
      lex.evaluated.add(name)
  of '-':
    lex.startToken()
    if lex.isDirectivesEnd():
      lex.state = afterToken
      lex.cur = Token.DirectivesEnd
    else:
      lex.state = indentationSettingToken
      lex.cur = Token.Indentation
    lex.lineStartState = lineStart
    lex.indentation = -1
    lex.endToken()
  of '.':
    lex.startToken()
    if lex.isDocumentEnd():
      lex.state = expectLineEnd
      lex.cur = Token.DocumentEnd
    else:
      lex.state = indentationSettingToken
      lex.lineStartState = lineStart
      lex.indentation = -1
      lex.cur = Token.Indentation
    lex.endToken()
  else:
    lex.startToken()
    while lex.c == ' ': lex.advance()
    if lex.c in commentOrLineEnd:
      lex.state = expectLineEnd
      return false
    if lex.c == '\t':
      var peek = lex.source.bufpos
      while lex.source.buf[peek] in space:
        peek += 1
      if lex.source.buf[peek] in commentOrLineEnd:
        lex.state = expectLineEnd
        lex.source.bufpos = peek
        return false
    lex.endToken()
    lex.cur = Token.Indentation
    lex.indentation = -1
    lex.state = indentationSettingToken
    lex.lineStartState = lineStart
  return true

proc yamlVersion(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  lex.startToken()
  lex.readNumericSubtoken()
  if lex.c != '.':
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  lex.advance()
  lex.readNumericSubtoken()
  if lex.c notin spaceOrLineEnd:
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  lex.cur = Token.DirectiveParam
  lex.endToken()
  lex.state = expectLineEnd
  return true

proc tagShorthand(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c != '!':
    raise lex.generateError("Illegal character, tag shorthand must start with '!': " & escape("" & lex.c))
  lex.startToken()
  lex.advance()

  if lex.c in spaceOrLineEnd: discard
  else:
    while lex.c in tagShorthandChars: lex.advance()
    if lex.c != '!':
      if lex.c in spaceOrLineEnd:
        raise lex.generateError("Tag shorthand must end with '!'.")
      else:
        raise lex.generateError("Illegal character in tag shorthand: " & escape("" & lex.c))
    lex.advance()
    if lex.c notin spaceOrLineEnd:
      raise lex.generateError("Missing space after tag shorthand")
  lex.cur = Token.TagHandle
  lex.endToken()
  lex.state = tagUri
  return true

proc tagUri(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  lex.startToken()
  if lex.c == '<':
    raise lex.generateError("Illegal character in tag URI: " & escape("" & lex.c))
  lex.readUri(false)
  lex.cur = Token.Suffix
  lex.endToken()
  lex.state = expectLineEnd
  return true

proc unknownDirParams(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c in lineEnd + {'#'}:
    lex.state = expectLineEnd
    return false
  lex.startToken()
  while true:
    lex.advance()
    if lex.c in lineEnd + {'#'}: break
  lex.cur = Token.DirectiveParam
  return true

proc expectLineEnd(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c notin commentOrLineEnd:
    raise lex.generateError("Unexpected character (expected line end): " & escape("" & lex.c))
  lex.endLine()
  return false

proc lineStart(lex: var Lexer): bool =
  return case lex.startLine()
  of lsDirectivesEndMarker: lex.lineDirEnd()
  of lsDocumentEndMarker: lex.lineDocEnd()
  of lsComment, lsNewline: lex.endLine(); false
  of lsStreamEnd: lex.state = streamEnd; false
  of lsContent:
    if lex.flowDepth == 0: lex.lineIndentation()
    else: lex.flowLineIndentation()

proc flowLineStart(lex: var Lexer): bool =
  var indent: int
  case lex.c
  of '-':
    if lex.isDirectivesEnd():
      raise lex.generateError("Directives end marker before end of flow content")
    indent = 0
  of '.':
    if lex.isDocumentEnd():
      raise lex.generateError("Document end marker before end of flow content")
    indent = 0
  else:
    let lineStart = lex.source.bufpos
    while lex.c == ' ': lex.advance()
    indent = lex.source.bufpos - lineStart
    while lex.c in space: lex.advance()
  if lex.c in commentOrLineEnd:
    lex.state = expectLineEnd
    return false
  if indent <= lex.indentation:
    raise lex.generateError("Too few indentation spaces (must surpass surrounding block level)")
  lex.state = insideLine
  return false

proc flowLineIndentation(lex: var Lexer): bool =
  if lex.currentIndentation() < lex.indentation:
    raise lex.generateError("Too few indentation spaces (must surpass surrounding block level)")
  lex.state = insideLine
  return false

proc checkIndicatorChar(lex: var Lexer, kind: Token) =
  if lex.isPlainSafe():
    lex.readPlainScalar()
  else:
    lex.startToken()
    lex.advance()
    lex.endToken()
    lex.cur = kind
    lex.state = beforeIndentationSettingToken

proc enterFlowCollection(lex: var Lexer, kind: Token) =
  lex.startToken()
  if lex.flowDepth == 0:
    lex.jsonEnablingState = afterJsonEnablingToken
    lex.lineStartState = flowLineStart
    lex.propertyIndentation = -1
  lex.flowDepth += 1
  lex.state = afterToken
  lex.advance()
  lex.endToken()
  lex.cur = kind

proc leaveFlowCollection(lex: var Lexer, kind: Token) =
  lex.startToken()
  if lex.flowDepth == 0:
    raise lex.generateError("No flow collection to leave!")
  lex.flowDepth -= 1
  if lex.flowDepth == 0:
    lex.jsonEnablingState = afterToken
    lex.lineStartState = lineStart
  lex.state = lex.jsonEnablingState
  lex.advance()
  lex.endToken()
  lex.cur = kind

proc readNamespace(lex: var Lexer) =
  lex.startToken()
  lex.advance()
  if lex.c == '<':
    lex.readURI(true)
    lex.endToken()
    lex.cur = Token.VerbatimTag
    lex.state = afterToken
  else:
    var handleEnd = lex.tokenStart
    while true:
      case lex.source.buf[handleEnd]
      of spaceOrLineEnd + flowIndicators:
        handleEnd = lex.tokenStart
        lex.source.bufpos -= 1
        break
      of '!':
        handleEnd += 1
        break
      else:
        handleEnd += 1
    while lex.source.bufpos < handleEnd:
      lex.advance()
      if lex.c notin tagShorthandChars + {'!'}:
        raise lex.generateError("Illegal character in tag handle: " & escape("" & lex.c))
    lex.advance()
    lex.endToken()
    lex.cur = Token.TagHandle
    lex.state = atSuffix

proc readAnchorName(lex: var Lexer) =
  lex.startToken()
  while true:
    lex.advance()
    if lex.c in spaceOrLineEnd + flowIndicators: break
  if lex.source.bufpos == lex.tokenStart + 1:
    raise lex.generateError("Anchor name must not be empty")
  lex.state = afterToken

proc insideLine(lex: var Lexer): bool =
  case lex.c
  of ':':
    lex.checkIndicatorChar(Token.MapValueInd)
    if lex.cur == Token.MapValueInd and lex.propertyIndentation != -1:
      lex.indentation = lex.propertyIndentation
      lex.propertyIndentation = -1
  of '?':
    lex.checkIndicatorChar(Token.MapKeyInd)
  of '-':
    lex.checkIndicatorChar(Token.SeqItemInd)
  of commentOrLineEnd:
    lex.endLine()
    return false
  of '"':
    lex.readDoubleQuotedScalar()
    lex.state = lex.jsonEnablingState
  of '\'':
    lex.readSingleQuotedScalar()
    lex.state = lex.jsonEnablingState
  of '>', '|':
    if lex.flowDepth > 0:
      lex.readPlainScalar()
    else:
      lex.readBlockScalar()
  of '{':
    lex.enterFlowCollection(Token.MapStart)
  of '}':
    lex.leaveFlowCollection(Token.MapEnd)
  of '[':
    lex.enterFlowCollection(Token.SeqStart)
  of ']':
    lex.leaveFlowCollection(Token.SeqEnd)
  of ',':
    lex.startToken()
    lex.advance()
    lex.endToken()
    lex.cur = Token.SeqSep
    lex.state = afterToken
  of '!':
    lex.readNamespace()
  of '&':
    lex.readAnchorName()
    lex.endToken()
    lex.cur = Token.Anchor
  of '*':
    lex.readAnchorName()
    lex.endToken()
    lex.cur = Token.Alias
  of ' ', '\t':
    while true:
      lex.advance()
      if lex.c notin space: break
    return false
  of '@', '`':
    raise lex.generateError("Reserved character may not start any token")
  else:
    lex.readPlainScalar()
  return true

proc indentationSettingToken(lex: var Lexer): bool =
  let cachedIndentation = lex.currentIndentation()
  result = lex.insideLine()
  if result and lex.flowDepth == 0:
    if lex.cur in nodePropertyKind:
      lex.propertyIndentation = cachedIndentation
    else:
      lex.indentation = cachedIndentation

proc afterToken(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c in commentOrLineEnd:
    lex.endLine()
  else:
    lex.state = insideLine
  return false

proc beforeIndentationSettingToken(lex: var Lexer): bool =
  discard lex.afterToken()
  if lex.state == insideLine:
    lex.state = indentationSettingToken
  return false

proc afterJsonEnablingToken(lex: var Lexer): bool =
  while lex.c == ' ': lex.advance()
  while true:
    case lex.c
    of ':':
      lex.startToken()
      lex.advance()
      lex.endToken()
      lex.cur = Token.MapValueInd
      lex.state = afterToken
      return true
    of '#', '\l', '\c':
      lex.endLine()
      discard lex.flowLineStart()
    of EndOfFile:
      lex.state = streamEnd
      return false
    else:
      lex.state = insideLine
      return false

proc lineIndentation(lex: var Lexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = Token.Indentation
  lex.state = indentationSettingToken
  return true

proc lineDirEnd(lex: var Lexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = Token.DirectivesEnd
  lex.state = afterToken
  lex.indentation = -1
  lex.propertyIndentation = -1
  return true

proc lineDocEnd(lex: var Lexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = Token.DocumentEnd
  lex.state = expectLineEnd
  lex.lineStartState = outsideDoc
  return true

proc atSuffix(lex: var Lexer): bool =
  lex.startToken()
  lex.evaluated.setLen(0)
  var curStart = lex.tokenStart - 1
  while true:
    case lex.c
    of uriChars: lex.advance()
    of '%':
      if curStart <= lex.source.bufpos - 2:
        lex.evaluated.add(lex.source.buf[curStart..lex.source.bufpos - 2])
      lex.readHexSequence(2)
      curStart = lex.source.bufpos
      lex.advance()
    else: break
  if curStart <= lex.source.bufpos - 2:
    lex.evaluated.add(lex.source.buf[curStart..lex.source.bufpos - 2])
  lex.endToken()
  lex.cur = Token.Suffix
  lex.state = afterToken
  return true

proc streamEnd(lex: var Lexer): bool =
  lex.startToken()
  lex.endToken()
  lex.cur = Token.StreamEnd
  return true