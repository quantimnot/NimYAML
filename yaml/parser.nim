#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/parser
## ==================
##
## This is the low-level parser API. A ``YamlParser`` enables you to parse any
## non-nil string or Stream object as YAML character stream.

import tables, strutils, macros, streams, std/importutils
import stream, private/lex, private/internal, private/escaping, private/uri, data,
    memory, source

when defined(nimNoNil):
    {.experimental: "notnil".}

type
  YamlParser* = object
    ## A parser object. Retains its ``TagLibrary`` across calls to
    ## `parse <#parse,YamlParser,Stream>`_. Can be used
    ## to access anchor names while parsing a YAML character stream, but
    ## only until the document goes out of scope (i.e. until
    ## ``yamlEndDocument`` is yielded).
    issueWarnings: bool
    directiveExtensions: bool
    sourceUri: string
    keepComments: bool
    budget: MemoryBudget

  YamlParserError* = object of YamlLoadingError
    ## A parser error is raised if the character stream that is parsed is
    ## not a valid YAML character stream. This stream cannot and will not be
    ## parsed wholly nor partially and all events that have been emitted by
    ## the YamlStream the parser provides should be discarded.
    ##
    ## A character stream is invalid YAML if and only if at least one of the
    ## following conditions apply:
    ##
    ## - There are invalid characters in an element whose contents is
    ##   restricted to a limited set of characters. For example, there are
    ##   characters in a tag URI which are not valid URI characters.
    ## - An element has invalid indentation. This can happen for example if
    ##   a block list element indicated by ``"- "`` is less indented than
    ##   the element in the previous line, but there is no block sequence
    ##   list open at the same indentation level.
    ## - The YAML structure is invalid. For example, an explicit block map
    ##   indicated by ``"? "`` and ``": "`` may not suddenly have a block
    ##   sequence item (``"- "``) at the same indentation level. Another
    ##   possible violation is closing a flow style object with the wrong
    ##   closing character (``}``, ``]``) or not closing it at all.
    ## - A custom tag shorthand is used that has not previously been
    ##   declared with a ``%TAG`` directive.
    ## - Multiple tags or anchors are defined for the same node.
    ## - An alias has a tag or anchor associated with it.
    ##
    ## Some elements in this list are vague. For a detailed description of a
    ## valid YAML character stream, see the YAML specification.

  YamlDocumentStart* = object
    ## Where the source of a document begins: the start of the line holding
    ## its first directive, its `---` marker or, for a document without
    ## either, its first content. ``offset`` is a byte offset in the whole
    ## input, ``line`` the line number there. Parsing can start at a
    ## document start, see `parse <#parse,YamlParser,string,YamlDocumentStart>`_.
    ##
    ## A document start also carries what parsing from it needs to know
    ## about the documents before it: ``index``, the 0-based number of the
    ## document in the stream, and ``globals``, the ``%GLOBAL`` directives of
    ## the first document (empty for the first document itself, which
    ## declares them).
    offset*, line*: int
    index*: int
    globals*: seq[Directive]

  State = proc(ctx: Context, e: var Event): bool {.gcSafe, raises: [CatchableError].}

  Level = object
    state: State
    indentation: int

  Context = ref object of YamlStream
    handles: seq[tuple[handle, uriPrefix: string]]
    issueWarnings: bool
    # NimYAML's directive extensions, see `beforeDoc`. ``globals`` are
    # declared in the directive block of the first document and apply to
    # every document; ``documentsBegun`` counts the documents whose first
    # token has been read, so that the first one can be told apart.
    directiveExtensions: bool
    sourceUri: string
    globals: seq[Directive]
    documentsBegun: int
    budget: MemoryBudget
    lex: Lexer
    levels: seq[Level]
    keyCache: seq[Event]
    keyCachePos: int
    caching: bool

    headerProps, inlineProps: Properties
    headerStart, inlineStart: Mark
    blockIndentation: int
    # start of the most recently started document, and the offset of the
    # line of its `---` (its start, if it has no directives before it);
    # error recovery must resume after both, or it would parse the failed
    # document again from its marker
    documentStart: YamlDocumentStart
    documentMarker: int
    # whether the current document's directive block is being read: a
    # document that fails there has its `---` still ahead
    inDirectiveBlock: bool

  YamlDocumentError* = object
    ## An error that `parseRecovering` recovered from.
    error*: ref YamlParserError
    ## Where parsing continued after the error: the start of the next
    ## document after the error. ``offset`` is -1 if no document followed.
    resumedAt*: YamlDocumentStart

  YamlRecoveringStream* = ref object of YamlStream
    ## A parser that recovers from errors, see `parseRecovering`.
    ctx: Context
    buffer: seq[Event]
    pos: int
    errors: seq[YamlDocumentError]
    # offset of the line parsing last continued at after an error
    lastResync: int
    streamStarted, needToken: bool

const defaultProperties = (yAnchorNone, yTagQuestionMark)

# parser states

{.push gcSafe, raises: [CatchableError].}
proc atStreamStart(ctx: Context, e: var Event): bool
proc beforeDoc(ctx: Context, e: var Event): bool
proc beforeDocEnd(ctx: Context, e: var Event): bool
proc afterDirectivesEnd(ctx: Context, e: var Event): bool
proc beforeImplicitRoot(ctx: Context, e: var Event): bool
proc atBlockIndentation(ctx: Context, e: var Event): bool
proc beforeBlockIndentation(ctx: Context, e: var Event): bool
proc beforeNodeProperties(ctx: Context, e: var Event): bool
proc afterCompactParent(ctx: Context, e: var Event): bool
proc afterCompactParentProps(ctx: Context, e: var Event): bool
proc mergePropsOnNewline(ctx: Context, e: var Event): bool
proc beforeFlowItemProps(ctx: Context, e: var Event): bool
proc inBlockSeq(ctx: Context, e: var Event): bool
proc beforeBlockMapValue(ctx: Context, e: var Event): bool
proc atBlockIndentationProps(ctx: Context, e: var Event): bool
proc beforeFlowItem(ctx: Context, e: var Event): bool
proc afterFlowSeqSep(ctx: Context, e: var Event): bool
proc afterFlowMapSep(ctx: Context, e: var Event): bool
proc atBlockMapKeyProps(ctx: Context, e: var Event): bool
proc afterImplicitKey(ctx: Context, e: var Event): bool
proc afterBlockParent(ctx: Context, e: var Event): bool
proc afterBlockParentProps(ctx: Context, e: var Event): bool
proc afterImplicitPairStart(ctx: Context, e: var Event): bool
proc beforePairValue(ctx: Context, e: var Event): bool
proc afterFlowMapValue(ctx: Context, e: var Event): bool
proc afterFlowSeqSepProps(ctx: Context, e: var Event): bool
proc afterFlowSeqItem(ctx: Context, e: var Event): bool
proc beforeBlockMapKey(ctx: Context, e: var Event): bool
proc afterFlowMapKey(ctx: Context, e: var Event): bool
{.pop.}
{.push gcSafe, raises: [].}
proc atStreamEnd(ctx: Context, e : var Event): bool
proc atEmptyPairKey(ctx: Context, e: var Event): bool
proc afterPairValue(ctx: Context, e: var Event): bool
proc emitCached(ctx: Context, e: var Event): bool
{.pop.}

template pushLevel(ctx: Context, newState: State, newIndent: int) =
  debug("parser: push " & newState.astToStr & ", indent = " & $newIndent)
  ctx.levels.add(Level(state: newState, indentation: newIndent))

template pushLevel(ctx: Context, newState: State) =
  debug("parser: push " & newState.astToStr)
  ctx.levels.add(Level(state: newState))

template transition(ctx: Context, newState: State) =
  debug("parser: transition " & newState.astToStr)
  ctx.levels[^1].state = newState

template transition(ctx: Context, newState: State, newIndent) =
  debug("parser: transition " & newState.astToStr & ", indent = " & $newIndent)
  ctx.levels[^1] = Level(state: newState, indentation: newIndent)

template updateIndentation(ctx: Context, newIndent: int) =
  debug("parser: update indent = " & $newIndent)
  ctx.levels[^1].indentation = newIndent

template popLevel(ctx: Context) =
  debug("parser: pop")
  discard ctx.levels.pop()

proc resolveHandle(ctx: Context, handle: string): string {.raises: [].} =
  for item in ctx.handles:
    if item.handle == handle:
      return item.uriPrefix
  return ""

proc initCommon(ctx: Context, p: YamlParser) =
  ctx.pushLevel(atStreamStart, -2)
  ctx.nextImpl = proc(s: YamlStream, e: var Event): bool {.raises: [CatchableError], gcsafe, closure.} =
    let c = Context(s)
    c.lex.compact()
    return c.levels[^1].state(c, e)
  ctx.lastTokenContextImpl = proc(s: YamlStream, lineContent: var string): bool {.gcsafe, raises: [], closure.} =
    lineContent = Context(s).lex.currentLine()
    return true
  ctx.headerProps = defaultProperties
  ctx.inlineProps = defaultProperties
  ctx.issueWarnings = p.issueWarnings
  ctx.directiveExtensions = p.directiveExtensions
  ctx.sourceUri = p.sourceUri
  ctx.budget = p.budget
  ctx.lex.directiveExtensions = p.directiveExtensions
  ctx.lex.keepComments = p.keepComments
  ctx.keyCachePos = 0
  ctx.caching = false

proc continueAt(ctx: Context, start: YamlDocumentStart) =
  ## Prepares parsing from ``start`` as if the documents before it had been
  ## parsed: they declared the global directives and count as begun.
  ctx.globals = start.globals
  ctx.documentsBegun = start.index

proc init(ctx: Context, p: YamlParser, source: Stream) {.inline.} =
  ctx.initCommon(p)
  ctx.lex.init(source, budget = p.budget)

proc init(ctx: Context, p: YamlParser, source: string) {.inline.} =
  ctx.initCommon(p)
  ctx.lex.init(source)

# interface

proc init*(p: var YamlParser, issueWarnings: bool = false,
    directiveExtensions = true, sourceUri = "", keepComments = false,
    budget: MemoryBudget = nil) =
  ## Initializes a YAML parser. See `initYamlParser`.
  p.issueWarnings = issueWarnings
  p.directiveExtensions = directiveExtensions
  p.sourceUri = sourceUri
  p.keepComments = keepComments
  p.budget = budget

proc initYamlParser*(issueWarnings: bool = false, directiveExtensions = true,
    sourceUri = "", keepComments = false,
    budget: MemoryBudget = nil): YamlParser =
  ## Creates an initializes YAML parser and returns it.
  ##
  ## With ``directiveExtensions``, the parser implements NimYAML's
  ## ``%GLOBAL`` and ``%SCHEMA`` directives (see the README); without, they
  ## are reserved directives like any other, as YAML 1.2 defines them.
  ## ``sourceUri`` is the URI the input was retrieved from; relative
  ## ``%SCHEMA`` references resolve against it. With ``keepComments``, the
  ## streams of the parser collect the comments of the input, see
  ## `comments <#comments,YamlStream>`_. ``budget`` is charged for the
  ## input the parser buffers when it reads a `Stream` or `YamlSource`: a
  ## line or token that does not fit raises a `YamlParserError` whose
  ## ``parent`` is a `YamlMemoryLimitError`. String input is not charged.
  result.init(issueWarnings, directiveExtensions, sourceUri, keepComments,
      budget)

