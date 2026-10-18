#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ECMA-262 regular expressions, as JSON Schema's ``pattern``,
## ``patternProperties`` and ``format: regex`` use them.
##
## JSON Schema says patterns SHOULD be valid ECMA-262 regular expressions and
## the test suite expects them to be interpreted with the ``u`` flag: the
## pattern and the input are sequences of code points, ``\p{..}`` works,
## and the grammar is the strict one without Annex B's leniency. That is what
## this module implements, without any other flag: no case folding, ``.``
## stops at line terminators, and ``^``/``$`` only match at the ends of the
## input. ``\d``, ``\w`` and ``\b`` are ASCII-only as ECMA-262 defines them;
## ``\s`` is Unicode white space.
##
## Supported: alternatives, greedy and lazy quantifiers, capturing, named
## and non-capturing groups, backreferences (numbered and ``\k<name>``),
## lookahead and lookbehind (of any width), character classes with ranges and
## class escapes, and ``\p{..}``/``\P{..}`` for General Categories (by short
## name, long name or alias, also as ``gc=..``/``General_Category=..``) and
## the binary properties ``Any``, ``ASCII`` and ``Assigned``. Other Unicode
## properties (scripts, ``Alphabetic``, ...) would need further tables and
## are rejected as unsupported, as are the ``v``-flag class syntax and
## pattern modifiers.
##
## Matching is backtracking, as ECMA-262 semantics require for
## backreferences and lookaround, but runs on an explicit stack so that long
## inputs cannot overflow the call stack, and it gives up after a fixed number
## of steps (raising ``EcmaRegexError``) so that a pathological pattern cannot
## hang validation.

import std/[strutils, unicode]
import unicodecategories

type
  EcmaRegexError* = object of ValueError
    ## Raised for invalid or unsupported patterns, and when matching exceeds
    ## the step limit.

  ItemKind = enum
    ikRange, ikCategories, ikNotCategories, ikClass

  ClassItem = object
    case kind: ItemKind
    of ikRange: first, last: int32
    of ikCategories, ikNotCategories: categories: set[GeneralCategory]
    of ikClass: class: int ## index of a nested (possibly negated) class

  CharClass = object
    negated: bool
    items: seq[ClassItem]

  AssertionKind = enum
    akStart, akEnd, akWordBoundary, akNotWordBoundary

  NodeKind = enum
    nkEmpty, nkChar, nkAny, nkClass, nkSeq, nkAlt, nkGroup, nkRepeat,
    nkAssert, nkLook, nkBackRef

  Node = ref object
    case kind: NodeKind
    of nkEmpty, nkAny: discard
    of nkChar: cp: int32
    of nkClass: class: int
    of nkSeq, nkAlt: children: seq[Node]
    of nkGroup:
      group: int ## capture group number, or 0 for non-capturing
      inner: Node
    of nkRepeat:
      repeated: Node
      min, max: int ## ``max == -1`` for unbounded
      greedy: bool
      firstGroup, lastGroup: int ## capture groups inside ``repeated``
    of nkAssert: assertion: AssertionKind
    of nkLook:
      behind, negative: bool
      body: Node
    of nkBackRef:
      refGroup: int
      refName: string ## for ``\k<name>``, resolved after parsing

  OpKind = enum
    opChar, opClass, opAny, opSplit, opJump, opSave, opClearCaptures,
    opAssert, opLook, opBackRef, opCounterInit, opLoop, opLoopMark,
    opLoopEnd, opMatch

  Instruction = object
    kind: OpKind
    backward: bool ## for consuming instructions: match right to left
    greedy: bool   ## for opLoop
    a, b, c, d: int

  Look = object
    start: int ## first instruction of the sub-program
    negative: bool

  EcmaRegex* = object
    ## A compiled regular expression.
    program: seq[Instruction]
    classes: seq[CharClass]
    looks: seq[Look]
    groups: int
    registers: int

const
  maxInstructions = 200_000
  maxSteps = 5_000_000
  syntaxChars = {'^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{',
      '}', '|', '/'}

proc regexError(msg: string): ref EcmaRegexError =
  newException(EcmaRegexError, msg)

# ----------------------------------------------------------------------------
# Character sets
# ----------------------------------------------------------------------------

