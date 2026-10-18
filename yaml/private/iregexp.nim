#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## I-Regexp: interoperable regular expressions as defined by
## `RFC 9485 <https://www.rfc-editor.org/rfc/rfc9485>`_.
##
## JSONPath's ``match()`` and ``search()`` functions take their patterns in
## this dialect. It is a deliberately small subset of XSD regular
## expressions: alternation, grouping, the quantifiers ``* + ? {n,m}``, ``.``,
## bracketed character classes and Unicode General Category escapes
## (``\p{Lu}``). There are no anchors, back-references, lazy quantifiers or
## lookaround, which is what makes a non-backtracking implementation
## possible.
##
## One deliberate deviation from the RFC's grammar: outside of brackets,
## ``^`` and ``$`` are anchors (start and end of input) rather than literal
## characters. RFC 9485 lists them as ordinary characters, but implementations
## map I-Regexps to their host dialect, where they anchor, and the JSONPath
## Compliance Test Suite expects exactly that (``match(@, '^ab.*')``). For
## ``match()`` they are redundant; for ``search()`` they restrict where a
## match may occur. A literal ``^`` is written ``\^`` and a literal ``$``
## ``[$]``, since I-Regexp has no ``\$`` escape.
##
## Why not ``std/re`` or ``std/nre``? Both wrap PCRE, a shared library NimYAML
## would then depend on at runtime, and both speak a different dialect: PCRE
## gives meaning to ``\d``, ``\w``, ``(?:`` and friends, which I-Regexp treats as
## literals or rejects. Translating patterns would be about as much code as
## matching them directly.
##
## The engine compiles a pattern to a program for a Pike VM (Thompson's NFA
## simulation, extended with a program counter instead of a state graph). All
## threads advance over the input in lock step, so matching takes time linear
## in the input for a given pattern and a hostile pattern like ``(a*)*b``
## cannot cause catastrophic backtracking. Counted repetition is expanded
## into copies of the repeated expression; ``maxInstructions`` bounds the
## result so that ``(((a{1000}){1000}){1000})`` is rejected instead of
## exhausting memory.

import std/[strutils, unicode]
import unicodecategories

type
  IRegexpError* = object of ValueError
    ## Raised for patterns that are not valid I-Regexps, or too large.

  ClassItemKind = enum
    ciRange       ## code points ``first .. last``
    ciCategory    ## code points in one of ``categories`` (``\p{..}``)
    ciNotCategory ## code points in none of ``categories`` (``\P{..}``)

  ClassItem = object
    kind: ClassItemKind
    first, last: int32
    categories: set[GeneralCategory]

  CharClass = object
    ## A set of code points. Every atom except groups compiles to one:
    ## a literal character is a class with a single one-element range.
    negated: bool
    items: seq[ClassItem]

  NodeKind = enum
    nkClass, nkConcat, nkAlternation, nkRepeat, nkStart, nkEnd

  Node = ref object
    ## The syntax tree is kept only between parsing and compiling, because
    ## counted repetition needs to copy whole subexpressions.
    case kind: NodeKind
    of nkClass: class: CharClass
    of nkConcat, nkAlternation: children: seq[Node]
    of nkStart, nkEnd: discard
    of nkRepeat:
      repeated: Node
      min: int
      max: int ## ``-1`` for unbounded

  OpKind = enum
    opClass   ## consume one code point in ``classes[arg]``, else die
    opSplit   ## continue at ``arg`` and at ``arg2`` (preferring neither)
    opJump    ## continue at ``arg``
    opMatch   ## the pattern has matched
    opStart   ## continue only at the start of the input (``^``)
    opEnd     ## continue only at the end of the input (``$``)

  Instruction = object
    kind: OpKind
    arg, arg2: int

  IRegexp* = object
    ## A compiled I-Regexp.
    program: seq[Instruction]
    classes: seq[CharClass]

const maxInstructions = 100_000

proc regexpError(msg: string): ref IRegexpError =
  newException(IRegexpError, msg)

# ----------------------------------------------------------------------------
# Parsing
#
# The parser follows the ABNF of RFC 9485, Section 3 production by production.
# It works on code points, not bytes, because the grammar distinguishes code
# point ranges (``NormalChar`` includes everything above U+007E except
# surrogates).
# ----------------------------------------------------------------------------

type Parser = object
  pattern: seq[Rune]
  pos: int

proc atEnd(p: Parser): bool = p.pos >= p.pattern.len

proc peek(p: Parser): int32 =
  if p.atEnd: -1'i32 else: int32(p.pattern[p.pos])