proc budget*(p: YamlParser): MemoryBudget =
  ## The memory budget of ``p``, nil if it has none.
  p.budget

proc parse*(p: YamlParser, s: Stream): YamlStream =
  let ctx = new(Context)
  ctx.init(p, s)
  return ctx

proc parse*(p: YamlParser, s: string): YamlStream =
  let ctx = new(Context)
  ctx.init(p, s)
  return ctx

proc parse*(p: YamlParser, s: string, start: YamlDocumentStart): YamlStream =
  ## Parses input that begins at the document start ``start`` of some
  ## original input: ``s`` must be the original input from byte
  ## ``start.offset`` on, e.g. ``input[start.offset .. ^1]``. The stream
  ## yields ``yamlStartStream``, then that document and all following ones,
  ## with positions (and further document starts) referring to the original
  ## input.
  let ctx = new(Context)
  ctx.initCommon(p)
  ctx.continueAt(start)
  ctx.lex.init(s, start.offset, start.line)
  return ctx

proc parse*(p: YamlParser, s: Stream, start: YamlDocumentStart): YamlStream =
  ## Like the `string` variant; ``s`` must deliver the original input from
  ## byte ``start.offset`` on, e.g. after ``s.setPosition(start.offset)``.
  let ctx = new(Context)
  ctx.initCommon(p)
  ctx.continueAt(start)
  ctx.lex.init(s, start.offset, start.line, p.budget)
  return ctx

proc parse*(p: YamlParser, src: YamlSource): YamlStream
    {.raises: [IOError, OSError].} =
  ## Parses the input of ``src``, reading it as a stream; the lexer keeps a
  ## sliding window of it, charged to the budget of ``p``.
  p.parse(newSourceStream(src))

proc parse*(p: YamlParser, src: YamlSource, start: YamlDocumentStart):
    YamlStream {.raises: [IOError, OSError].} =
  ## Parses the input of ``src`` from the document start ``start`` on; see
  ## the `string` variant.
  p.parse(newSourceStream(src, start.offset), start)

proc documentStart*(s: YamlStream): YamlDocumentStart {.raises: [ValueError].} =
  ## The start of the document whose ``yamlStartDoc`` event was most recently
  ## returned by ``s``, which must come from `parse`, `resume` or
  ## `parseRecovering`.
  if s of YamlRecoveringStream: return YamlRecoveringStream(s).ctx.documentStart
  if not (s of Context):
    raise newException(ValueError, "documentStart requires a YamlStream from parse")
  Context(s).documentStart

proc comments*(s: YamlStream): seq[Comment] {.raises: [ValueError].} =
  ## The comments of the input that ``s`` has read so far, in input order.
  ## ``s`` must come from `parse`, `resume` or `parseRecovering` of a parser
  ## initialized with ``keepComments``; otherwise there are none. Comments
  ## are read along with the tokens around them, so after the last event,
  ## all comments of the input are there.
  if s of YamlRecoveringStream: return YamlRecoveringStream(s).ctx.lex.comments
  if not (s of Context):
    raise newException(ValueError, "comments requires a YamlStream from parse")
  Context(s).lex.comments

proc takeComments*(s: YamlStream): seq[Comment] {.raises: [ValueError].} =
  ## Like `comments <#comments,YamlStream>`_, but hands the comments over:
  ## a later call returns only the comments read since, so that a stream of
  ## any length need not keep all of its comments.
  if s of YamlRecoveringStream:
    return move YamlRecoveringStream(s).ctx.lex.comments
  if not (s of Context):
    raise newException(ValueError, "comments requires a YamlStream from parse")
  move Context(s).lex.comments

type
  YamlFeedParser* = ref object
    ## A push-style parser for input that arrives in chunks, e.g. from a
    ## socket or an async pipe. Input is supplied with `feed`, events are
    ## pulled with `tryNext`. When the available input does not suffice to
    ## produce the next event, `tryNext` returns ``false`` and the parser
    ## resumes from the same point once more input has been fed. Call
    ## `finish` once all input has been fed.
    ##
    ## Event production is all-or-nothing: an attempt that runs out of input
    ## is rolled back, so no event and no error is ever based on incomplete
    ## input. The next attempt starts over from the beginning of the event.
    ## For scalars, a completion gate skips attempts until the new input can
    ## end the scalar, so feeding a large scalar in small chunks is linear.
    ## A flow collection is parsed as a whole and re-parsed by every attempt:
    ## feeding a large one in small chunks costs time quadratic in its size,
    ## so feed chunks of a few KiB or more.
    ##
    ## Consumed input is discarded between events. The buffer holds the
    ## input of the event in progress (for flow collections: the whole
    ## collection) plus whatever has been fed but not yet parsed; `feed`
    ## never blocks, so drain `events` after each `feed` to keep it small.
    ##
    ## Unlike the parser returned by `parse`, a ``YamlFeedParser`` is not a
    ## `YamlStream`; it yields plain events.
    ctx: Context
    started, ended: bool
    # buffered input length of the last attempt that ran out of input,
    # -1 if the last attempt did not. Unchanged length = nothing new to try.
    starvedAt: int
    error: ref YamlParserError
    # event to return before parsing further: a peeked event restored from
    # the checkpoint of a YamlStream
    pending: seq[Event]
    # number of parse attempts made (for testing the completion gate)
    attempts: int

proc newYamlFeedParser*(p: YamlParser): YamlFeedParser =
  ## Creates a feed parser using the settings of ``p``.
  let ctx = new(Context)
  ctx.initCommon(p)
  ctx.lex.initFeed(budget = p.budget)
  result = YamlFeedParser(ctx: ctx, starvedAt: -1)

proc newYamlFeedParser*(p: YamlParser, start: YamlDocumentStart): YamlFeedParser =
  ## Creates a feed parser for input that begins at the document start
  ## ``start`` of some original input: feed the original input from byte
  ## ``start.offset`` on. Positions refer to the original input.
  let ctx = new(Context)
  ctx.initCommon(p)
  ctx.continueAt(start)
  ctx.lex.initFeed(start.offset, start.line, p.budget)
  result = YamlFeedParser(ctx: ctx, starvedAt: -1)

proc documentStart*(fp: YamlFeedParser): YamlDocumentStart =
  ## The start of the document whose ``yamlStartDoc`` event was most recently
  ## returned by ``fp``.
  fp.ctx.documentStart

proc feed*(fp: YamlFeedParser, data: openArray[char]) {.raises: [ValueError].} =
  ## Appends ``data`` to the input. Raises ``ValueError`` if called after
  ## `finish`.
  fp.ctx.lex.feed(data)

proc finish*(fp: YamlFeedParser) =
  ## Signals that all input has been fed. Afterwards, `tryNext` returns
  ## ``true`` until the ``yamlEndStream`` event has been returned.
  fp.ctx.lex.finish()

proc finished*(fp: YamlFeedParser): bool =
  ## ``true`` once the ``yamlEndStream`` event has been returned.
  fp.ended

proc comments*(fp: YamlFeedParser): seq[Comment] =
  ## Like `comments <#comments,YamlStream>`_: the comments of the input
  ## that ``fp`` has parsed so far, if its parser was initialized with
  ## ``keepComments``. Input that an attempt read before running out of
  ## input is read again by the next attempt, which replaces its comments.
  fp.ctx.lex.comments

proc tryNext*(fp: YamlFeedParser, e: var Event): bool
    {.raises: [YamlParserError].} =
  ## Tries to produce the next event. Returns ``true`` and sets ``e`` if an
  ## event could be produced. Returns ``false`` if more input must be fed
  ## first, or if the stream has already ended (see `finished`).
  ##
  ## Raises `YamlParserError` if the input is invalid. An error is only
  ## raised once the input fed so far proves it, and once the line it
  ## occurs in is complete, so its position and line content equal those
  ## reported for the same input given as a string. After an error, every
  ## further call raises the same error.
  if not fp.error.isNil: raise fp.error
  if fp.ended: return false
  if fp.pending.len > 0:
    e = fp.pending.pop()
    if e.kind == yamlEndStream: fp.ended = true
    return true
  let ctx = fp.ctx
  let final = ctx.lex.inputFinished()
  if not final and fp.starvedAt == ctx.lex.bufferedLen(): return false
  # skip the attempt if the new input cannot complete the scalar that the
  # previous attempt ran out of input in.
  if not final and ctx.lex.gateBlocks(): return false
  # no lexer state is held here, so the feed buffer may be compacted.
  ctx.lex.compact(allowFeed = true)
  var snapshot: typeof(ctx[])
  if not final:
    snapshot = ctx[]
    ctx.lex.resetStarved()
  template rollback(waitForLineEnd = false) =
    ctx[] = move(snapshot)
    fp.starvedAt = ctx.lex.bufferedLen()
    ctx.lex.armGate(waitForLineEnd)
    return false
  inc(fp.attempts)
  try:
    if not fp.started:
      ctx.lex.start()
    while not ctx.levels[^1].state(ctx, e): discard
  except CatchableError as ce:
    if not final:
      if ctx.lex.starved(): rollback()
      if not ctx.lex.lineComplete(): rollback(waitForLineEnd = true)
    var pe: ref YamlParserError
    if ce of YamlParserError:
      pe = (ref YamlParserError)(ce)
    elif ce of YamlStreamError and ce.parent of YamlParserError:
      # raised by a nested ``next`` while caching a flow collection
      pe = (ref YamlParserError)(ce.parent)
    else:
      pe = (ref YamlParserError)(msg: ce.msg, parent: ce,
          mark: ctx.lex.curStartPos, lineContent: ctx.lex.currentLine())
    fp.error = pe
    raise pe
  if not final and ctx.lex.starved(): rollback()
  fp.starvedAt = -1
  fp.started = true
  if e.kind == yamlEndStream: fp.ended = true
  result = true

iterator events*(fp: YamlFeedParser): Event {.raises: [YamlParserError].} =
  ## Yields all events that can be produced from the input fed so far.
  var e: Event
  while fp.tryNext(e): yield e

# checkpoints