proc isLineTerminator(c: int32): bool =
  c == 0x0A or c == 0x0D or c == 0x2028 or c == 0x2029

proc isWhiteSpace(c: int32): bool =
  ## ``WhiteSpace`` and ``LineTerminator`` (ECMA-262, 12.2 and 12.3).
  case c
  of 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000 .. 0x200A,
     0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
  else: false

proc isWordChar(c: int32): bool =
  c in 0x30'i32 .. 0x39'i32 or c in 0x41'i32 .. 0x5A'i32 or
      c in 0x61'i32 .. 0x7A'i32 or c == 0x5F

proc contains(r: EcmaRegex, class: CharClass, c: int32): bool =
  result = false
  for item in class.items:
    case item.kind
    of ikRange:
      if c >= item.first and c <= item.last: result = true
    of ikCategories:
      if c.generalCategory in item.categories: result = true
    of ikNotCategories:
      if c.generalCategory notin item.categories: result = true
    of ikClass:
      if r.contains(r.classes[item.class], c): result = true
    if result: break
  if class.negated: result = not result

const
  categoryNames: array[38, (string, set[GeneralCategory])] = [
    ("L", {Lu, Ll, Lt, Lm, Lo}), ("LC", {Lu, Ll, Lt}),
    ("M", {Mn, Mc, Me}), ("N", {Nd, Nl, No}),
    ("P", {Pc, Pd, Ps, Pe, Pi, Pf, Po}), ("S", {Sm, Sc, Sk, So}),
    ("Z", {Zs, Zl, Zp}), ("C", {Cc, Cf, Cs, Co, Cn}),
    ("Letter", {Lu, Ll, Lt, Lm, Lo}), ("Cased_Letter", {Lu, Ll, Lt}),
    ("Mark", {Mn, Mc, Me}), ("Combining_Mark", {Mn, Mc, Me}),
    ("Number", {Nd, Nl, No}), ("Punctuation", {Pc, Pd, Ps, Pe, Pi, Pf, Po}),
    ("punct", {Pc, Pd, Ps, Pe, Pi, Pf, Po}), ("Symbol", {Sm, Sc, Sk, So}),
    ("Separator", {Zs, Zl, Zp}), ("Other", {Cc, Cf, Cs, Co, Cn}),
    ("Uppercase_Letter", {Lu}), ("Lowercase_Letter", {Ll}),
    ("Titlecase_Letter", {Lt}), ("Modifier_Letter", {Lm}),
    ("Other_Letter", {Lo}), ("Nonspacing_Mark", {Mn}),
    ("Spacing_Mark", {Mc}), ("Enclosing_Mark", {Me}),
    ("Decimal_Number", {Nd}), ("digit", {Nd}), ("Letter_Number", {Nl}),
    ("Other_Number", {No}), ("Connector_Punctuation", {Pc}),
    ("Dash_Punctuation", {Pd}), ("Open_Punctuation", {Ps}),
    ("Close_Punctuation", {Pe}), ("Initial_Punctuation", {Pi}),
    ("Final_Punctuation", {Pf}), ("Other_Punctuation", {Po}),
    ("Math_Symbol", {Sm})]
  moreCategoryNames: array[13, (string, set[GeneralCategory])] = [
    ("Currency_Symbol", {Sc}), ("Modifier_Symbol", {Sk}),
    ("Other_Symbol", {So}), ("Space_Separator", {Zs}),
    ("Line_Separator", {Zl}), ("Paragraph_Separator", {Zp}),
    ("Control", {Cc}), ("cntrl", {Cc}), ("Format", {Cf}),
    ("Surrogate", {Cs}), ("Private_Use", {Co}), ("Unassigned", {Cn}),
    ("Any", {Lu .. Cn})]

proc lookupCategory(name: string, categories: var set[GeneralCategory]): bool =
  for category in GeneralCategory:
    if $category == name:
      categories = {category}
      return true
  for (n, c) in categoryNames:
    if n == name:
      categories = c
      return true
  for (n, c) in moreCategoryNames:
    if n == name and n != "Any":
      categories = c
      return true
  result = false

# ----------------------------------------------------------------------------
# Parsing (ECMA-262, 22.2.1, with the [UnicodeMode] parameter)
# ----------------------------------------------------------------------------

