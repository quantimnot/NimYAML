#!/usr/bin/env nim r -d:release -d:lto --hints:off --warnings:off --processing:off
#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## genidnatables: generates ``yaml/private/idnatables.nim``.
##
## Usage: ``nim r tools/genidnatables.nim <dir>``
##
## JSON Schema's ``idn-hostname`` format means IDNA2008 host names, which the
## test suite checks the way UTS 46 processes them: mapped (``Ａ`` is ``a``),
## normalized to NFC, with Punycode labels decoded, and validated with the
## contextual rules of RFC 5892 and the Bidi rule of RFC 5893. That needs
## more of the Unicode Character Database than General Categories:
##
## * the UTS 46 status and mapping of every code point
##   (``IdnaMappingTable.txt``),
## * Bidi_Class (``extracted/DerivedBidiClass.txt``),
## * Joining_Type (``extracted/DerivedJoiningType.txt``),
## * the scripts the contextual rules mention (``Scripts.txt``),
## * Canonical_Combining_Class (``extracted/DerivedCombiningClass.txt``),
## * canonical decompositions (``UnicodeData.txt``) and composition
##   exclusions (``CompositionExclusions.txt``), for NFC.
##
## Each property is stored as a sorted list of runs like in
## ``yaml/private/unicodecategories.nim``. ``<dir>`` must contain the files
## above, with the ``extracted`` ones directly in it, all from the same
## Unicode version, which is given with ``--version:X.Y.Z``.
##
## Download them from https://www.unicode.org/Public/idna/latest/ and
## https://www.unicode.org/Public/UCD/latest/ucd/.

import std/[algorithm, os, parseopt, strutils, tables]
when defined(nimPreviewSlimSystem):
  import std/syncio

const
  maxCodePoint = 0x10FFFF
  output = "yaml" / "private" / "idnatables.nim"
  statuses = ["valid", "validNV8", "ignored", "mapped", "deviation",
      "disallowed"]
  bidiClasses = ["L", "R", "AL", "EN", "ES", "ET", "AN", "CS", "NSM", "BN",
      "B", "S", "WS", "ON", "LRE", "LRO", "RLE", "RLO", "PDF", "LRI", "RLI",
      "FSI", "PDI"]
  joiningTypes = ["U", "C", "D", "L", "R", "T"]
  scripts = ["Other", "Greek", "Hebrew", "Hiragana", "Katakana", "Han"]

proc dataLines(path: string): seq[seq[string]] =
  ## The ';'-separated fields of the non-comment lines of a UCD file.
  for line in lines(path):
    let content = line.split('#')[0].strip
    if content.len == 0: continue
    var fields: seq[string]
    for f in content.split(';'): fields.add(f.strip)
    result.add(fields)

proc parseRange(s: string): (int, int) =
  let parts = s.split("..")
  let first = parseHexInt(parts[0])
  result = (first, if parts.len > 1: parseHexInt(parts[1]) else: first)

proc readProperty(path: string, names: openArray[string], default: string,
    useMissing: bool): seq[uint8] =
  ## Reads a property with values in ``names``; values not in ``names``
  ## count as ``default``. ``@missing`` lines set defaults for ranges.
  result = newSeq[uint8](maxCodePoint + 1)
  let defaultIndex = uint8(names.find(default))
  for c in result.mitems: c = defaultIndex
  if useMissing:
    for line in lines(path):
      if line.startsWith("# @missing:"):
        let fields = line[11 .. ^1].split(';')
        let (first, last) = parseRange(fields[0].strip)
        let value = names.find(fields[1].strip)
        let v = if value < 0: defaultIndex else: uint8(value)
        for cp in first .. last: result[cp] = v
  for fields in dataLines(path):
    let (first, last) = parseRange(fields[0])
    let value = names.find(fields[1])
    let v = if value < 0: defaultIndex else: uint8(value)
    for cp in first .. last: result[cp] = v

proc runs(values: seq[uint8], shift: int): seq[uint32] =
  for cp in 0 .. maxCodePoint:
    if cp == 0 or values[cp] != values[cp - 1]:
      result.add(uint32(cp) shl shift or uint32(values[cp]))

proc emitArray[T](o: var string, name, typ: string, items: seq[T],
    perLine: int, suffix: string) =
  o.add("const " & name & "*: array[" & $items.len & ", " & typ & "] = [\n")
  for i, item in items:
    if i mod perLine == 0: o.add("  ")
    o.add("0x" & toHex(item) & suffix)
    if i < items.high: o.add(if i mod perLine == perLine - 1: ",\n" else: ", ")
  o.add("]\n\n")

proc prefixed(prefix: string, names: openArray[string]): string =
  for i, name in names:
    if i > 0: result.add(", ")
    result.add(prefix & name)