type
  YamlCheckpointHandle* = object
    handle*, uriPrefix*: string

  YamlCheckpointDirective* = object
    ## Plain-data form of a `Directive`.
    kind*: DirectiveKind
    origin*: DirectiveOrigin
    overridden*: bool
    positions*: seq[int] ## start, end, value start, value end (line, column)
    value*, handle*, uri*: string ## version or prefix or reference; handle; uri

  YamlCheckpointIssue* = object
    ## Plain-data form of a `DirectiveIssue`.
    kind*: DirectiveIssueKind
    message*: string
    positions*: seq[int] ## start, end (line, column)

  YamlCheckpointEvent* = object
    ## Plain-data form of an `Event`.
    kind*: EventKind
    startLine*, startColumn*, endLine*, endColumn*: int
    anchor*, tag*: string
    collectionStyle*: CollectionStyle
    scalarStyle*: ScalarStyle
    # scalar content, alias target or %YAML version
    content*: string
    # explicitDirectivesEnd or explicitDocumentEnd
    explicit*: bool
    handles*: seq[YamlCheckpointHandle]
    # yamlStartDoc: whether ``directives`` is set, and its content
    hasDirectives*: bool
    schema*: string
    declarations*: seq[YamlCheckpointDirective]
    issues*: seq[YamlCheckpointIssue]

  YamlCheckpointLevel* = object
    state*, indentation*: int

  YamlCheckpoint* = object
    ## The state of a parser between two events, from which parsing can be
    ## resumed later, e.g. in another process. A checkpoint is plain data and
    ## can be serialized with NimYAML itself (or any other serializer that
    ## handles objects, sequences, strings, integers, booleans and enums).
    ##
    ## ``offset`` is the byte offset in the original input from which input
    ## must be supplied when resuming. Offsets of checkpoints taken from a
    ## resumed parser still refer to the original input.
    ##
    ## All other fields are internal: they may change between NimYAML
    ## versions and must not be modified. A checkpoint can only be resumed by
    ## a NimYAML version with the same ``version``. ``checksum`` covers all
    ## other fields, so that a checkpoint corrupted in storage is rejected
    ## instead of being resumed; it is not a protection against deliberate
    ## manipulation.
    version*: int
    checksum*: string
    offset*: int
    started*, ended*: bool
    lexer*: LexerCheckpoint
    handles*: seq[YamlCheckpointHandle]
    levels*: seq[YamlCheckpointLevel]
    keyCache*: seq[YamlCheckpointEvent]
    keyCachePos*: int
    caching*: bool
    headerAnchor*, headerTag*, inlineAnchor*, inlineTag*: string
    headerStartLine*, headerStartColumn*: int
    inlineStartLine*, inlineStartColumn*: int
    blockIndentation*: int
    documentStartOffset*, documentStartLine*, documentStartIndex*: int
    # %GLOBAL directives, and the number of documents begun
    globals*: seq[YamlCheckpointDirective]
    documentsBegun*: int
    # event that has been peeked but not yet returned by ``next``
    peeked*: seq[YamlCheckpointEvent]

export LexerCheckpoint

const checkpointVersion* = 2
  ## Version of the checkpoint format created by this NimYAML version.

proc parserStates(): array[33, State] {.raises: [].} =
  # the position of a state in this list is its checkpoint id. Append only.
  [State(atStreamStart), beforeDoc, beforeDocEnd, afterDirectivesEnd,
   beforeImplicitRoot, atBlockIndentation, beforeBlockIndentation,
   beforeNodeProperties, afterCompactParent, afterCompactParentProps,
   mergePropsOnNewline, beforeFlowItemProps, inBlockSeq, beforeBlockMapValue,
   atBlockIndentationProps, beforeFlowItem, afterFlowSeqSep, afterFlowMapSep,
   atBlockMapKeyProps, afterImplicitKey, afterBlockParent,
   afterBlockParentProps, afterImplicitPairStart, beforePairValue,
   afterFlowMapValue, afterFlowSeqSepProps, afterFlowSeqItem, atStreamEnd,
   atEmptyPairKey, afterPairValue, emitCached, afterFlowMapKey,
   beforeBlockMapKey]

proc stateId(s: State): int {.raises: [ValueError].} =
  let states = parserStates()
  for i, candidate in states:
    if candidate == s: return i
  raise newException(ValueError, "parser is in a state without checkpoint id")

proc stateById(id: int): State {.raises: [ValueError].} =
  let states = parserStates()
  if id < 0 or id > states.high:
    raise newException(ValueError, "invalid parser state in checkpoint")
  states[id]

proc toCheckpoint(d: Directive): YamlCheckpointDirective =
  result = YamlCheckpointDirective(kind: d.kind, origin: d.origin,
      overridden: d.overridden)
  for m in [d.startPos, d.endPos, d.valueStart, d.valueEnd]:
    result.positions.add([int(m.line), int(m.column)])
  case d.kind
  of dkYaml: result.value = d.version
  of dkTag:
    result.value = d.prefix
    result.handle = d.handle
  of dkSchema:
    result.value = d.reference
    result.uri = d.uri

proc toCheckpoint(directives: seq[Directive]): seq[YamlCheckpointDirective] =
  for d in directives: result.add(d.toCheckpoint())

proc toCheckpoint(i: DirectiveIssue): YamlCheckpointIssue =
  YamlCheckpointIssue(kind: i.kind, message: i.message,
      positions: @[int(i.startPos.line), int(i.startPos.column),
                   int(i.endPos.line), int(i.endPos.column)])

proc toCheckpoint(handles: seq[tuple[handle, uriPrefix: string]]):
    seq[YamlCheckpointHandle] =
  for h in handles:
    result.add(YamlCheckpointHandle(handle: h.handle, uriPrefix: h.uriPrefix))

proc fromCheckpoint(handles: seq[YamlCheckpointHandle]):
    seq[tuple[handle, uriPrefix: string]] =
  for h in handles: result.add((handle: h.handle, uriPrefix: h.uriPrefix))

proc toCheckpoint(e: Event): YamlCheckpointEvent =
  result = YamlCheckpointEvent(kind: e.kind,
      startLine: e.startPos.line, startColumn: e.startPos.column,
      endLine: e.endPos.line, endColumn: e.endPos.column)
  case e.kind
  of yamlStartMap:
    result.anchor = string(e.mapProperties.anchor)
    result.tag = string(e.mapProperties.tag)
    result.collectionStyle = e.mapStyle
  of yamlStartSeq:
    result.anchor = string(e.seqProperties.anchor)
    result.tag = string(e.seqProperties.tag)
    result.collectionStyle = e.seqStyle
  of yamlScalar:
    result.anchor = string(e.scalarProperties.anchor)
    result.tag = string(e.scalarProperties.tag)
    result.scalarStyle = e.scalarStyle
    result.content = e.scalarContent
  of yamlStartDoc:
    result.explicit = e.explicitDirectivesEnd
    result.content = e.version
    result.handles = e.handles.toCheckpoint()
    if not e.directives.isNil:
      result.hasDirectives = true
      result.schema = e.directives.schema
      result.declarations = e.directives.declarations.toCheckpoint()
      for i in e.directives.issues: result.issues.add(i.toCheckpoint())
  of yamlEndDoc:
    result.explicit = e.explicitDocumentEnd
  of yamlAlias:
    result.content = string(e.aliasTarget)
  of yamlStartStream, yamlEndStream, yamlEndMap, yamlEndSeq: discard

proc toMark(line, column: int): Mark {.raises: [ValueError].} =
  if line == 0 and column == 0:
    # positions the parser has not set yet are zero-initialized, outside of
    # the range of ``Positive``. Restore them as they were.
    zeroMem(addr result, sizeof(result))
    return
  if line < 1 or column < 1:
    raise newException(ValueError, "invalid position in checkpoint")
  Mark(line: line, column: column)

proc markAt(positions: seq[int], i: int): Mark {.raises: [ValueError].} =
  if positions.len < 2 * i + 2:
    raise newException(ValueError, "invalid position in checkpoint")
  toMark(positions[2 * i], positions[2 * i + 1])

proc fromCheckpoint(c: YamlCheckpointDirective): Directive
    {.raises: [ValueError].} =
  result = case c.kind
    of dkYaml: Directive(kind: dkYaml, version: c.value)
    of dkTag: Directive(kind: dkTag, handle: c.handle, prefix: c.value)
    of dkSchema: Directive(kind: dkSchema, reference: c.value, uri: c.uri)
  result.origin = c.origin
  result.overridden = c.overridden
  result.startPos = c.positions.markAt(0)
  result.endPos = c.positions.markAt(1)
  result.valueStart = c.positions.markAt(2)
  result.valueEnd = c.positions.markAt(3)

proc fromCheckpoint(directives: seq[YamlCheckpointDirective]): seq[Directive]
    {.raises: [ValueError].} =
  for d in directives: result.add(d.fromCheckpoint())

proc fromCheckpoint(c: YamlCheckpointEvent): Event {.raises: [ValueError].} =
  let
    startPos = toMark(c.startLine, c.startColumn)
    endPos = toMark(c.endLine, c.endColumn)
    props = (Anchor(c.anchor), Tag(c.tag))
  result = case c.kind
    of yamlStartStream: Event(kind: yamlStartStream)
    of yamlEndStream: Event(kind: yamlEndStream)
    of yamlStartMap:
      Event(kind: yamlStartMap, mapProperties: props, mapStyle: c.collectionStyle)
    of yamlStartSeq:
      Event(kind: yamlStartSeq, seqProperties: props, seqStyle: c.collectionStyle)
    of yamlScalar:
      Event(kind: yamlScalar, scalarProperties: props,
            scalarStyle: c.scalarStyle, scalarContent: c.content)
    of yamlStartDoc:
      Event(kind: yamlStartDoc, explicitDirectivesEnd: c.explicit,
            version: c.content, handles: c.handles.fromCheckpoint())
    of yamlEndDoc: Event(kind: yamlEndDoc, explicitDocumentEnd: c.explicit)
    of yamlEndMap: Event(kind: yamlEndMap)
    of yamlEndSeq: Event(kind: yamlEndSeq)
    of yamlAlias: Event(kind: yamlAlias, aliasTarget: Anchor(c.content))
  if c.kind == yamlStartDoc and c.hasDirectives:
    result.directives = DocumentDirectives(schema: c.schema,
        declarations: c.declarations.fromCheckpoint())
    for i in c.issues:
      result.directives.issues.add(DirectiveIssue(kind: i.kind,
          message: i.message, startPos: i.positions.markAt(0),
          endPos: i.positions.markAt(1)))
  result.startPos = startPos
  result.endPos = endPos

proc enc(s: var string, x: int) = s.add($x & ";")
proc enc(s: var string, x: bool) = s.add(if x: "1;" else: "0;")
proc enc(s: var string, x: string) = s.add($x.len & ":" & x)
proc enc[E: enum](s: var string, x: E) = s.enc(ord(x))

proc enc(s: var string, h: YamlCheckpointHandle) =
  s.enc(h.handle)
  s.enc(h.uriPrefix)

proc enc(s: var string, d: YamlCheckpointDirective) =
  s.enc(d.kind)
  s.enc(d.origin)
  s.enc(d.overridden)
  s.enc(d.positions.len)
  for x in d.positions: s.enc(x)
  s.enc(d.value)
  s.enc(d.handle)
  s.enc(d.uri)

proc enc(s: var string, i: YamlCheckpointIssue) =
  s.enc(i.kind)
  s.enc(i.message)
  s.enc(i.positions.len)
  for x in i.positions: s.enc(x)