type Parser = object
  pattern: seq[int32]
  pos: int
  classes: seq[CharClass]
  groupCount: int   ## total number of capturing groups, from a pre-scan
  nextGroup: int
  names: seq[string] ## names[i] is the name of group i + 1, or ""
  backRefs: seq[Node] ## named backreferences to resolve

proc atEnd(p: Parser): bool = p.pos >= p.pattern.len
proc peek(p: Parser, offset = 0): int32 =
  if p.pos + offset < p.pattern.len: p.pattern[p.pos + offset] else: -1
proc fail(p: Parser, msg: string) {.noreturn.} =
  raise regexError(msg & " at position " & $p.pos)
proc isChar(p: Parser, c: char, offset = 0): bool = p.peek(offset) == int32(c)
proc expect(p: var Parser, c: char) =
  if not p.isChar(c): p.fail("expected '" & c & "'")
  inc(p.pos)

proc countGroups(pattern: seq[int32]): int =
  ## Counts capturing groups so that ``\N`` can be checked against the total
  ## while parsing (backreferences may point forward).
  var
    i = 0
    inClass = false
  while i < pattern.len:
    let c = pattern[i]
    if c == int32('\\'): inc(i)
    elif inClass:
      if c == int32(']'): inClass = false
    elif c == int32('['): inClass = true
    elif c == int32('('):
      if i + 1 >= pattern.len or pattern[i + 1] != int32('?'): inc(result)
      elif i + 2 < pattern.len and pattern[i + 2] == int32('<') and
          i + 3 < pattern.len and pattern[i + 3] notin [int32('='), int32('!')]:
        inc(result)
    inc(i)

proc hexValue(c: int32): int =
  if c >= int32('0') and c <= int32('9'): int(c) - ord('0')
  elif c >= int32('a') and c <= int32('f'): int(c) - ord('a') + 10
  elif c >= int32('A') and c <= int32('F'): int(c) - ord('A') + 10
  else: -1

proc hexDigits(p: var Parser, count: int): int32 =
  var value = 0
  for _ in 0 ..< count:
    let h = hexValue(p.peek)
    if h < 0: p.fail("invalid hexadecimal escape")
    value = value * 16 + h
    inc(p.pos)
  result = int32(value)

proc unicodeEscape(p: var Parser): int32 =
  ## Parses the part of ``\u...`` after ``u``, combining surrogate pairs.
  if p.isChar('{'):
    inc(p.pos)
    var value = 0
    let start = p.pos
    while not p.isChar('}'):
      let h = hexValue(p.peek)
      if h < 0: p.fail("invalid code point escape")
      value = value * 16 + h
      if value > 0x10FFFF: p.fail("code point out of range")
      inc(p.pos)
    if p.pos == start: p.fail("empty code point escape")
    inc(p.pos)
    return int32(value)
  result = p.hexDigits(4)
  if result >= 0xD800 and result <= 0xDBFF and p.isChar('\\') and
      p.isChar('u', 1):
    let save = p.pos
    p.pos += 2
    if hexValue(p.peek) >= 0:
      let low = p.hexDigits(4)
      if low >= 0xDC00 and low <= 0xDFFF:
        return 0x10000'i32 + ((result - 0xD800) shl 10) + (low - 0xDC00)
    p.pos = save

proc propertyEscape(p: var Parser, negated: bool): ClassItem =
  ## Parses ``{..}`` after ``\p`` or ``\P``.
  p.expect('{')
  var name, value: string
  var hasValue = false
  while not p.isChar('}'):
    let c = p.peek
    if c < 0: p.fail("unterminated property escape")
    if c == int32('='):
      if hasValue: p.fail("invalid property escape")
      hasValue = true
    elif c > 0x7F or char(c) notin Letters + Digits + {'_'}:
      p.fail("invalid property name")
    elif hasValue: value.add(char(c))
    else: name.add(char(c))
    inc(p.pos)
  inc(p.pos)
  var categories: set[GeneralCategory]
  if hasValue:
    if name notin ["General_Category", "gc"]:
      p.fail("unsupported Unicode property " & name)
    if not lookupCategory(value, categories):
      p.fail("unknown General Category " & value)
  elif name == "Any": categories = {Lu .. Cn}
  elif name == "Assigned": categories = {Lu .. Co}
  elif name == "ASCII":
    return ClassItem(kind: ikClass, class: -1) # placeholder, see caller
  elif not lookupCategory(name, categories):
    p.fail("unknown or unsupported Unicode property " & name)
  if negated: result = ClassItem(kind: ikNotCategories, categories: categories)
  else: result = ClassItem(kind: ikCategories, categories: categories)