proc main() =
  var
    dir = ""
    version = "unknown"
  for kind, key, value in getopt():
    case kind
    of cmdArgument: dir = key
    of cmdLongOption, cmdShortOption:
      if key == "version": version = value
    of cmdEnd: discard
  if dir.len == 0:
    quit("usage: genidnatables [--version:X.Y.Z] <dir>", 1)

  # UTS 46 statuses and mappings. A run is packed into 64 bits: the first
  # code point (21 bits), the status (3 bits), the mapping's length (6 bits)
  # and offset into ``idnaMappings`` (24 bits).
  var
    idnaRuns: seq[uint64]
    mappings: seq[uint32]
    covered = 0
  proc addRun(first, status: int, mapping: seq[uint32]) =
    let offset = mappings.len
    mappings.add(mapping)
    doAssert mapping.len < 64 and offset < (1 shl 24)
    idnaRuns.add(uint64(first) or uint64(status) shl 21 or
        uint64(mapping.len) shl 24 or uint64(offset) shl 30)
  for fields in dataLines(dir / "IdnaMappingTable.txt"):
    let (first, last) = parseRange(fields[0])
    var status = fields[1]
    if status.startsWith("disallowed"): status = "disallowed"
    if status == "valid" and fields.len > 3 and fields[3] in ["NV8", "XV8"]:
      status = "validNV8"
    var mapping: seq[uint32]
    if fields.len > 2 and fields[2].len > 0:
      for cp in fields[2].splitWhitespace: mapping.add(uint32(parseHexInt(cp)))
    if first != covered: addRun(covered, statuses.find("disallowed"), @[])
    let index = statuses.find(status)
    doAssert index >= 0, "unknown status " & status
    # runs without mapping continue as long as the status stays the same
    let previous = if idnaRuns.len > 0:
        int((idnaRuns[^1] shr 21) and 7) else: -1
    let previousLength = if idnaRuns.len > 0:
        int((idnaRuns[^1] shr 24) and 63) else: -1
    if not (previous == index and mapping.len == 0 and previousLength == 0):
      addRun(first, index, mapping)
    covered = last + 1
  if covered <= maxCodePoint: addRun(covered, statuses.find("disallowed"), @[])

  let
    bidi = readProperty(dir / "DerivedBidiClass.txt", bidiClasses, "L", true)
    joining = readProperty(dir / "DerivedJoiningType.txt", joiningTypes, "U",
        false)
    script = readProperty(dir / "Scripts.txt", scripts, "Other", false)
  var ccc = newSeq[uint8](maxCodePoint + 1)
  for fields in dataLines(dir / "DerivedCombiningClass.txt"):
    let (first, last) = parseRange(fields[0])
    for cp in first .. last: ccc[cp] = uint8(parseInt(fields[1]))

  # canonical decompositions, packed as code point (21 bits) and the one or
  # two code points it decomposes to (21 bits each)
  var
    decompositions: seq[uint64]
    pairs: seq[(int, int, int)]
    excluded: seq[int]
  for fields in dataLines(dir / "CompositionExclusions.txt"):
    excluded.add(parseRange(fields[0])[0])
  for line in lines(dir / "UnicodeData.txt"):
    let fields = line.split(';')
    if fields[5].len == 0 or fields[5][0] == '<': continue
    let
      cp = parseHexInt(fields[0])
      parts = fields[5].splitWhitespace
      first = parseHexInt(parts[0])
      second = if parts.len > 1: parseHexInt(parts[1]) else: 0
    decompositions.add(uint64(cp) or uint64(first) shl 21 or
        uint64(second) shl 42)
    if parts.len == 2 and cp notin excluded and ccc[cp] == 0 and
        ccc[first] == 0:
      pairs.add((first, second, cp))
  pairs.sort()
  var compositions: seq[uint64]
  for (first, second, cp) in pairs:
    compositions.add(uint64(first) shl 42 or uint64(second) shl 21 or
        uint64(cp))

  var o = """#!/usr/bin/env nim r -d:release -d:lto --hints:off --warnings:off --processing:off

## Unicode data for IDNA, generated by ``tools/genidnatables.nim`` from
## the Unicode Character Database and UTS 46 (Unicode """ & version & """);
## do not edit. See the generator for the packing of each table.

type
  IdnaStatus* = enum
    """ & statuses.join(", ") & """

  BidiClass* = enum
    """ & prefixed("bc", bidiClasses) & """

  JoiningType* = enum
    """ & prefixed("jt", joiningTypes) & """

  IdnaScript* = enum
    """ & prefixed("sc", scripts) & """

"""
  o.emitArray("idnaRuns", "uint64", idnaRuns, 4, "'u64")
  o.emitArray("idnaMappings", "uint32", mappings, 8, "'u32")
  o.emitArray("bidiRuns", "uint32", runs(bidi, 5), 8, "'u32")
  o.emitArray("joiningRuns", "uint32", runs(joining, 3), 8, "'u32")
  o.emitArray("scriptRuns", "uint32", runs(script, 3), 8, "'u32")
  o.emitArray("combiningRuns", "uint32", runs(ccc, 8), 8, "'u32")
  o.emitArray("decompositions", "uint64", decompositions, 4, "'u64")
  o.emitArray("compositions", "uint64", compositions, 4, "'u64")
  writeFile(output, o)
  echo "wrote ", output, ": ", idnaRuns.len, " IDNA runs, ", mappings.len,
      " mapped code points, ", decompositions.len, " decompositions, ",
      compositions.len, " compositions"

main()