proc enc(s: var string, e: YamlCheckpointEvent) =
  s.enc(e.kind)
  for x in [e.startLine, e.startColumn, e.endLine, e.endColumn]: s.enc(x)
  s.enc(e.anchor)
  s.enc(e.tag)
  s.enc(e.collectionStyle)
  s.enc(e.scalarStyle)
  s.enc(e.content)
  s.enc(e.explicit)
  s.enc(e.handles.len)
  for h in e.handles: s.enc(h)
  s.enc(e.hasDirectives)
  s.enc(e.schema)
  s.enc(e.declarations.len)
  for d in e.declarations: s.enc(d)
  s.enc(e.issues.len)
  for i in e.issues: s.enc(i)

proc digest(cp: YamlCheckpoint): string =
  ## FNV-1a over a canonical encoding of all fields but ``checksum``.
  var s = ""
  s.enc(cp.version)
  s.enc(cp.offset)
  s.enc(cp.started)
  s.enc(cp.ended)
  let l = cp.lexer
  for x in [l.offset, l.cur, l.curStartLine, l.curStartColumn, l.curEndLine,
            l.curEndColumn, l.flowDepth, l.indentation, l.bufpos, l.lineNumber,
            l.lineStart, l.tokenStart, l.state, l.lineStartState,
            l.jsonEnablingState, l.c, l.propertyIndentation]:
    s.enc(x)
  s.enc(l.evaluated)
  s.enc(l.seenMultiline)
  s.enc(cp.handles.len)
  for h in cp.handles: s.enc(h)
  s.enc(cp.levels.len)
  for level in cp.levels:
    s.enc(level.state)
    s.enc(level.indentation)
  s.enc(cp.keyCache.len)
  for e in cp.keyCache: s.enc(e)
  s.enc(cp.keyCachePos)
  s.enc(cp.caching)
  for x in [cp.headerAnchor, cp.headerTag, cp.inlineAnchor, cp.inlineTag]:
    s.enc(x)
  for x in [cp.headerStartLine, cp.headerStartColumn, cp.inlineStartLine,
            cp.inlineStartColumn, cp.blockIndentation, cp.documentStartOffset,
            cp.documentStartLine, cp.documentStartIndex, cp.documentsBegun]:
    s.enc(x)
  s.enc(cp.globals.len)
  for d in cp.globals: s.enc(d)
  s.enc(cp.peeked.len)
  for e in cp.peeked: s.enc(e)
  var h = 0xcbf29ce484222325'u64
  for c in s:
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  result = toHex(h)

proc checkpoint(ctx: Context, started: bool): YamlCheckpoint {.raises: [ValueError].} =
  result = YamlCheckpoint(version: checkpointVersion, started: started,
      handles: ctx.handles.toCheckpoint(), keyCachePos: ctx.keyCachePos,
      caching: ctx.caching,
      headerAnchor: string(ctx.headerProps.anchor),
      headerTag: string(ctx.headerProps.tag),
      inlineAnchor: string(ctx.inlineProps.anchor),
      inlineTag: string(ctx.inlineProps.tag),
      headerStartLine: ctx.headerStart.line,
      headerStartColumn: ctx.headerStart.column,
      inlineStartLine: ctx.inlineStart.line,
      inlineStartColumn: ctx.inlineStart.column,
      blockIndentation: ctx.blockIndentation,
      documentStartOffset: ctx.documentStart.offset,
      documentStartLine: ctx.documentStart.line,
      documentStartIndex: ctx.documentStart.index,
      globals: ctx.globals.toCheckpoint(), documentsBegun: ctx.documentsBegun)
  if started:
    result.lexer = ctx.lex.checkpoint()
    result.offset = result.lexer.offset
  for level in ctx.levels:
    result.levels.add(YamlCheckpointLevel(state: stateId(level.state),
                                          indentation: level.indentation))
  for e in ctx.keyCache: result.keyCache.add(e.toCheckpoint())

proc restore(ctx: Context, cp: YamlCheckpoint) {.raises: [ValueError].} =
  ## restores everything but the lexer.
  if cp.version != checkpointVersion:
    raise newException(ValueError, "checkpoint has format version " &
        $cp.version & ", this NimYAML version requires " & $checkpointVersion)
  if cp.checksum != cp.digest():
    raise newException(ValueError, "checkpoint is corrupted (checksum mismatch)")
  # cheap structural checks, also for checkpoints with a matching checksum.
  # Between two events, cached events are only pending while emitCached is
  # on top of the stack.
  let emitCachedId = stateId(emitCached)
  var valid = cp.levels.len > 0 and cp.peeked.len <= 1 and not cp.caching and
      cp.keyCachePos >= 0 and
      (if cp.keyCache.len == 0:
         cp.keyCachePos == 0 and cp.levels[^1].state != emitCachedId
       else: cp.keyCachePos < cp.keyCache.len and
             cp.levels[^1].state == emitCachedId)
  if valid:
    for i in 0 ..< cp.levels.len - 1:
      if cp.levels[i].state == emitCachedId: valid = false
  if valid and cp.started:
    let l = cp.lexer
    valid = l.offset == cp.offset and l.bufpos >= 1 and
        l.lineStart <= l.bufpos - 1 and l.tokenStart <= l.bufpos and
        l.bufpos < int.high div 4 and l.lineNumber < int.high div 4 and
        l.flowDepth < int.high div 4
  elif valid:
    valid = cp.offset == 0
  if not valid:
    raise newException(ValueError, "invalid checkpoint")
  ctx.handles = cp.handles.fromCheckpoint()
  ctx.levels.setLen(0)
  for level in cp.levels:
    ctx.levels.add(Level(state: stateById(level.state),
                         indentation: level.indentation))
  ctx.keyCache.setLen(0)
  for e in cp.keyCache: ctx.keyCache.add(e.fromCheckpoint())
  ctx.keyCachePos = cp.keyCachePos
  ctx.caching = cp.caching
  ctx.headerProps = (Anchor(cp.headerAnchor), Tag(cp.headerTag))
  ctx.inlineProps = (Anchor(cp.inlineAnchor), Tag(cp.inlineTag))
  ctx.headerStart = toMark(cp.headerStartLine, cp.headerStartColumn)
  ctx.inlineStart = toMark(cp.inlineStartLine, cp.inlineStartColumn)
  ctx.blockIndentation = cp.blockIndentation
  ctx.globals = cp.globals.fromCheckpoint()
  ctx.documentsBegun = cp.documentsBegun
  ctx.documentStart = YamlDocumentStart(offset: cp.documentStartOffset,
                                        line: cp.documentStartLine,
                                        index: cp.documentStartIndex)
  # the globals of a document start are those of the stream, except for the
  # first document, which declares them
  if ctx.documentStart.index > 0: ctx.documentStart.globals = ctx.globals
  ctx.documentMarker = ctx.documentStart.offset
  if cp.peeked.len == 1: ctx.peek = cp.peeked[0].fromCheckpoint()

proc checkpoint*(s: YamlStream): YamlCheckpoint {.raises: [ValueError].} =
  ## Captures the state of a parser returned by `parse` or `resume`. Call it
  ## only between two calls of ``next``, never from code that runs inside
  ## ``next``. Raises ``ValueError`` if ``s`` is not such a parser, or if it
  ## has raised an error (including a failure of its input stream).
  if not (s of Context):
    raise newException(ValueError, "checkpoint requires a YamlStream from parse or resume")
  privateAccess(YamlStream)
  if s.failed:
    raise newException(ValueError, "cannot checkpoint after an error")
  let ctx = Context(s)
  result = ctx.checkpoint(true)
  if s.peeked: result.peeked.add(s.cached.toCheckpoint())
  result.checksum = result.digest()

proc checkpoint*(fp: YamlFeedParser): YamlCheckpoint {.raises: [ValueError].} =
  ## Captures the state of a feed parser. Raises ``ValueError`` after an
  ## error. Neither input that has been fed but not yet parsed nor a call of
  ## `finish` is part of the checkpoint: when resuming, feed from ``offset``
  ## on and call `finish` again.
  if not fp.error.isNil:
    raise newException(ValueError, "cannot checkpoint after an error")
  result = fp.ctx.checkpoint(fp.started)
  for e in fp.pending: result.peeked.add(e.toCheckpoint())
  result.ended = fp.ended
  result.checksum = result.digest()

proc resumeContext(p: YamlParser, cp: YamlCheckpoint): Context {.raises: [ValueError].} =
  result = new(Context)
  result.initCommon(p)
  result.restore(cp)

proc resume*(p: YamlParser, cp: YamlCheckpoint, s: Stream): YamlStream
    {.raises: [ValueError].} =
  ## Resumes parsing from a checkpoint. ``s`` must deliver the original
  ## input from byte ``cp.offset`` on, e.g. after ``s.setPosition(cp.offset)``
  ## on a file stream. Raises ``ValueError`` if the checkpoint is corrupted,
  ## invalid or was created by a different checkpoint format version.
  ##
  ## Parser settings (e.g. ``issueWarnings``) are taken from ``p``, not from
  ## the checkpoint.
  if not cp.started:
    raise newException(ValueError, "checkpoint of an unstarted feed parser; " &
        "use newYamlFeedParser to resume it")
  let ctx = p.resumeContext(cp)
  ctx.lex.restore(cp.lexer, s, p.budget)
  result = ctx

proc resume*(p: YamlParser, cp: YamlCheckpoint, s: string): YamlStream
    {.raises: [ValueError].} =
  ## Resumes parsing from a checkpoint. ``s`` must be the original input
  ## from byte ``cp.offset`` on, e.g. ``input[cp.offset .. ^1]``. Raises
  ## ``ValueError`` like the `Stream` variant, and if ``s`` is shorter than
  ## the input the checkpoint has already read.
  if not cp.started:
    raise newException(ValueError, "checkpoint of an unstarted feed parser; " &
        "use newYamlFeedParser to resume it")
  if cp.lexer.bufpos > s.len + 1:
    raise newException(ValueError, "input is shorter than the input the " &
        "checkpoint has already read; it must start at offset " & $cp.offset)
  let ctx = p.resumeContext(cp)
  ctx.lex.restore(cp.lexer, s)
  result = ctx

proc newYamlFeedParser*(p: YamlParser, cp: YamlCheckpoint): YamlFeedParser
    {.raises: [ValueError].} =
  ## Resumes parsing from a checkpoint as feed parser. Feed the original
  ## input from byte ``cp.offset`` on.
  let ctx = p.resumeContext(cp)
  if cp.started: ctx.lex.restoreFeed(cp.lexer, p.budget)
  else: ctx.lex.initFeed(budget = p.budget)
  result = YamlFeedParser(ctx: ctx, starvedAt: -1, started: cp.started,
                          ended: cp.ended)
  privateAccess(YamlStream)
  if ctx.peeked:
    ctx.peeked = false
    result.pending.add(move(ctx.cached))

# implementation

proc isEmpty(props: Properties): bool =
  result = props.anchor == yAnchorNone and
           props.tag == yTagQuestionMark