proc addClass(p: var Parser, class: CharClass): int =
  p.classes.add(class)
  result = p.classes.high

proc asciiItem(p: var Parser, negated: bool): ClassItem =
  ClassItem(kind: ikClass, class: p.addClass(CharClass(negated: negated,
      items: @[ClassItem(kind: ikRange, first: 0, last: 0x7F)])))

proc classEscape(p: var Parser, c: int32, item: var ClassItem): bool =
  ## Parses the class escapes ``\d \D \s \S \w \W \p \P`` after the
  ## backslash (``c`` is the letter, not yet consumed).
  case char(c and 0x7F)
  of 'd', 'D', 'w', 'W', 's', 'S':
    if c > 0x7F: return false
    inc(p.pos)
    var class = CharClass(negated: char(c) in {'D', 'W', 'S'})
    case char(c)
    of 'd', 'D': class.items = @[ClassItem(kind: ikRange, first: 0x30, last: 0x39)]
    of 'w', 'W':
      class.items = @[ClassItem(kind: ikRange, first: 0x30, last: 0x39),
          ClassItem(kind: ikRange, first: 0x41, last: 0x5A),
          ClassItem(kind: ikRange, first: 0x5F, last: 0x5F),
          ClassItem(kind: ikRange, first: 0x61, last: 0x7A)]
    else:
      for r in [(0x09'i32, 0x0D'i32), (0x20'i32, 0x20'i32), (0xA0'i32, 0xA0'i32),
          (0x1680'i32, 0x1680'i32), (0x2000'i32, 0x200A'i32),
          (0x2028'i32, 0x2029'i32), (0x202F'i32, 0x202F'i32),
          (0x205F'i32, 0x205F'i32), (0x3000'i32, 0x3000'i32),
          (0xFEFF'i32, 0xFEFF'i32)]:
        class.items.add(ClassItem(kind: ikRange, first: r[0], last: r[1]))
    item = ClassItem(kind: ikClass, class: p.addClass(class))
    result = true
  of 'p', 'P':
    if c > 0x7F: return false
    inc(p.pos)
    let negated = c == int32('P')
    item = p.propertyEscape(negated)
    if item.kind == ikClass and item.class == -1: item = p.asciiItem(negated)
    result = true
  else: result = false

proc characterEscape(p: var Parser, inClass: bool): int32 =
  ## Parses a ``CharacterEscape`` after the backslash; fails if there is
  ## none.
  let c = p.peek
  if c < 0: p.fail("pattern ends with '\\'")
  inc(p.pos)
  if c > 0x7F: p.fail("invalid escape")
  case char(c)
  of 'f': result = 0x0C
  of 'n': result = 0x0A
  of 'r': result = 0x0D
  of 't': result = 0x09
  of 'v': result = 0x0B
  of 'c':
    let letter = p.peek
    if letter < 0 or letter > 0x7F or char(letter) notin Letters:
      p.fail("invalid control escape")
    inc(p.pos)
    result = letter mod 32
  of '0':
    if p.peek >= int32('0') and p.peek <= int32('9'):
      p.fail("invalid octal escape")
    result = 0
  of 'x': result = p.hexDigits(2)
  of 'u': result = p.unicodeEscape()
  of '-':
    if not inClass: p.fail("invalid escape '\\-'")
    result = int32('-')
  else:
    if char(c) in syntaxChars: result = c
    elif inClass and char(c) == 'b': result = 0x08
    else: p.fail("invalid escape '\\" & char(c) & "'")

proc classAtom(p: var Parser, item: var ClassItem): int32 =
  ## Parses one ``ClassAtom``. Returns its code point, or -1 if it is a
  ## class escape (then ``item`` is set).
  let c = p.peek
  if c < 0: p.fail("unterminated character class")
  if c == int32('\\'):
    inc(p.pos)
    if p.classEscape(p.peek, item): return -1
    return p.characterEscape(true)
  inc(p.pos)
  result = c