proc fail(p: Parser, msg: string) {.noreturn.} =
  raise regexpError(msg & " at position " & $p.pos & " of I-Regexp " &
      escape($p.pattern))

proc expect(p: var Parser, c: char) =
  if p.peek != int32(c): p.fail("expected '" & c & "'")
  inc(p.pos)

proc singleCharClass(c: int32): CharClass =
  CharClass(items: @[ClassItem(kind: ciRange, first: c, last: c)])

proc categoryEscape(p: var Parser): ClassItem =
  ## Parses ``\p{..}`` or ``\P{..}`` after the backslash. A one-letter name
  ## means the whole major category (``L`` is ``Lu`` to ``Lo``, ``C``
  ## includes unassigned code points ``Cn``).
  let negated = p.peek == int32('P')
  inc(p.pos)
  p.expect('{')
  var name = ""
  while not p.atEnd and p.peek != int32('}') and name.len < 2:
    if p.peek > 0x7F: p.fail("invalid Unicode category name")
    name.add(char(p.peek))
    inc(p.pos)
  p.expect('}')
  var categories: set[GeneralCategory]
  case name
  of "L": categories = {Lu, Ll, Lt, Lm, Lo}
  of "M": categories = {Mn, Mc, Me}
  of "N": categories = {Nd, Nl, No}
  of "P": categories = {Pc, Pd, Ps, Pe, Pi, Pf, Po}
  of "Z": categories = {Zs, Zl, Zp}
  of "S": categories = {Sm, Sc, Sk, So}
  of "C": categories = {Cc, Cf, Cs, Co, Cn}
  of "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc",
     "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl",
     "Zp", "Cc", "Cf", "Co", "Cn":
    # Cs is missing on purpose: RFC 9485 does not list it
    for category in GeneralCategory:
      if $category == name: categories = {category}
  else: p.fail("unknown Unicode category " & escape(name))
  result = ClassItem(kind: if negated: ciNotCategory else: ciCategory,
      categories: categories)

proc singleCharEscape(p: var Parser): int32 =
  ## Parses ``SingleCharEsc`` after the backslash; returns -1 if the next
  ## character does not form one.
  result = p.peek
  case result
  of int32('('), int32(')'), int32('*'), int32('+'), int32('-'), int32('.'),
     int32('?'), int32('['), int32('\\'), int32(']'), int32('^'),
     int32('{'), int32('|'), int32('}'): discard
  of int32('n'): result = 0x0A
  of int32('r'): result = 0x0D
  of int32('t'): result = 0x09
  else: return -1
  inc(p.pos)

proc isSurrogate(c: int32): bool = c >= 0xD800 and c <= 0xDFFF

proc classChar(p: var Parser): int32 =
  ## Parses ``CCchar``, a single character within brackets, or returns -1
  ## without consuming anything if there is none.
  let c = p.peek
  if c < 0 or c == int32('-') or c == int32('[') or c == int32(']') or
      c.isSurrogate:
    return -1
  if c == int32('\\'):
    inc(p.pos)
    result = p.singleCharEscape()
    if result < 0: dec(p.pos)
  else:
    inc(p.pos)
    result = c

proc bracketedClass(p: var Parser): CharClass =
  ## Parses ``charClassExpr``. A ``-`` is literal only as the first or last
  ## character; anywhere else it must form a range.
  p.expect('[')
  if p.peek == int32('^'):
    result.negated = true
    inc(p.pos)
  if p.peek == int32('-'):
    result.items.add(ClassItem(kind: ciRange, first: int32('-'), last: int32('-')))
    inc(p.pos)
  while true:
    if p.peek == int32(']'): break
    if p.peek == int32('-'):
      inc(p.pos)
      if p.peek != int32(']'): p.fail("'-' must start a range or end the class")
      result.items.add(ClassItem(kind: ciRange, first: int32('-'), last: int32('-')))
      break
    if p.peek == int32('\\') and p.pos + 1 < p.pattern.len and
        int32(p.pattern[p.pos + 1]) in [int32('p'), int32('P')]:
      inc(p.pos)
      result.items.add(p.categoryEscape())
      continue
    let first = p.classChar()
    if first < 0: p.fail("invalid character in character class")
    var last = first
    if p.peek == int32('-') and p.pos + 1 < p.pattern.len and
        int32(p.pattern[p.pos + 1]) != int32(']'):
      inc(p.pos)
      last = p.classChar()
      if last < 0: p.fail("invalid end of character range")
      if last < first: p.fail("character range out of order")
    result.items.add(ClassItem(kind: ciRange, first: first, last: last))
  if result.items.len == 0: p.fail("empty character class")
  p.expect(']')