proc generateError(ctx: Context, message: string):
    ref YamlParserError {.raises: [], .} =
  result = (ref YamlParserError)(
    msg: message, parent: nil, mark: ctx.lex.curStartPos,
    lineContent: ctx.lex.currentLine())

proc safeNext(ctx: Context) =
  try:
    ctx.lex.next()
  except LexerError as e:
    raise (ref YamlParserError)(
      msg: e.msg, parent: e.parent, mark: Mark(line: e.line, column: e.column),
      lineContent: e.lineContent)

proc parseTag(ctx: Context): Tag =
  let handle = ctx.lex.fullLexeme()
  var uri = ctx.resolveHandle(handle)
  if uri == "":
    raise ctx.generateError("unknown handle: " & escape(handle))
  ctx.safeNext()
  if ctx.lex.cur != Token.Suffix:
    raise ctx.generateError("unexpected token (expected tag suffix): " & $ctx.lex.cur)
  uri.add(ctx.lex.evaluated)
  return Tag(uri)

proc toStyle(t: Token): ScalarStyle =
  return (case t
    of Plain: ssPlain
    of SingleQuoted: ssSingleQuoted
    of DoubleQuoted: ssDoubleQuoted
    of Literal: ssLiteral
    of Folded: ssFolded
    else: ssAny)

proc mergeProps(ctx: Context, src, target: var Properties) =
  if src.tag != yTagQuestionMark:
    if target.tag != yTagQuestionMark:
      raise ctx.generateError("Only one tag allowed per node")
    target.tag = src.tag
    src.tag = yTagQuestionMark
  if src.anchor != yAnchorNone:
    if target.anchor != yAnchorNone:
      raise ctx.generateError("Only one anchor allowed per node")
    target.anchor = src.anchor
    src.anchor = yAnchorNone

proc autoScalarTag(props: Properties, t: Token): Properties =
  result = props
  if t in {Token.SingleQuoted, Token.DoubleQuoted} and
      props.tag == yTagQuestionMark:
    result.tag = yTagExclamationMark

proc atStreamStart(ctx: Context, e: var Event): bool =
  ctx.transition(atStreamEnd)
  ctx.pushLevel(beforeDoc, -1)
  e = Event(startPos: ctx.lex.curStartPos, endPos: ctx.lex.curStartPos, kind: yamlStartStream)
  ctx.safeNext()
  resetHandles(ctx.handles)
  return true

proc atStreamEnd(ctx: Context, e : var Event): bool =
  e = Event(startPos: ctx.lex.curStartPos,
            endPos: ctx.lex.curStartPos, kind: yamlEndStream)
  return true

# Directives
#
# A document's directive block is read by `beforeDoc`, one directive per
# line. YAML 1.2 knows ``%YAML`` and ``%TAG``; everything else is a reserved
# directive, to be ignored with a warning (§6.8). With directive extensions
# enabled, NimYAML also gives meaning to two names that would otherwise be
# reserved:
#
# * ``%SCHEMA <uri-reference>...`` names the JSON Schemas of the document,
#   resolved against the source URI of the stream; the document is to be
#   valid against all of them. Each reference becomes a directive of its own.
# * ``%GLOBAL <directive>`` wraps a ``YAML``, ``TAG`` or ``SCHEMA`` directive
#   and makes it apply to every document of the stream. It may only appear
#   in the directive block of the first document. A document's own
#   directives override the global ones for that document.
#
# Misusing these directives never makes the input invalid YAML, because
# every such line is a valid reserved directive. The offending directive is
# ignored instead and a `DirectiveIssue` recorded, which travels with the
# document's ``yamlStartDoc`` event. Syntax errors in the parameters of a
# wrapped directive are the errors that directive would raise on its own
# line, since the lexer lexes them the same way.
#
# The readers below each consume one directive's tokens. They are shared by
# a directive on its own line and the same directive wrapped by ``%GLOBAL``,
# so both are checked identically.

type DirectiveParameter = tuple[value: string, startPos, endPos: Mark]

proc issue(issues: var seq[DirectiveIssue], kind: DirectiveIssueKind,
    startPos, endPos: Mark, message: string) =
  ## Records why a directive is ignored.
  issues.add(DirectiveIssue(kind: kind, message: message,
      startPos: startPos, endPos: endPos))

proc readParameters(ctx: Context): seq[DirectiveParameter] =
  ## Consumes the parameters of a ``%SCHEMA`` or reserved directive; the
  ## current token is the directive itself.
  ctx.safeNext()
  while ctx.lex.cur == Token.DirectiveParam:
    result.add((ctx.lex.fullLexeme(), ctx.lex.curStartPos, ctx.lex.curEndPos))
    ctx.safeNext()

proc readYamlDirective(ctx: Context, origin: DirectiveOrigin,
    start: Mark): Directive =
  ## Reads ``%YAML <version>``; the lexer has already checked the version's
  ## syntax.
  ctx.safeNext()
  if ctx.lex.cur != Token.DirectiveParam:
    raise ctx.generateError("Invalid token (expected YAML version string): " & $ctx.lex.cur)
  result = Directive(kind: dkYaml, origin: origin, version: ctx.lex.fullLexeme(),
      startPos: start, endPos: ctx.lex.curEndPos,
      valueStart: ctx.lex.curStartPos, valueEnd: ctx.lex.curEndPos)
  ctx.safeNext()

proc readTagDirective(ctx: Context, origin: DirectiveOrigin,
    start: Mark, earlier: seq[Directive] = @[]): Directive =
  ## Reads ``%TAG <handle> <prefix>``. YAML 1.2 (§6.8.2) makes a second
  ## ``%TAG`` for the same handle in one document an error, even with the
  ## same prefix; ``earlier`` are the document's directives so far. (A
  ## document's ``%TAG`` may override a global one: those are not passed.)
  ctx.safeNext()
  if ctx.lex.cur != Token.TagHandle:
    raise ctx.generateError("Invalid token (expected tag handle): " & $ctx.lex.cur)
  let handle = ctx.lex.fullLexeme()
  for d in earlier:
    if d.kind == dkTag and d.handle == handle:
      raise ctx.generateError("Duplicate %TAG for handle " & handle &
          " (first declared in line " & $d.startPos.line & ")")
  ctx.safeNext()
  if ctx.lex.cur != Token.Suffix:
    raise ctx.generateError("Invalid token (expected tag URI): " & $ctx.lex.cur)
  result = Directive(kind: dkTag, origin: origin, handle: handle,
      prefix: ctx.lex.evaluated, startPos: start, endPos: ctx.lex.curEndPos,
      valueStart: ctx.lex.curStartPos, valueEnd: ctx.lex.curEndPos)
  ctx.safeNext()

proc readSchemaDirective(ctx: Context, origin: DirectiveOrigin, start: Mark,
    issues: var seq[DirectiveIssue], directives: var seq[Directive]): Mark =
  ## Reads a ``%SCHEMA`` directive into one directive per schema that can be
  ## located, recording why for the others. Returns the end of the line.
  let directiveEnd = ctx.lex.curEndPos
  let params = ctx.readParameters()
  result = if params.len > 0: params[^1].endPos else: directiveEnd
  if params.len == 0:
    issues.issue(diInvalidSchema, start, result,
        "%SCHEMA expects at least one URI reference")
  for (reference, valueStart, valueEnd) in params:
    if not isUriReference(reference):
      issues.issue(diInvalidSchema, valueStart, valueEnd,
          escape(reference) & " is not a URI reference")
      continue
    var uri = reference
    if not reference.isAbsolute:
      if ctx.sourceUri.len == 0:
        issues.issue(diUnresolvableSchema, valueStart, valueEnd,
            "relative schema reference " & escape(reference) &
            " cannot be resolved: the input has no source URI")
        continue
      uri = resolve(ctx.sourceUri, reference)
    directives.add(Directive(kind: dkSchema, origin: origin,
        reference: reference, uri: uri, startPos: start, endPos: result,
        valueStart: valueStart, valueEnd: valueEnd))

proc skipRestOfLine(ctx: Context, line: int): Mark =
  ## Consumes the remaining tokens of directive line ``line``; returns the
  ## end of the last one.
  result = ctx.lex.curEndPos
  while ctx.lex.cur != Token.StreamEnd and ctx.lex.curStartPos.line == line:
    result = ctx.lex.curEndPos
    ctx.safeNext()

proc sameDeclaration(a, b: Directive): bool =
  ## Whether ``a`` and ``b`` set the same thing, so that one replaces the
  ## other: the version, the schema, or the prefix of the same tag handle.
  a.kind == b.kind and (a.kind != dkTag or a.handle == b.handle)

proc readGlobalDirective(ctx: Context, issues: var seq[DirectiveIssue],
    seenGlobalSchema: var bool) =
  ## Reads ``%GLOBAL <directive>``; the current token is ``%GLOBAL``.
  let
    start = ctx.lex.curStartPos
    line = start.line
    firstDocument = ctx.documentsBegun == 1
  ctx.safeNext()
  let wrapped = ctx.lex.cur
  if ctx.lex.curStartPos.line != line or wrapped notin {Token.YamlDirective,
      Token.TagDirective, Token.SchemaDirective, Token.GlobalDirective,
      Token.UnknownDirective}:
    issues.issue(diMissingGlobal, start, Mark(line: line,
        column: start.column + "%GLOBAL".len), "%GLOBAL needs a directive")
    return
  var
    declared: seq[Directive]
    stop: Mark
  case wrapped
  of Token.YamlDirective: declared.add(ctx.readYamlDirective(doGlobal, start))
  of Token.TagDirective: declared.add(ctx.readTagDirective(doGlobal, start))
  of Token.SchemaDirective:
    if not firstDocument:
      # still read, so that it is checked like everywhere else
      var ignored: seq[DirectiveIssue]
      stop = ctx.readSchemaDirective(doGlobal, start, ignored, declared)
    else:
      let duplicate = seenGlobalSchema
      seenGlobalSchema = true
      stop = ctx.readSchemaDirective(doGlobal, start, issues, declared)
      if declared.len == 0: return
      if duplicate:
        issues.issue(diDuplicateGlobal, start, stop,
            "a global %SCHEMA has already been declared")
        return
  of Token.GlobalDirective:
    let stop = ctx.skipRestOfLine(line)
    issues.issue(diNestedGlobal, start, stop, "%GLOBAL cannot wrap %GLOBAL")
    return
  else:
    let name = ctx.lex.evaluated
    let stop = ctx.skipRestOfLine(line)
    issues.issue(diUnknownGlobal, start, stop, "%GLOBAL " & name &
        " is ignored: only YAML, TAG and SCHEMA can be global")
    return
  if wrapped != Token.SchemaDirective: stop = declared[0].endPos
  if not firstDocument:
    issues.issue(diMisplacedGlobal, start, stop,
        "%GLOBAL is only allowed before the first document")
    return
  if wrapped != Token.SchemaDirective:
    let d = declared[0]
    for existing in ctx.globals:
      if existing.sameDeclaration(d):
        issues.issue(diDuplicateGlobal, start, d.endPos,
            "a global %" & $d.kind &
            (if d.kind == dkTag: " for " & d.handle else: "") &
            " has already been declared")
        return
  ctx.globals.add(declared)