proc characterClass(p: var Parser): Node =
  p.expect('[')
  var class = CharClass()
  if p.isChar('^'):
    class.negated = true
    inc(p.pos)
  while not p.isChar(']'):
    var item: ClassItem
    let first = p.classAtom(item)
    if p.isChar('-') and not p.isChar(']', 1) and p.peek(1) >= 0:
      inc(p.pos)
      var item2: ClassItem
      let last = p.classAtom(item2)
      if first < 0 or last < 0:
        p.fail("character class escape used as range bound")
      if first > last: p.fail("character class range out of order")
      class.items.add(ClassItem(kind: ikRange, first: first, last: last))
    elif first < 0: class.items.add(item)
    else: class.items.add(ClassItem(kind: ikRange, first: first, last: first))
  inc(p.pos)
  result = Node(kind: nkClass, class: p.addClass(class))

proc groupName(p: var Parser): string =
  ## Parses ``name>`` after ``<``.
  while not p.isChar('>'):
    var c = p.peek
    if c < 0: p.fail("unterminated group name")
    if c == int32('\\'):
      inc(p.pos)
      p.expect('u')
      c = p.unicodeEscape()
    else: inc(p.pos)
    let r = Rune(c)
    let ok = (c == int32('$') or c == int32('_') or r.isAlpha or
        (result.len > 0 and (c in 0x30'i32 .. 0x39'i32 or c == 0x200C or
        c == 0x200D or c.generalCategory in {Mn, Mc, Nd, Pc})))
    if not ok: p.fail("invalid group name")
    result.add(r.toUTF8)
  inc(p.pos)
  if result.len == 0: p.fail("empty group name")

proc disjunction(p: var Parser): Node {.raises: [EcmaRegexError].}

proc decimalNumber(p: var Parser): int =
  result = 0
  while p.peek >= int32('0') and p.peek <= int32('9'):
    if result < 100_000_000: result = result * 10 + int(p.peek) - ord('0')
    inc(p.pos)

proc atom(p: var Parser): Node =
  let c = p.peek
  case char(if c > 0x7F: 0 else: c)
  of '.':
    inc(p.pos)
    result = Node(kind: nkAny)
  of '[': result = p.characterClass()
  of '(':
    inc(p.pos)
    if p.isChar('?'):
      inc(p.pos)
      if p.isChar(':'):
        inc(p.pos)
        result = Node(kind: nkGroup, group: 0, inner: p.disjunction())
      elif p.isChar('<'):
        inc(p.pos)
        let name = p.groupName()
        if name in p.names: p.fail("duplicate group name " & name)
        inc(p.nextGroup)
        p.names.add(name)
        result = Node(kind: nkGroup, group: p.nextGroup, inner: p.disjunction())
      else: p.fail("invalid group")
    else:
      inc(p.nextGroup)
      p.names.add("")
      result = Node(kind: nkGroup, group: p.nextGroup, inner: p.disjunction())
    p.expect(')')
  of '\\':
    inc(p.pos)
    let e = p.peek
    if e >= int32('1') and e <= int32('9'):
      let n = p.decimalNumber()
      if n > p.groupCount: p.fail("backreference to nonexistent group")
      return Node(kind: nkBackRef, refGroup: n)
    if e == int32('k'):
      inc(p.pos)
      p.expect('<')
      result = Node(kind: nkBackRef, refName: p.groupName())
      p.backRefs.add(result)
      return
    var item: ClassItem
    if p.classEscape(e, item):
      return Node(kind: nkClass, class: p.addClass(CharClass(items: @[item])))
    result = Node(kind: nkChar, cp: p.characterEscape(false))
  of '*', '+', '?': p.fail("nothing to repeat")
  of '{': p.fail("lone '{'")
  of '}', ']': p.fail("lone '" & char(c) & "'")
  else:
    inc(p.pos)
    result = Node(kind: nkChar, cp: c)