proc isNormalChar(c: int32): bool =
  case c
  of 0x00 .. 0x27, int32(','), int32('-'), 0x2F .. 0x3E, 0x40 .. 0x5A,
     0x5E .. 0x7A, 0x7E .. 0xD7FF, 0xE000 .. 0x10FFFF: true
  else: false

proc alternation(p: var Parser): Node {.raises: [IRegexpError].}

proc atom(p: var Parser): Node =
  let c = p.peek
  if c == int32('('):
    inc(p.pos)
    result = p.alternation()
    p.expect(')')
  elif c == int32('.'):
    inc(p.pos)
    # RFC 9485, Section 5.3: '.' matches anything but line terminators
    result = Node(kind: nkClass, class: CharClass(negated: true, items: @[
        ClassItem(kind: ciRange, first: 0x0A, last: 0x0A),
        ClassItem(kind: ciRange, first: 0x0D, last: 0x0D)]))
  elif c == int32('['):
    result = Node(kind: nkClass, class: p.bracketedClass())
  elif c == int32('^'):
    inc(p.pos)
    result = Node(kind: nkStart)
  elif c == int32('$'):
    inc(p.pos)
    result = Node(kind: nkEnd)
  elif c == int32('\\'):
    inc(p.pos)
    if p.peek in [int32('p'), int32('P')]:
      result = Node(kind: nkClass, class: CharClass(items: @[p.categoryEscape()]))
    else:
      let escaped = p.singleCharEscape()
      if escaped < 0: p.fail("invalid escape")
      result = Node(kind: nkClass, class: singleCharClass(escaped))
  elif c.isNormalChar:
    inc(p.pos)
    result = Node(kind: nkClass, class: singleCharClass(c))
  else:
    p.fail("unexpected character")

proc quantity(p: var Parser): int =
  ## Parses ``QuantExact``.
  let start = p.pos
  while p.peek >= int32('0') and p.peek <= int32('9'):
    if result > maxInstructions: p.fail("repetition count too large")
    result = result * 10 + int(p.peek - int32('0'))
    inc(p.pos)
  if p.pos == start: p.fail("expected repetition count")

proc piece(p: var Parser): Node =
  result = p.atom()
  if result.kind in {nkStart, nkEnd}: return # anchors take no quantifier
  var min, max: int
  case p.peek
  of int32('*'): (min, max) = (0, -1)
  of int32('+'): (min, max) = (1, -1)
  of int32('?'): (min, max) = (0, 1)
  of int32('{'):
    inc(p.pos)
    min = p.quantity()
    max = min
    if p.peek == int32(','):
      inc(p.pos)
      max = if p.peek == int32('}'): -1 else: p.quantity()
      if max >= 0 and max < min: p.fail("repetition range out of order")
    if p.peek != int32('}'): p.fail("expected '}'")
  else: return
  inc(p.pos)
  result = Node(kind: nkRepeat, repeated: result, min: min, max: max)

proc branch(p: var Parser): Node =
  result = Node(kind: nkConcat)
  while not p.atEnd and p.peek != int32('|') and p.peek != int32(')'):
    result.children.add(p.piece())

proc alternation(p: var Parser): Node {.raises: [IRegexpError].} =
  result = Node(kind: nkAlternation, children: @[p.branch()])
  while p.peek == int32('|'):
    inc(p.pos)
    result.children.add(p.branch())

# ----------------------------------------------------------------------------
# Compiling
#
# The classic Thompson construction, emitting instructions instead of states.
# Jump targets of a split that precede its body are patched once the body has
# been emitted.
# ----------------------------------------------------------------------------

proc emit(r: var IRegexp, kind: OpKind, arg = 0, arg2 = 0): int =
  if r.program.len >= maxInstructions:
    raise regexpError("I-Regexp too large")
  result = r.program.len
  r.program.add(Instruction(kind: kind, arg: arg, arg2: arg2))