proc effectiveDirectives(ctx: Context, own: seq[Directive],
    issues: seq[DirectiveIssue], version: var string): DocumentDirectives =
  ## Overlays the document's own directives on the global ones: sets the
  ## effective tag handles in ``ctx.handles`` and ``version``, and returns
  ## the record for the ``yamlStartDoc`` event (nil if there is nothing to
  ## record).
  resetHandles(ctx.handles)
  version = ""
  for d in ctx.globals & own:
    case d.kind
    of dkYaml: version = d.version
    of dkTag: discard registerHandle(ctx.handles, d.handle, d.prefix)
    of dkSchema: discard
  if ctx.globals.len == 0 and own.len == 0 and issues.len == 0: return nil
  result = DocumentDirectives(issues: issues)
  for g in ctx.globals:
    var declaration = g
    for d in own:
      if d.sameDeclaration(g): declaration.overridden = true
    result.declarations.add(declaration)
  result.declarations.add(own)
  let schemas = result.schemas
  if schemas.len > 0: result.schema = schemas[0]

proc beforeDoc(ctx: Context, e: var Event): bool =
  var
    own: seq[Directive]
    issues: seq[DirectiveIssue]
    seenDirectives, seenYaml, seenSchema, seenGlobalSchema = false
    start = YamlDocumentStart(offset: -1)
  template startDocument(explicit: bool) =
    ctx.inDirectiveBlock = false
    var version: string
    let directives = ctx.effectiveDirectives(own, issues, version)
    e = startDocEvent(explicit, version, ctx.handles, ctx.lex.curStartPos,
        ctx.lex.curEndPos, directives)
  while true:
    if start.offset < 0 and ctx.lex.cur notin {DocumentEnd, StreamEnd}:
      # the first token of the document; the lexer is still on its line
      inc(ctx.documentsBegun)
      start = YamlDocumentStart(offset: ctx.lex.lineOffset(),
                                line: ctx.lex.currentLineNumber(),
                                index: ctx.documentsBegun - 1)
      if start.index > 0: start.globals = ctx.globals
      # set right away, so that error recovery knows the start of a
      # document that fails before its yamlStartDoc
      ctx.documentStart = start
      ctx.documentMarker = start.offset
      ctx.inDirectiveBlock = ctx.lex.cur in {YamlDirective, TagDirective,
          SchemaDirective, GlobalDirective, UnknownDirective}
    case ctx.lex.cur
    of DocumentEnd:
      if seenDirectives:
        raise ctx.generateError("Missing `---` after directives")
      ctx.safeNext()
    of DirectivesEnd:
      ctx.documentMarker = ctx.lex.lineOffset()
      startDocument(true)
      ctx.safeNext()
      ctx.transition(beforeDocEnd)
      ctx.pushLevel(afterDirectivesEnd, -1)
      return true
    of StreamEnd:
      if seenDirectives:
        raise ctx.generateError("Missing `---` after directives")
      ctx.popLevel()
      return false
    of Indentation:
      startDocument(false)
      ctx.transition(beforeDocEnd)
      ctx.pushLevel(beforeImplicitRoot, -1)
      return true
    of YamlDirective:
      seenDirectives = true
      if seenYaml: raise ctx.generateError("Duplicate %YAML")
      seenYaml = true
      own.add(ctx.readYamlDirective(doDocument, ctx.lex.curStartPos))
      if own[^1].version != "1.2" and ctx.issueWarnings:
        discard # TODO
    of TagDirective:
      seenDirectives = true
      own.add(ctx.readTagDirective(doDocument, ctx.lex.curStartPos, own))
    of SchemaDirective:
      seenDirectives = true
      let
        start = ctx.lex.curStartPos
        duplicate = seenSchema
      seenSchema = true
      var declared: seq[Directive]
      let stop = ctx.readSchemaDirective(doDocument, start, issues, declared)
      if declared.len > 0:
        if duplicate:
          issues.issue(diDuplicateSchema, start, stop,
              "a document can have only one %SCHEMA")
        else: own.add(declared)
    of GlobalDirective:
      seenDirectives = true
      ctx.readGlobalDirective(issues, seenGlobalSchema)
    of UnknownDirective:
      seenDirectives = true
      let
        start = ctx.lex.curStartPos
        name = ctx.lex.evaluated
        params = ctx.readParameters()
      issues.issue(diUnknownDirective, start,
          if params.len > 0: params[^1].endPos else: Mark(line: start.line,
              column: start.column + 1 + name.len),
          "unknown directive %" & name & " is ignored")
    else:
      raise ctx.generateError("Unexpected token (expected directive or document start): " & $ctx.lex.cur)

proc afterDirectivesEnd(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.inlineStart = ctx.lex.curStartPos
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Indentation:
    # without node properties on the `---` line, the root node starts at the
    # first content character of the next line, like in beforeImplicitRoot
    # (inlineStart would otherwise be left over from the previous document).
    # (properties on that line have been merged into headerProps by now)
    if ctx.inlineProps.isEmpty() and ctx.headerProps.isEmpty():
      ctx.inlineStart = ctx.lex.curEndPos
    ctx.headerStart = ctx.inlineStart
    ctx.transition(atBlockIndentation)
    ctx.pushLevel(beforeBlockIndentation)
    return false
  of DocumentEnd, DirectivesEnd, StreamEnd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    # the properties belong to this root node only; left in place, they
    # would be applied to the root of the next document
    ctx.inlineProps = defaultProperties
    ctx.popLevel()
    return true
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.popLevel()
    ctx.safeNext()
    return true
  of Alias:
    # `--- *a`: whether the anchor exists is not a question of syntax (it
    # never does across documents; lint's undefined-alias reports it)
    if not ctx.inlineProps.isEmpty():
      raise ctx.generateError("Alias may not have node properties")
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.lex.curStartPos,
        ctx.lex.curEndPos)
    ctx.popLevel()
    ctx.safeNext()
    return true
  of MapStart, SeqStart:
    # a flow collection on the `---` line (`--- {a: b}`, YAML 1.2
    # example 9.4) is the root node; it is parsed like any flow node
    if ctx.inlineProps.isEmpty(): ctx.inlineStart = ctx.lex.curStartPos
    ctx.transition(beforeFlowItemProps)
    return false
  else:
    raise ctx.generateError("Illegal content at `---`: " & $ctx.lex.cur)

proc beforeImplicitRoot(ctx: Context, e: var Event): bool =
  if ctx.lex.cur != Token.Indentation:
    raise ctx.generateError("Unexpected token (expected line start): " & $ctx.lex.cur)
  ctx.inlineStart = ctx.lex.curEndPos
  ctx.headerStart = ctx.lex.curEndPos
  ctx.updateIndentation(ctx.lex.recentIndentation())
  ctx.safeNext()
  case ctx.lex.cur
  of SeqItemInd, MapKeyInd, MapValueInd:
    ctx.transition(afterCompactParent)
    return false
  of scalarTokenKind, MapStart, SeqStart:
    ctx.transition(atBlockIndentationProps)
    return false
  of nodePropertyKind:
    ctx.transition(atBlockIndentationProps)
    ctx.pushLevel(beforeNodeProperties)
  else:
    raise ctx.generateError("Unexpected token (expected collection start): " & $ctx.lex.cur)