proc quantifier(p: var Parser, min, max: var int): bool =
  case char(if p.peek > 0x7F or p.peek < 0: 0 else: p.peek)
  of '*': (min, max) = (0, -1)
  of '+': (min, max) = (1, -1)
  of '?': (min, max) = (0, 1)
  of '{':
    inc(p.pos)
    if not (p.peek >= int32('0') and p.peek <= int32('9')):
      p.fail("invalid quantifier")
    min = p.decimalNumber()
    max = min
    if p.isChar(','):
      inc(p.pos)
      max = if p.isChar('}'): -1 else: p.decimalNumber()
    if not p.isChar('}'): p.fail("invalid quantifier")
    if max >= 0 and max < min: p.fail("numbers out of order in quantifier")
  else: return false
  inc(p.pos)
  result = true

proc term(p: var Parser): Node =
  let c = p.peek
  if c == int32('^'):
    inc(p.pos)
    result = Node(kind: nkAssert, assertion: akStart)
  elif c == int32('$'):
    inc(p.pos)
    result = Node(kind: nkAssert, assertion: akEnd)
  elif c == int32('\\') and p.isChar('b', 1):
    p.pos += 2
    result = Node(kind: nkAssert, assertion: akWordBoundary)
  elif c == int32('\\') and p.isChar('B', 1):
    p.pos += 2
    result = Node(kind: nkAssert, assertion: akNotWordBoundary)
  elif c == int32('(') and p.isChar('?', 1) and
      (p.isChar('=', 2) or p.isChar('!', 2) or
       (p.isChar('<', 2) and (p.isChar('=', 3) or p.isChar('!', 3)))):
    let behind = p.isChar('<', 2)
    p.pos += (if behind: 3 else: 2)
    let negative = p.isChar('!')
    inc(p.pos)
    result = Node(kind: nkLook, behind: behind, negative: negative,
        body: p.disjunction())
    p.expect(')')
  else:
    let groupsBefore = p.nextGroup
    result = p.atom()
    var min, max: int
    if p.quantifier(min, max):
      var greedy = true
      if p.isChar('?'):
        greedy = false
        inc(p.pos)
      result = Node(kind: nkRepeat, repeated: result, min: min, max: max,
          greedy: greedy, firstGroup: groupsBefore + 1, lastGroup: p.nextGroup)
    return
  var min, max: int
  if p.quantifier(min, max): p.fail("nothing to repeat")

proc alternative(p: var Parser): Node =
  result = Node(kind: nkSeq)
  while not p.atEnd and not p.isChar('|') and not p.isChar(')'):
    result.children.add(p.term())

proc disjunction(p: var Parser): Node {.raises: [EcmaRegexError].} =
  result = p.alternative()
  if p.isChar('|'):
    result = Node(kind: nkAlt, children: @[result])
    while p.isChar('|'):
      inc(p.pos)
      result.children.add(p.alternative())

# ----------------------------------------------------------------------------
# Compiling
# ----------------------------------------------------------------------------

proc emit(r: var EcmaRegex, kind: OpKind, a = 0, b = 0, c = 0, d = 0,
    backward = false): int =
  if r.program.len >= maxInstructions: raise regexError("pattern too large")
  r.program.add(Instruction(kind: kind, a: a, b: b, c: c, d: d,
      backward: backward))
  result = r.program.high

proc compile(r: var EcmaRegex, node: Node, backward: bool) {.raises: [EcmaRegexError].}

proc compileLook(r: var EcmaRegex, node: Node): int =
  ## Compiles a lookaround body as a separate sub-program after a jump.
  let skip = r.emit(opJump)
  let start = r.program.len
  r.compile(node.body, node.behind)
  discard r.emit(opMatch)
  r.program[skip].a = r.program.len
  r.looks.add(Look(start: start, negative: node.negative))
  result = r.looks.high