proc compile(r: var IRegexp, node: Node) =
  case node.kind
  of nkClass:
    r.classes.add(node.class)
    discard r.emit(opClass, r.classes.high)
  of nkConcat:
    for child in node.children: r.compile(child)
  of nkStart: discard r.emit(opStart)
  of nkEnd: discard r.emit(opEnd)
  of nkAlternation:
    # split L1, next; L1: a; jump end; next: split L2, ... ; last branch
    var jumps: seq[int]
    for i, child in node.children:
      if i < node.children.high:
        let split = r.emit(opSplit, r.program.len + 1)
        r.compile(child)
        jumps.add(r.emit(opJump))
        r.program[split].arg2 = r.program.len
      else:
        r.compile(child)
    for jump in jumps: r.program[jump].arg = r.program.len
  of nkRepeat:
    for _ in 1 .. node.min: r.compile(node.repeated)
    if node.max < 0:
      # loop: split body, end; body; jump loop
      let loop = r.emit(opSplit, r.program.len + 1)
      r.compile(node.repeated)
      discard r.emit(opJump, loop)
      r.program[loop].arg2 = r.program.len
    else:
      # optional copies, each skipping to the end: e? e? ... e?
      var splits: seq[int]
      for _ in node.min + 1 .. node.max:
        splits.add(r.emit(opSplit, r.program.len + 1))
        r.compile(node.repeated)
      for split in splits: r.program[split].arg2 = r.program.len

proc compileIRegexp*(pattern: string): IRegexp {.raises: [IRegexpError].} =
  ## Compiles ``pattern``, raising ``IRegexpError`` if it is not a valid
  ## I-Regexp or would compile to an excessively large program.
  var p = Parser(pattern: pattern.toRunes)
  for c in p.pattern:
    if int32(c).isSurrogate or int32(c) > 0x10FFFF:
      raise regexpError("invalid code point in I-Regexp " & escape(pattern))
  let tree = p.alternation()
  if not p.atEnd: p.fail("unmatched ')'")
  result.compile(tree)
  discard result.emit(opMatch)

# ----------------------------------------------------------------------------
# Matching
# ----------------------------------------------------------------------------

proc contains(item: ClassItem, c: int32): bool =
  case item.kind
  of ciRange: c >= item.first and c <= item.last
  of ciCategory: generalCategory(c) in item.categories
  of ciNotCategory: generalCategory(c) notin item.categories

proc contains(class: CharClass, c: int32): bool =
  result = class.negated
  for item in class.items:
    if c in item: return not class.negated

proc addThread(r: IRegexp, threads: var seq[int], onList: var seq[int],
    generation: int, start: int, atStart, atEnd: bool) =
  ## Adds the thread at ``start`` and everything reachable from it without
  ## consuming input. ``onList[pc] == generation`` marks instructions already
  ## added in this step, which is what keeps empty loops like ``(a*)*`` from
  ## spinning forever and bounds the work per input character.
  var pending = @[start]
  while pending.len > 0:
    let pc = pending.pop()
    if onList[pc] == generation: continue
    onList[pc] = generation
    let instruction = r.program[pc]
    case instruction.kind
    of opJump: pending.add(instruction.arg)
    of opSplit:
      pending.add(instruction.arg2)
      pending.add(instruction.arg)
    of opStart:
      if atStart: pending.add(pc + 1)
    of opEnd:
      if atEnd: pending.add(pc + 1)
    of opClass, opMatch: threads.add(pc)

proc run(r: IRegexp, text: string, anywhere: bool): bool =
  ## Simulates the program on ``input``. If ``anywhere`` is set, a new thread
  ## starts at every position and reaching ``opMatch`` at any point succeeds
  ## (``search``); otherwise only a match at the end of the input counts.
  let input = text.toRunes
  var
    current, next: seq[int]
    onList = newSeq[int](r.program.len)
    generation = 1
  r.addThread(current, onList, generation, 0, true, input.len == 0)
  for i, c in input:
    if anywhere:
      for pc in current:
        if r.program[pc].kind == opMatch: return true
    inc(generation)
    next.setLen(0)
    let atEnd = i == input.high
    for pc in current:
      let instruction = r.program[pc]
      if instruction.kind == opClass and int32(c) in r.classes[instruction.arg]:
        r.addThread(next, onList, generation, pc + 1, false, atEnd)
    if anywhere: r.addThread(next, onList, generation, 0, false, atEnd)
    swap(current, next)
    if current.len == 0 and not anywhere: return false
  for pc in current:
    if r.program[pc].kind == opMatch: return true

proc matches*(r: IRegexp, input: string): bool =
  ## Whether ``r`` matches the whole of ``input`` (JSONPath's ``match()``).
  r.run(input, anywhere = false)

proc matchesSubstring*(r: IRegexp, input: string): bool =
  ## Whether ``r`` matches some substring of ``input``, possibly empty
  ## (JSONPath's ``search()``).
  r.run(input, anywhere = true)