proc atBlockIndentation(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation == ctx.levels[^1].indentation and
      (ctx.lex.cur != Token.SeqItemInd or
       ctx.levels[^3].state == inBlockSeq):
    e = scalarEvent("", ctx.headerProps, ssPlain,
                    ctx.headerStart, ctx.headerStart)
    ctx.headerProps = defaultProperties
    ctx.popLevel()
    ctx.popLevel()
    return true
  ctx.inlineStart = ctx.lex.curStartPos
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of nodePropertyKind:
    if isEmpty(ctx.headerProps):
      ctx.transition(mergePropsOnNewline)
    else:
      ctx.transition(atBlockIndentationProps)
    ctx.pushLevel(beforeNodeProperties)
    return false
  of SeqItemInd:
    e = startSeqEvent(csBlock, ctx.headerProps,
                      ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(inBlockSeq, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation())
    ctx.safeNext()
    return true
  of MapKeyInd:
    e = startMapEvent(csBlock, ctx.headerProps,
                      ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(beforeBlockMapValue, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation())
    ctx.safeNext()
    return true
  of Plain, SingleQuoted, DoubleQuoted:
    ctx.updateIndentation(ctx.lex.recentIndentation())
    let scalarToken = ctx.lex.cur
    e = scalarEvent(ctx.lex.evaluated, ctx.headerProps,
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      if ctx.lex.lastScalarWasMultiline():
        raise ctx.generateError("Implicit mapping key may not be multiline")
      let props = e.scalarProperties
      e.scalarProperties = autoScalarTag(defaultProperties, scalarToken)
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, props, ctx.headerStart, headerEnd)
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      e.scalarProperties = autoScalarTag(e.scalarProperties, scalarToken)
      ctx.popLevel()
    return true
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, headerEnd)
      ctx.headerProps = defaultProperties
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    elif not isEmpty(ctx.headerProps):
      raise ctx.generateError("Alias may not have properties")
    else:
      ctx.popLevel()
    return true
  else:
    ctx.transition(atBlockIndentationProps)
    return false

proc atBlockIndentationProps(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of MapValueInd:
    ctx.keyCache.add(scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curEndPos))
    ctx.inlineProps = defaultProperties
    e = startMapEvent(csBlock, ctx.headerProps, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(afterImplicitKey)
    ctx.pushLevel(emitCached)
    return true
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      if ctx.lex.lastScalarWasMultiline():
        raise ctx.generateError("Implicit mapping key may not be multiline")
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, headerEnd)
      ctx.headerProps = defaultProperties
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      ctx.mergeProps(ctx.headerProps, e.scalarProperties)
      ctx.popLevel()
    return true
  of MapStart, SeqStart:
    let
      startPos = ctx.lex.curStartPos
      indent = ctx.lex.currentIndentation()
      levelDepth = ctx.levels.len
    ctx.transition(beforeFlowItemProps)
    ctx.caching = true
    while ctx.levels.len >= levelDepth:
      ctx.keyCache.add(ctx.next())
    ctx.caching = false
    if ctx.lex.cur == Token.MapValueInd:
      ctx.pushLevel(afterImplicitKey, indent)
      ctx.pushLevel(emitCached)
      if ctx.lex.curStartPos.line != startPos.line:
        raise ctx.generateError("Implicit mapping key may not be multiline")
      e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, startPos)
      ctx.headerProps = defaultProperties
      return true
    else:
      ctx.pushLevel(emitCached)
      return false
  of Literal, Folded:
    ctx.mergeProps(ctx.inlineProps, ctx.headerProps)
    e = scalarEvent(ctx.lex.evaluated, ctx.headerProps, toStyle(ctx.lex.cur),
                    ctx.inlineStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.safeNext()
    ctx.popLevel()
    return true
  of Indentation:
    ctx.safeNext()
    ctx.transition(atBlockIndentation)
    return false
  of StreamEnd, DocumentEnd, DirectivesEnd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curStartPos)
    ctx.inlineProps = defaultProperties
    ctx.popLevel()
    return true
  else:
    raise ctx.generateError("Unexpected token (expected block content): " & $ctx.lex.cur)

proc beforeNodeProperties(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of TagHandle:
    if ctx.inlineProps.tag != yTagQuestionMark:
      raise ctx.generateError("Only one tag allowed per node")
    ctx.inlineProps.tag = ctx.parseTag()
  of VerbatimTag:
    if ctx.inlineProps.tag != yTagQuestionMark:
      raise ctx.generateError("Only one tag allowed per node")
    ctx.inlineProps.tag = Tag(move(ctx.lex.evaluated))
  of Token.Anchor:
    if ctx.inlineProps.anchor != yAnchorNone:
      raise ctx.generateError("Only one anchor allowed per node")
    ctx.inlineProps.anchor = ctx.lex.shortLexeme().Anchor
  of Indentation:
    ctx.mergeProps(ctx.inlineProps, ctx.headerProps)
    ctx.popLevel()
    return false
  of Alias:
    raise ctx.generateError("Alias may not have node properties")
  else:
    ctx.popLevel()
    return false
  ctx.safeNext()
  return false

proc afterCompactParent(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.transition(afterCompactParentProps)
    ctx.pushLevel(beforeNodeProperties)
  of SeqItemInd:
    e = startSeqEvent(csBlock, ctx.headerProps, ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(inBlockSeq, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation())
    ctx.safeNext()
    return true
  of MapKeyInd:
    e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(beforeBlockMapValue, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation)
    ctx.safeNext()
    return true
  else:
    ctx.transition(afterCompactParentProps)
    return false

proc afterCompactParentProps(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Indentation:
    ctx.headerStart = ctx.inlineStart
    ctx.transition(atBlockIndentation, ctx.levels[^3].indentation)
    ctx.pushLevel(beforeBlockIndentation)
    return false
  of MapValueInd:
    ctx.keyCache.add(scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curStartPos))
    ctx.inlineProps = defaultProperties
    e = startMapEvent(csBlock, defaultProperties, ctx.lex.curStartPos, ctx.lex.curStartPos)
    ctx.transition(afterImplicitKey)
    ctx.pushLevel(emitCached)
    return true
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, defaultProperties, headerEnd, headerEnd)
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      ctx.popLevel()
    return true
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.updateIndentation(ctx.lex.recentIndentation())
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      if ctx.lex.lastScalarWasMultiline():
        raise ctx.generateError("Implicit mapping key may not be multiline")
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, defaultProperties, headerEnd, headerEnd)
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      ctx.popLevel()
    return true
  of MapStart, SeqStart, StreamEnd, DocumentEnd, DirectivesEnd:
    ctx.transition(atBlockIndentationProps)
    return false
  else:
    raise ctx.generateError("Unexpected token (expected newline or flow item start: " & $ctx.lex.cur)

proc afterBlockParent(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.transition(afterBlockParentProps)
    ctx.pushLevel(beforeNodeProperties)
  of SeqItemInd, MapKeyInd:
    raise ctx.generateError("Compact notation not allowed after implicit key")
  else:
    ctx.transition(afterBlockParentProps)
  return false

proc afterBlockParentProps(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
    return false
  of MapValueInd:
    raise ctx.generateError("Compact notation not allowed after implicit key")
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      raise ctx.generateError("Compact notation not allowed after implicit key")
    ctx.popLevel()
    return true
  else:
    ctx.transition(afterCompactParentProps)
    return false

proc mergePropsOnNewline(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  if ctx.lex.cur == Token.Indentation:
    ctx.mergeProps(ctx.inlineProps, ctx.headerProps)
  ctx.transition(afterCompactParentProps)
  return false

proc beforeDocEnd(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of DocumentEnd:
    e = endDocEvent(true, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(beforeDoc)
    ctx.safeNext()
    resetHandles(ctx.handles)
  of StreamEnd:
    e = endDocEvent(false, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.popLevel()
  of DirectivesEnd:
    e = endDocEvent(false, ctx.lex.curStartPos, ctx.lex.curStartPos)
    ctx.transition(beforeDoc)
    resetHandles(ctx.handles)
  else:
    raise ctx.generateError("Unexpected token (expected document end): " & $ctx.lex.cur)
  return true

proc inBlockSeq(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation > ctx.levels[^1].indentation:
    raise ctx.generateError("Invalid indentation: got " & $ctx.blockIndentation & ", expected " & $ctx.levels[^1].indentation)
  case ctx.lex.cur
  of SeqItemInd:
    ctx.safeNext()
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.blockIndentation)
    return false
  else:
    if ctx.levels[^3].indentation == ctx.levels[^1].indentation:
      e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
      ctx.popLevel()
      ctx.popLevel()
      return true
    else:
      raise ctx.generateError("Illegal token (expected block sequence indicator): " & $ctx.lex.cur)

proc beforeBlockMapKey(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation > ctx.levels[^1].indentation:
    raise ctx.generateError("Invalid indentation: got " & $ctx.blockIndentation & ", expected " & $ctx.levels[^1].indentation)
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of MapKeyInd:
    ctx.transition(beforeBlockMapValue)
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.blockIndentation)
    ctx.safeNext()
    return false
  of nodePropertyKind:
    ctx.transition(atBlockMapKeyProps)
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Plain, SingleQuoted, DoubleQuoted:
    ctx.transition(atBlockMapKeyProps)
    return false
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.transition(afterImplicitKey)
    return true
  of MapValueInd:
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(beforeBlockMapValue)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected mapping key): " & $ctx.lex.cur)

proc atBlockMapKeyProps(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    if ctx.lex.lastScalarWasMultiline():
      raise ctx.generateError("Implicit mapping key may not be multiline")
  of MapValueInd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curStartPos)
    ctx.inlineProps = defaultProperties
    ctx.transition(afterImplicitKey)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected implicit mapping key): " & $ctx.lex.cur)
  ctx.safeNext()
  ctx.transition(afterImplicitKey)
  return true

proc afterImplicitKey(ctx: Context, e: var Event): bool =
  if ctx.lex.cur != Token.MapValueInd:
    raise ctx.generateError("Unexpected token (expected ':'): " & $ctx.lex.cur)
  ctx.safeNext()
  ctx.transition(beforeBlockMapKey)
  ctx.pushLevel(beforeBlockIndentation)
  ctx.pushLevel(afterBlockParent, max(0, ctx.levels[^2].indentation))
  return false

proc beforeBlockMapValue(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation > ctx.levels[^1].indentation:
    raise ctx.generateError("Invalid indentation")
  case ctx.lex.cur
  of MapValueInd:
    ctx.transition(beforeBlockMapKey)
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.blockIndentation)
    ctx.safeNext()
  of MapKeyInd, Plain, SingleQuoted, DoubleQuoted, nodePropertyKind:
    # the value is allowed to be missing after an explicit key
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(beforeBlockMapKey)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected mapping value): " & $ctx.lex.cur)

proc beforeBlockIndentation(ctx: Context, e: var Event): bool =
  proc endBlockNode(e: var Event) =
    if ctx.levels[^1].state == beforeBlockMapKey:
      e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    elif ctx.levels[^1].state == beforeBlockMapValue:
      e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
      ctx.transition(beforeBlockMapKey)
      ctx.pushLevel(beforeBlockIndentation)
      return
    elif ctx.levels[^1].state == inBlockSeq:
      e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    elif ctx.levels[^1].state == atBlockIndentation:
      e = scalarEvent("", ctx.headerProps, ssPlain, ctx.headerStart, ctx.headerStart)
      ctx.headerProps = defaultProperties
    elif ctx.levels[^1].state == beforeBlockIndentation:
      raise ctx.generateError("Unexpected double beforeBlockIndentation")
    else:
      raise ctx.generateError("Internal error (please report this bug): unexpected state at endBlockNode")
    ctx.popLevel()
  ctx.popLevel()
  case ctx.lex.cur
  of Indentation:
    ctx.blockIndentation = ctx.lex.currentIndentation()
    if ctx.blockIndentation < ctx.levels[^1].indentation:
      endBlockNode(e)
      return true
    else:
      ctx.safeNext()
      return false
  of StreamEnd, DocumentEnd, DirectivesEnd:
    ctx.blockIndentation = 0
    if ctx.levels[^1].state != beforeDocEnd:
      endBlockNode(e)
      return true
    else:
      return false
  else:
    raise ctx.generateError("Unexpected content after node in block context (expected newline): " & $ctx.lex.cur)

proc beforeFlowItem(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.transition(beforeFlowItemProps)
    ctx.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  else:
    ctx.transition(beforeFlowItemProps)
  return false

proc beforeFlowItemProps(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.safeNext()
    ctx.popLevel()
  of MapStart:
    e = startMapEvent(csFlow, ctx.inlineProps, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.transition(afterFlowMapSep)
    ctx.safeNext()
  of SeqStart:
    e = startSeqEvent(csFlow, ctx.inlineProps, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.transition(afterFlowSeqSep)
    ctx.safeNext()
  of MapEnd, SeqEnd, SeqSep, MapValueInd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.popLevel()
  else:
    raise ctx.generateError("Unexpected token (expected flow node): " & $ctx.lex.cur)
  ctx.inlineProps = defaultProperties
  return true

proc afterFlowMapKey(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of MapValueInd:
    ctx.transition(afterFlowMapValue)
    ctx.pushLevel(beforeFlowItem)
    ctx.safeNext()
    return false
  of SeqSep, MapEnd:
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(afterFlowMapValue)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected ':'): " & $ctx.lex.cur)

proc afterFlowMapValue(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of SeqSep:
    ctx.transition(afterFlowMapSep)
    ctx.safeNext()
    return false
  of MapEnd:
    e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  of Plain, SingleQuoted, DoubleQuoted, MapKeyInd, Token.Anchor, Alias, MapStart, SeqStart:
    raise ctx.generateError("Missing ','")
  else:
    raise ctx.generateError("Unexpected token (expected ',' or '}'): " & $ctx.lex.cur)

proc afterFlowSeqItem(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of SeqSep:
    ctx.transition(afterFlowSeqSep)
    ctx.safeNext()
    return false
  of SeqEnd:
    e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  of Plain, SingleQuoted, DoubleQuoted, MapKeyInd, Token.Anchor, Alias, MapStart, SeqStart:
    raise ctx.generateError("Missing ','")
  else:
    raise ctx.generateError("Unexpected token (expected ',' or ']'): " & $ctx.lex.cur)

proc afterFlowMapSep(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of MapKeyInd:
    ctx.safeNext()
  of MapEnd:
    e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  of SeqSep:
    raise ctx.generateError("Missing mapping entry between commas (use '?' for an empty mapping entry)")
  else: discard
  ctx.transition(afterFlowMapKey)
  ctx.pushLevel(beforeFlowItem)
  return false

proc afterFlowSeqSep(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of SeqSep:
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curStartPos)
    ctx.safeNext()
    return true
  of nodePropertyKind:
    ctx.transition(afterFlowSeqSepProps)
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Plain, SingleQuoted, DoubleQuoted, MapStart, SeqStart:
    ctx.transition(afterFlowSeqSepProps)
    return false
  of MapKeyInd:
    ctx.transition(afterFlowSeqSepProps)
    e = startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.transition(afterFlowSeqItem)
    ctx.pushLevel(beforePairValue)
    ctx.pushLevel(beforeFlowItem)
    return true
  of MapValueInd:
    ctx.transition(afterFlowSeqItem)
    e = startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.pushLevel(atEmptyPairKey)
    return true
  of SeqEnd:
    e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  else:
    ctx.transition(afterFlowSeqItem)
    ctx.pushLevel(beforeFlowItem)
    return false

proc afterFlowSeqSepProps(ctx: Context, e: var Event): bool =
  # here we handle potential implicit single pairs within flow sequences.
  ctx.transition(afterFlowSeqItem)
  case ctx.lex.cur
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      ctx.pushLevel(afterImplicitPairStart)
      if ctx.caching:
        ctx.keyCache.add(startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curStartPos))
      else:
        ctx.keyCache.add(move(e))
        e = startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curStartPos)
        ctx.pushLevel(emitCached)
    return true
  of MapStart, SeqStart:
    let
      startPos = ctx.lex.curStartPos
      indent = ctx.levels[^1].indentation
      cacheStart = ctx.keyCache.len
      levelDepth = ctx.levels.len
      alreadyCaching = ctx.caching
    ctx.pushLevel(beforeFlowItemProps)
    ctx.caching = true
    while ctx.levels.len > levelDepth:
      ctx.keyCache.add(ctx.next())
    ctx.caching = alreadyCaching
    if ctx.lex.cur == Token.MapValueInd:
      ctx.pushLevel(afterImplicitPairStart, indent)
      if ctx.lex.curStartPos.line != startPos.line:
        raise ctx.generateError("Implicit mapping key may not be multiline")
      if not alreadyCaching:
        ctx.pushLevel(emitCached)
        e = startMapEvent(csPair, defaultProperties, startPos, startPos)
        return true
      else:
        # we are already filling a cache.
        # so we just squeeze the map start in.
        ctx.keyCache.insert(startMapEvent(csPair, defaultProperties, startPos, startPos), cacheStart)
        return false
    else:
      if not alreadyCaching:
        ctx.pushLevel(emitCached)
      return false
  else:
    ctx.pushLevel(beforeFlowItem)
    return false

proc atEmptyPairKey(ctx: Context, e: var Event): bool =
  ctx.transition(beforePairValue)
  e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curStartPos)
  return true

proc beforePairValue(ctx: Context, e: var Event): bool =
  if ctx.lex.cur == Token.MapValueInd:
    ctx.transition(afterPairValue)
    ctx.pushLevel(beforeFlowItem)
    ctx.safeNext()
    return false
  else:
    # pair ends here without value
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.popLevel()
    return true

proc afterImplicitPairStart(ctx: Context, e: var Event): bool =
  ctx.safeNext()
  ctx.transition(afterPairValue)
  ctx.pushLevel(beforeFlowItem)
  return false

proc afterPairValue(ctx: Context, e: var Event): bool =
  e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
  ctx.popLevel()
  return true

proc emitCached(ctx: Context, e: var Event): bool =
  debug("emitCollection key: pos = " & $ctx.keyCachePos & ", len = " & $ctx.keyCache.len)
  yAssert(ctx.keyCachePos < ctx.keyCache.len)
  e = move(ctx.keyCache[ctx.keyCachePos])
  inc(ctx.keyCachePos)
  if ctx.keyCachePos == len(ctx.keyCache):
    ctx.keyCache.setLen(0)
    ctx.keyCachePos = 0
    ctx.popLevel()
  return true

proc display*(p: YamlParser, event: Event): string =
  ## Generate a representation of the given event with proper visualization of
  ## anchor and tag (if any). The generated representation is conformant to the
  ## format used in the yaml test suite.
  ##
  ## This proc is an informed version of ``$`` on ``YamlStreamEvent`` which can
  ## properly display the anchor and tag name as it occurs in the input.
  ## However, it shall only be used while using the streaming API because after
  ## finishing the parsing of a document, the parser drops all information about
  ## anchor and tag names.
  case event.kind
  of yamlStartStream: result = "+STR"
  of yamlEndStream: result = "-STR"
  of yamlEndMap: result = "-MAP"
  of yamlEndSeq: result = "-SEQ"
  of yamlStartDoc:
    result = "+DOC"
    if event.explicitDirectivesEnd: result &= " ---"
  of yamlEndDoc:
    result = "-DOC"
    if event.explicitDocumentEnd: result &= " ..."
  of yamlStartMap:
    result = "+MAP" & renderAttrs(event.mapProperties, true)
  of yamlStartSeq:
    result = "+SEQ" & renderAttrs(event.seqProperties, true)
  of yamlScalar:
    result = "=VAL" & renderAttrs(event.scalarProperties,
                                  event.scalarStyle in {ssPlain, ssFolded, ssLiteral})
    case event.scalarStyle
    of ssPlain, ssAny: result &= " :"
    of ssSingleQuoted: result &= " \'"
    of ssDoubleQuoted: result &= " \""
    of ssLiteral: result &= " |"
    of ssFolded: result &= " >"
    result &= yamlTestSuiteEscape(event.scalarContent)
  of yamlAlias: result = "=ALI *" & $event.aliasTarget
# error recovery

proc toParserError(ctx: Context, ce: ref CatchableError): ref YamlParserError =
  if ce of YamlParserError: (ref YamlParserError)(ce)
  elif ce of YamlStreamError and ce.parent of YamlParserError:
    # raised by a nested ``next`` while caching a flow collection
    (ref YamlParserError)(ce.parent)
  else:
    (ref YamlParserError)(msg: ce.msg, parent: ce, mark: ctx.lex.curStartPos,
                          lineContent: ctx.lex.currentLine())

proc recover(rs: YamlRecoveringStream, ce: ref CatchableError)
    {.raises: [YamlParserError].} =
  ## records the error, drops the events of the failed document and continues
  ## at the next document, if any.
  let ctx = rs.ctx
  let pe = ctx.toParserError(ce)
  if ctx.lex.streamFailed(): raise pe # not a YAML error; cannot continue
  rs.buffer.setLen(0)
  rs.pos = 0
  if not rs.streamStarted:
    rs.buffer.add(Event(kind: yamlStartStream))
    rs.streamStarted = true
  var record = YamlDocumentError(error: pe,
                                 resumedAt: YamlDocumentStart(offset: -1))
  ctx.keyCache.setLen(0)
  ctx.keyCachePos = 0
  ctx.caching = false
  ctx.headerProps = defaultProperties
  ctx.inlineProps = defaultProperties
  ctx.blockIndentation = 0
  resetHandles(ctx.handles)
  privateAccess(YamlStream)
  ctx.failed = false
  ctx.peeked = false
  # continue after the start of the failed document, so that it is not
  # parsed again
  var resynced = ctx.lex.resync(max(rs.lastResync, ctx.documentMarker))
  if resynced and ctx.inDirectiveBlock and ctx.lex.atDirectivesEndLine():
    # the `---` that ends the failed directive block belongs to the failed
    # document; parsing from it would resurrect that document without its
    # directives
    resynced = ctx.lex.resync(ctx.lex.lineOffset())
  ctx.inDirectiveBlock = false
  if resynced:
    record.resumedAt = YamlDocumentStart(offset: ctx.lex.lineOffset(),
                                         line: ctx.lex.currentLineNumber(),
                                         index: ctx.documentsBegun,
                                         globals: ctx.globals)
    rs.lastResync = record.resumedAt.offset
    ctx.levels = @[Level(state: atStreamEnd, indentation: -2),
                   Level(state: beforeDoc, indentation: -1)]
    rs.needToken = true
  else:
    ctx.levels = @[Level(state: atStreamEnd, indentation: -2)]
    rs.needToken = false
  if ctx.lex.streamFailed(): raise pe
  rs.errors.add(record)

proc fill(rs: YamlRecoveringStream) {.raises: [YamlParserError].} =
  ## produces the events of the next complete document (or the start or end
  ## of the stream) into the buffer. May produce nothing after an error.
  rs.buffer.setLen(0)
  rs.pos = 0
  let ctx = rs.ctx
  try:
    if rs.needToken:
      rs.needToken = false
      ctx.safeNext()
    while true:
      var e: Event
      ctx.lex.compact()
      while not ctx.levels[^1].state(ctx, e): discard
      let kind = e.kind
      rs.buffer.add(move(e))
      case kind
      of yamlStartStream:
        rs.streamStarted = true
        return
      of yamlEndDoc, yamlEndStream: return
      else: discard
  except CatchableError as ce:
    rs.recover(ce)

proc parseRecovering(p: YamlParser, ctx: Context): YamlRecoveringStream =
  result = YamlRecoveringStream(ctx: ctx, lastResync: -1)
  result.basicInit(proc(s: YamlStream, lineContent: var string): bool
      {.gcsafe, raises: [], closure.} =
    lineContent = YamlRecoveringStream(s).ctx.lex.currentLine()
    return true)
  result.nextImpl = proc(s: YamlStream, e: var Event): bool
      {.raises: [CatchableError], gcsafe, closure.} =
    let rs = YamlRecoveringStream(s)
    while rs.pos >= rs.buffer.len: rs.fill()
    e = move(rs.buffer[rs.pos])
    inc(rs.pos)
    return true

proc parseRecovering*(p: YamlParser, s: string): YamlRecoveringStream =
  ## Parses ``s`` like `parse`, but recovers from errors: when a document
  ## turns out to be invalid, the error is recorded (see `errors`), the
  ## document is dropped and parsing continues at the next document, i.e.
  ## at the next line starting with a `---` marker or after the next line
  ## starting with a `...` marker.
  ##
  ## The stream only yields documents that have been parsed completely, so it
  ## stays well-formed. To be able to drop a document, it buffers the events
  ## of the document being parsed: memory use is proportional to the largest
  ## document, not to the largest event. Only errors in the YAML input are
  ## recovered from; an error of the input stream is raised.
  let ctx = new(Context)
  ctx.init(p, s)
  result = parseRecovering(p, ctx)

proc parseRecovering*(p: YamlParser, s: Stream): YamlRecoveringStream =
  ## Like the `string` variant.
  let ctx = new(Context)
  try: ctx.init(p, s)
  except IOError, OSError: discard # reported by the first ``next``
  result = parseRecovering(p, ctx)

proc errors*(s: YamlRecoveringStream): lent seq[YamlDocumentError] =
  ## The errors recovered from so far, in input order.
  s.errors