proc compile(r: var EcmaRegex, node: Node, backward: bool) {.raises: [EcmaRegexError].} =
  case node.kind
  of nkEmpty: discard
  of nkChar: discard r.emit(opChar, node.cp, backward = backward)
  of nkAny: discard r.emit(opAny, backward = backward)
  of nkClass: discard r.emit(opClass, node.class, backward = backward)
  of nkSeq:
    if backward:
      for i in countdown(node.children.high, 0):
        r.compile(node.children[i], backward)
    else:
      for child in node.children: r.compile(child, backward)
  of nkAlt:
    var jumps: seq[int]
    for i, child in node.children:
      if i < node.children.high:
        let split = r.emit(opSplit)
        r.program[split].a = r.program.len
        r.compile(child, backward)
        jumps.add(r.emit(opJump))
        r.program[split].b = r.program.len
      else: r.compile(child, backward)
    for j in jumps: r.program[j].a = r.program.len
  of nkGroup:
    if node.group == 0: r.compile(node.inner, backward)
    else:
      # a backward match records the end of the group first
      discard r.emit(opSave, 2 * node.group + (if backward: 1 else: 0))
      r.compile(node.inner, backward)
      discard r.emit(opSave, 2 * node.group + (if backward: 0 else: 1))
  of nkRepeat:
    let
      counter = r.registers
      mark = r.registers + 1
    r.registers += 2
    discard r.emit(opCounterInit, counter)
    let loop = r.emit(opLoop, counter, node.min, node.max)
    r.program[loop].greedy = node.greedy
    discard r.emit(opLoopMark, mark)
    if node.firstGroup <= node.lastGroup:
      discard r.emit(opClearCaptures, node.firstGroup, node.lastGroup)
    r.compile(node.repeated, backward)
    discard r.emit(opLoopEnd, counter, mark, node.min, loop)
    r.program[loop].d = r.program.len
  of nkAssert: discard r.emit(opAssert, ord(node.assertion))
  of nkLook:
    let look = r.compileLook(node)
    discard r.emit(opLook, look)
  of nkBackRef: discard r.emit(opBackRef, node.refGroup, backward = backward)

proc toCodePoints(s: string): seq[int32] =
  ## Decodes UTF-8; invalid bytes become code points of their own value so
  ## that matching stays total.
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    var
      length = 1
      cp = c
    if c >= 0xC0 and c < 0xE0: (length, cp) = (2, c and 0x1F)
    elif c >= 0xE0 and c < 0xF0: (length, cp) = (3, c and 0x0F)
    elif c >= 0xF0 and c < 0xF8: (length, cp) = (4, c and 0x07)
    var ok = length == 1 or i + length <= s.len
    if ok and length > 1:
      for k in 1 ..< length:
        if (ord(s[i + k]) and 0xC0) != 0x80: ok = false
        else: cp = cp shl 6 or (ord(s[i + k]) and 0x3F)
    if not ok:
      (length, cp) = (1, c)
    result.add(int32(cp))
    i += length

proc compileEcmaRegex*(pattern: string): EcmaRegex {.raises: [EcmaRegexError].} =
  ## Parses and compiles ``pattern`` as an ECMA-262 regular expression with
  ## the ``u`` flag.
  var p = Parser(pattern: toCodePoints(pattern))
  p.groupCount = countGroups(p.pattern)
  let root = p.disjunction()
  if not p.atEnd:
    if p.isChar(')'): p.fail("unmatched ')'")
    p.fail("unexpected character")
  for backRef in p.backRefs:
    backRef.refGroup = p.names.find(backRef.refName) + 1
    if backRef.refGroup == 0:
      raise regexError("backreference to nonexistent group " & backRef.refName)
  result = EcmaRegex(classes: p.classes, groups: p.nextGroup)
  result.compile(root, false)
  discard result.emit(opMatch)

proc isEcmaRegex*(pattern: string): bool {.raises: [].} =
  ## Whether ``pattern`` is a valid ECMA-262 regular expression (``u`` flag)
  ## that this module supports.
  try:
    discard compileEcmaRegex(pattern)
    result = true
  except EcmaRegexError: result = false

# ----------------------------------------------------------------------------
# Matching
# ----------------------------------------------------------------------------

type
  EntryKind = enum
    ekChoice, ekCapture, ekRegister

  Entry = object
    kind: EntryKind
    a, b: int ## ekChoice: pc, pos; ekCapture/ekRegister: index, old value

  Machine = object
    steps: int

proc execute(r: EcmaRegex, m: var Machine, input: seq[int32], startPc,
    startPos: int, captures, registers: var seq[int]): bool =
  ## Runs the program from ``startPc`` at ``startPos``; on success,
  ## ``captures`` holds the captures of the first match found.
  var
    stack: seq[Entry]
    pc = startPc
    pos = startPos

  template setCapture(i, value: int) =
    stack.add(Entry(kind: ekCapture, a: i, b: captures[i]))
    captures[i] = value
  template setRegister(i, value: int) =
    stack.add(Entry(kind: ekRegister, a: i, b: registers[i]))
    registers[i] = value
  template fail() =
    var resumed = false
    while stack.len > 0:
      let e = stack.pop()
      case e.kind
      of ekCapture: captures[e.a] = e.b
      of ekRegister: registers[e.a] = e.b
      of ekChoice:
        pc = e.a
        pos = e.b
        resumed = true
        break
    if not resumed: return false
    continue

  while true:
    inc(m.steps)
    if m.steps > maxSteps: raise regexError("regular expression too complex")
    let instr = r.program[pc]
    case instr.kind
    of opChar, opClass, opAny:
      let i = if instr.backward: pos - 1 else: pos
      if i < 0 or i >= input.len: fail()
      let c = input[i]
      let ok = case instr.kind
        of opChar: c == int32(instr.a)
        of opClass: r.contains(r.classes[instr.a], c)
        else: not c.isLineTerminator
      if not ok: fail()
      pos = if instr.backward: pos - 1 else: pos + 1
      inc(pc)
    of opSplit:
      stack.add(Entry(kind: ekChoice, a: instr.b, b: pos))
      pc = instr.a
    of opJump: pc = instr.a
    of opSave:
      setCapture(instr.a, pos)
      inc(pc)
    of opClearCaptures:
      for g in instr.a .. instr.b:
        if captures[2 * g] >= 0 or captures[2 * g + 1] >= 0:
          setCapture(2 * g, -1)
          setCapture(2 * g + 1, -1)
      inc(pc)
    of opAssert:
      let ok = case AssertionKind(instr.a)
        of akStart: pos == 0
        of akEnd: pos == input.len
        of akWordBoundary, akNotWordBoundary:
          let
            before = pos > 0 and input[pos - 1].isWordChar
            after = pos < input.len and input[pos].isWordChar
          (before != after) == (AssertionKind(instr.a) == akWordBoundary)
      if not ok: fail()
      inc(pc)
    of opLook:
      let look = r.looks[instr.a]
      var
        subCaptures = captures
        subRegisters = registers
      let matched = r.execute(m, input, look.start, pos, subCaptures,
          subRegisters)
      if matched == look.negative: fail()
      if not look.negative:
        for i in 0 ..< captures.len:
          if subCaptures[i] != captures[i]: setCapture(i, subCaptures[i])
      inc(pc)
    of opBackRef:
      let
        s = captures[2 * instr.a]
        e = captures[2 * instr.a + 1]
      if s >= 0 and e >= 0:
        let length = e - s
        if instr.backward:
          if pos - length < 0: fail()
          for k in 0 ..< length:
            if input[pos - length + k] != input[s + k]: fail()
          pos -= length
        else:
          if pos + length > input.len: fail()
          for k in 0 ..< length:
            if input[pos + k] != input[s + k]: fail()
          pos += length
      inc(pc)
    of opCounterInit:
      setRegister(instr.a, 0)
      inc(pc)
    of opLoop:
      let
        count = registers[instr.a]
        min = instr.b
        max = instr.c
        exit = instr.d
      if count < min: inc(pc)
      elif max >= 0 and count >= max: pc = exit
      else:
        if instr.greedy:
          stack.add(Entry(kind: ekChoice, a: exit, b: pos))
          inc(pc)
        else:
          stack.add(Entry(kind: ekChoice, a: pc + 1, b: pos))
          pc = exit
    of opLoopMark:
      setRegister(instr.a, pos)
      inc(pc)
    of opLoopEnd:
      let
        count = registers[instr.a]
        mark = registers[instr.b]
      if count >= instr.c and pos == mark: fail()
      setRegister(instr.a, count + 1)
      pc = instr.d
    of opMatch: return true

proc search(r: EcmaRegex, input: seq[int32]): bool =
  var m = Machine()
  for start in 0 .. input.len:
    var
      captures = newSeq[int](2 * (r.groups + 1))
      registers = newSeq[int](r.registers)
    for c in captures.mitems: c = -1
    if r.execute(m, input, 0, start, captures, registers): return true
  result = false

proc contains*(r: EcmaRegex, input: string): bool {.raises: [EcmaRegexError].} =
  ## Whether ``r`` matches anywhere in ``input``, which is how JSON Schema
  ## applies patterns (they are not implicitly anchored).
  r.search(toCodePoints(input))
