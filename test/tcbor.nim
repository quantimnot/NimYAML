#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml/[cbor, data, stream, dumping, presenter, parser, memory]
import unittest, streams, strutils, tables, times

when not defined(gcArc) or defined(gcOrc):
  import ../yaml/dom

type
  Item = object
    name: string
    count: int32
    ratio: float
    tags: seq[string]
    enabled: bool

  Node = ref object
    value: int32
    next: Node

proc bytes(hex: string): string = parseHexStr(hex)
proc hex(data: string): string = toHex(data).toLowerAscii

type Trickle = ref object of StreamObj
  ## A stream that delivers one byte per read, so that the streaming
  ## decoder refills at every byte.
  data: string
  pos: int

proc trickleRead(s: Stream, buffer: pointer, bufLen: int): int =
  let t = Trickle(s)
  if bufLen == 0 or t.pos >= t.data.len: return 0
  cast[ptr char](buffer)[] = t.data[t.pos]
  inc t.pos
  1

proc trickleReadStr(s: Stream, buffer: var string, slice: Slice[int]): int =
  trickleRead(s, addr buffer[slice.a], slice.len)

proc trickleAtEnd(s: Stream): bool = Trickle(s).pos >= Trickle(s).data.len

proc trickle(data: string): Stream =
  Trickle(data: data, readDataImpl: trickleRead,
      readDataStrImpl: trickleReadStr, atEndImpl: trickleAtEnd)

proc contentEvents(s: YamlStream): seq[string] =
  for e in s:
    if e.kind notin {yamlStartStream, yamlEndStream, yamlStartDoc, yamlEndDoc}:
      result.add($e)

proc events(hex: string): seq[string] =
  result = contentEvents(parseCbor(bytes(hex)))
  # the streaming decoder must agree with the one over a string
  let streamed = contentEvents(parseCbor(trickle(bytes(hex))))
  if streamed != result:
    echo "  streamed ", hex, " -> ", streamed
    raise newException(AssertionDefect, "streamed decoding differs")

proc decodes(hex: string, expected: varargs[string]): bool =
  result = events(hex) == @expected
  if not result: echo "  ", hex, " -> ", events(hex)

proc roundTrips(hex: string): bool =
  let output = presentCbor(parseCbor(bytes(hex))).hex
  result = output == hex
  if not result: echo "  ", hex, " -> ", output

proc encodes(yaml, hex: string): bool =
  let output = yamlToCbor(yaml).hex
  result = output == hex
  if not result: echo "  ", yaml, " -> ", output

proc decodeError(hex: string): YamlCborError =
  var streamedMsg = ""
  try:
    for e in parseCbor(trickle(bytes(hex))): discard
  except YamlStreamError as e:
    streamedMsg = e.parent.msg
  try:
    for e in parseCbor(bytes(hex)): discard
  except YamlStreamError as e:
    result = (ref YamlCborError)(e.parent)[]
    # a stream has no known end, so a truncated collection is found where
    # the input ends rather than at its head; the message is the same
    if streamedMsg != result.msg:
      raise newException(AssertionDefect, "streamed error differs for " &
          hex & ": " & streamedMsg)
    return
  raise newException(AssertionDefect, "no error for " & hex)

suite "CBOR streaming":
  test "Each document is written when it is complete":
    proc breaking(): YamlStream =
      ## two documents, then an error instead of the end of the stream
      let events = newBufferYamlStream()
      for e in parser.parse(initYamlParser(), "--- 1\n--- 2\n"): events.put(e)
      initYamlStream(iterator(): Event {.closure, gcsafe.} =
        for e in events:
          if e.kind == yamlEndStream:
            raise newException(IOError, "the input broke")
          yield e)
    let target = newStringStream()
    expect YamlStreamError: presentCbor(breaking(), target)
    check target.data.hex == "0102"

  test "A large document within a budget":
    var items: seq[string]
    for i in 0 ..< 60_000:
      items.add("{\"id\": " & $i & ", \"name\": \"item " & $i & "\"}")
    let data = yamlToCbor("[" & items.join(", ") & "]")
    check data.len > 1_000_000
    let budget = newMemoryBudget(256 * 1024)
    check contentEvents(parseCbor(newStringStream(data), budget)) ==
        contentEvents(parseCbor(data))
    check budget.peak < 256 * 1024
    check budget.used == 0

  test "A declared length is not trusted before the bytes are there":
    # a byte string of 64 GiB, in 11 bytes
    let data = parseHexStr("5B0000001000000000414243")
    let before = max(getMaxMem(), getOccupiedMem())
    try:
      for e in parseCbor(newStringStream(data)): discard
      check false
    except YamlStreamError as e:
      check e.parent of YamlCborError
      check "unexpected end" in e.parent.msg
    check getMaxMem() - before < 1 shl 20

  test "A string larger than the budget":
    let data = yamlToCbor("\"" & repeat('x', 100_000) & "\"")
    try:
      for e in parseCbor(newStringStream(data), newMemoryBudget(64 * 1024)):
        discard
      check false
    except YamlStreamError as e:
      check not memoryLimitError(e).isNil

suite "CBOR decoding (RFC 8949 Appendix A)":
  test "Integers":
    check decodes("00", "=VAL :0")
    check decodes("17", "=VAL :23")
    check decodes("1818", "=VAL :24")
    check decodes("1903e8", "=VAL :1000")
    check decodes("1a000f4240", "=VAL :1000000")
    check decodes("1b000000e8d4a51000", "=VAL :1000000000000")
    check decodes("1bffffffffffffffff", "=VAL :18446744073709551615")
    check decodes("20", "=VAL :-1")
    check decodes("3863", "=VAL :-100")
    check decodes("3bffffffffffffffff", "=VAL :-18446744073709551616")

  test "Bignums":
    check decodes("c249010000000000000000", "=VAL :18446744073709551616")
    check decodes("c349010000000000000000", "=VAL :-18446744073709551617")
    check decodes("c240", "=VAL :0")

  test "Floats":
    check decodes("f90000", "=VAL :0.0")
    check decodes("f98000", "=VAL :-0.0")
    check decodes("f93c00", "=VAL :1.0")
    check decodes("fb3ff199999999999a", "=VAL :1.1")
    check decodes("f97bff", "=VAL :65504.0")
    check decodes("fa47c35000", "=VAL :100000.0")
    check decodes("fa7f7fffff", "=VAL :3.4028234663852886e+38")
    check decodes("fb7e37e43c8800759c", "=VAL :1e+300")
    check decodes("f90001", "=VAL :5.960464477539063e-8")
    check decodes("f90400", "=VAL :0.00006103515625")
    check decodes("f9c400", "=VAL :-4.0")
    check decodes("f97c00", "=VAL :.inf")
    check decodes("f9fc00", "=VAL :-.inf")
    check decodes("f97e00", "=VAL :.nan")
    check decodes("fa7fc00000", "=VAL :.nan")
    check decodes("fb7ff8000000000000", "=VAL :.nan")

  test "Simple values":
    check decodes("f4", "=VAL :false")
    check decodes("f5", "=VAL :true")
    check decodes("f6", "=VAL :null")
    check decodes("f7", "=VAL :null")

  test "Strings":
    check decodes("40", "=VAL <tag:yaml.org,2002:binary> :")
    check decodes("4401020304", "=VAL <tag:yaml.org,2002:binary> :AQIDBA==")
    check decodes("60", "=VAL <!> :")
    check decodes("6449455446", "=VAL <!> :IETF")
    check decodes("62225c", "=VAL <!> :\"\\\\")
    check decodes("62c3bc", "=VAL <!> :ü")
    check decodes("64f0908591", "=VAL <!> :𐅑")

  test "Tags":
    check decodes("c074323031332d30332d32315432303a30343a30305a",
        "=VAL <tag:yaml.org,2002:timestamp> :2013-03-21T20:04:00Z")
    check decodes("c11a514b67b0",
        "=VAL <tag:yaml.org,2002:timestamp> :2013-03-21T20:04:00Z")
    check decodes("c1fb41d452d9ec200000",
        "=VAL <tag:yaml.org,2002:timestamp> :2013-03-21T20:04:00.5Z")
    check decodes("d74401020304", "=VAL <tag:yaml.org,2002:binary> :AQIDBA==")
    check decodes("d818456449455446", "=VAL <tag:yaml.org,2002:binary> :ZElFVEY=")
    check decodes("d82076687474703a2f2f7777772e6578616d706c652e636f6d",
        "=VAL <!> :http://www.example.com")
    check decodes("d9d9f7f5", "=VAL :true")
    check decodes("d82a01", "=VAL <tag:nimyaml.org,2016:cbor:42> :1")
    check decodes("d82a6161", "=VAL <tag:nimyaml.org,2016:cbor:42> \"a")
    check decodes("d82a4161",
        "=VAL <tag:nimyaml.org,2016:cbor:42:binary> :YQ==")
    check decodes("d82a80", "+SEQ <tag:nimyaml.org,2016:cbor:42>", "-SEQ")

  test "Collections":
    check decodes("80", "+SEQ", "-SEQ")
    check decodes("8301820203820405", "+SEQ", "=VAL :1", "+SEQ", "=VAL :2",
        "=VAL :3", "-SEQ", "+SEQ", "=VAL :4", "=VAL :5", "-SEQ", "-SEQ")
    check decodes("a0", "+MAP", "-MAP")
    check decodes("a201020304", "+MAP", "=VAL :1", "=VAL :2", "=VAL :3",
        "=VAL :4", "-MAP")
    check decodes("826161a161626163", "+SEQ", "=VAL <!> :a", "+MAP",
        "=VAL <!> :b", "=VAL <!> :c", "-MAP", "-SEQ")
    check events("98190102030405060708090a0b0c0d0e0f101112131415161718181819").len == 27

  test "Indefinite lengths":
    check decodes("5f42010243030405ff",
        "=VAL <tag:yaml.org,2002:binary> :AQIDBAU=")
    check decodes("7f657374726561646d696e67ff", "=VAL <!> :streaming")
    check decodes("9fff", "+SEQ", "-SEQ")
    check decodes("9f018202039f0405ffff", "+SEQ", "=VAL :1", "+SEQ",
        "=VAL :2", "=VAL :3", "-SEQ", "+SEQ", "=VAL :4", "=VAL :5", "-SEQ",
        "-SEQ")
    check decodes("bf6346756ef563416d7421ff", "+MAP", "=VAL <!> :Fun",
        "=VAL :true", "=VAL <!> :Amt", "=VAL :-2", "-MAP")

  test "Shared values":
    check decodes("82d81c6161d81d00", "+SEQ", "=VAL &s0 <!> :a", "=ALI *s0", "-SEQ")
    check decodes("83d81c80d81c01d81d01", "+SEQ", "+SEQ &s0", "-SEQ",
        "=VAL &s1 :1", "=ALI *s1", "-SEQ")

  test "CBOR sequence":
    var docs = 0
    for e in parseCbor(bytes("0102f6")):
      if e.kind == yamlStartDoc: inc docs
    check docs == 3
    check events("") == newSeq[string]()

suite "CBOR encoding":
  test "Integers":
    check encodes("0", "00")
    check encodes("23", "17")
    check encodes("24", "1818")
    check encodes("1000", "1903e8")
    check encodes("1000000000000", "1b000000e8d4a51000")
    check encodes("18446744073709551615", "1bffffffffffffffff")
    check encodes("18446744073709551616", "c249010000000000000000")
    check encodes("-1", "20")
    check encodes("-1000", "3903e7")
    check encodes("-18446744073709551616", "3bffffffffffffffff")
    check encodes("-18446744073709551617", "c349010000000000000000")
    check encodes("!!int 0x10", "10")
    check encodes("!!int -0o10", "27")
    check encodes("-0", "00")

  test "Floats take the fewest bytes":
    check encodes("0.0", "f90000")
    check encodes("-0.0", "f98000")
    check encodes("1.0", "f93c00")
    check encodes("1.1", "fb3ff199999999999a")
    check encodes("1.5", "f93e00")
    check encodes("65504.0", "f97bff")
    check encodes("100000.0", "fa47c35000")
    check encodes("3.4028234663852886e+38", "fa7f7fffff")
    check encodes("1.0e+300", "fb7e37e43c8800759c")
    check encodes("5.960464477539063e-8", "f90001")
    check encodes("0.00006103515625", "f90400")
    check encodes("-4.1", "fbc010666666666666")
    check encodes(".inf", "f97c00")
    check encodes("-.inf", "f9fc00")
    check encodes(".nan", "f97e00")
    check encodes("!!float 1", "f93c00")

  test "Other scalars":
    check encodes("false", "f4")
    check encodes("True", "f5")
    check encodes("~", "f6")
    check encodes("!!null", "f6")
    check encodes("IETF", "6449455446")
    check encodes("\"1\"", "6131")
    check encodes("'true'", "6474727565")
    check encodes("!!str 1", "6131")
    check encodes("!foo 1", "6131")
    check encodes("ü", "62c3bc")
    check encodes("!!binary AQID BA==", "4401020304")
    check encodes("!!timestamp 2013-03-21T20:04:00Z",
        "c074323031332d30332d32315432303a30343a30305a")
    check encodes("!!timestamp 2013-03-21", "d903ec6a323031332d30332d3231")
    check encodes("!!timestamp 2013-03-21 20:04:00", "73323031332d30332d32312032303a30343a3030")
    check encodes("2013-03-21", "6a323031332d30332d3231")

  test "Collections":
    check encodes("[]", "80")
    check encodes("[1, [2, 3], [4, 5]]", "8301820203820405")
    check encodes("{}", "a0")
    check encodes("{1: 2, 3: 4}", "a201020304")
    check encodes("a: 1\nb: [2, 3]", "a26161016162820203")
    check encodes("- a\n- b: c", "826161a161626163")
    check encodes("? [1]\n: x", "a181016178")

  test "Anchors and aliases":
    check encodes("[&a x, *a]", "82d81c6178d81d00")
    check encodes("[&a [], &b 1, *b, *a]", "84d81c80d81c01d81d01d81d00")
    check encodes("[&a 1, &a 2, *a]", "83d81c01d81c02d81d01")

  test "Multiple documents":
    check encodes("1\n--- 2\n--- [3]", "01028103")
    check encodes("", "")

  test "Invalid scalars":
    for yaml in ["!!int x", "!!float x", "!!bool 1", "!!null x", "!!binary a$"]:
      expect YamlPresenterCborError:
        discard yamlToCbor(yaml)

  test "Round trips":
    for hex in ["00", "1bffffffffffffffff", "3bffffffffffffffff",
        "c249010000000000000000", "c349010000000000000000", "f98000",
        "fb3ff199999999999a", "fa47c35000", "f97e00", "f4", "f6", "40",
        "4401020304", "60", "64f0908591",
        "c074323031332d30332d32315432303a30343a30305a",
        "8301820203820405", "a26161016162820203", "826161a161626163",
        "a1820102a1f5f4", "82d81c6161d81d00", "d82a01", "d82a6161", "d82a4161",
        "d82a80", "d90100a0", "010203"]:
      check roundTrips(hex)

suite "CBOR errors":
  test "Truncated input":
    check decodeError("19").mark.column == 2
    check decodeError("62c3").mark.column == 2
    check decodeError("82").mark.column == 1
    check decodeError("8301").mark.column == 1
    check decodeError("9f01").mark.column == 3

  test "Not well-formed":
    check decodeError("1c").msg.contains("reserved")
    check decodeError("1f").msg.contains("indefinite")
    check decodeError("ff").msg.contains("break")
    check decodeError("f0").msg.contains("simple")
    check decodeError("f818").msg.contains("simple")
    check decodeError("5f6161ff").msg.contains("chunk")
    check decodeError("bf6161016162ff").msg.contains("after a key")
    check decodeError("8201ff").mark.column == 3

  test "Not valid":
    check decodeError("62c328").msg.contains("UTF-8")
    check decodeError("c001").msg.contains("text string")
    check decodeError("c26161").msg.contains("byte string")
    check decodeError("d81d00").msg.contains("not shared")
    check decodeError("d82ad82b01").msg.contains("nested")

suite "CBOR loading and dumping":
  test "Native values":
    let item = Item(name: "x", count: -5, ratio: 0.25,
        tags: @["1", "true", "a"], enabled: true)
    let data = Dumper().dumpCbor(item)
    check data.hex == "a5646e616d65617865636f756e7424657261746" &
        "96ff934006474616773836131647472756561616" &
        "7656e61626c6564f5"
    check loadAsCbor[Item](data) == item
    check loadAsCbor[Item](newStringStream(data)) == item

  test "Strings that look like other types stay strings":
    let data = Dumper().dumpCbor(@["1", "1.5", "null", "false", ""])
    check data.hex == "85613163312e35646e756c6c6566616c736560"
    check loadAsCbor[seq[string]](data) == @["1", "1.5", "null", "false", ""]

  test "Tables, unsigned integers and timestamps":
    check loadAsCbor[Table[string, uint64]](bytes("a161611bffffffffffffffff")) ==
        {"a": high(uint64)}.toTable
    check loadAsCbor[Time](bytes("c11a514b67b0")) == fromUnix(1363896240)

  test "Ref objects share values":
    var n = Node(value: 1)
    n.next = n
    let data = Dumper().dumpCbor(n)
    check data.hex == "d81ca26576616c756501646e657874d81d00"
    let loaded = loadAsCbor[Node](data)
    check loaded.value == 1
    check loaded.next == loaded

  test "CBOR sequences":
    let data = Dumper().dumpCborSequence([@[1'i32], @[2'i32, 3]])
    check data.hex == "8101820203"
    var loaded: seq[seq[int32]]
    loadCborSequence(data, loaded)
    check loaded == @[@[1'i32], @[2'i32, 3]]

  test "Errors":
    expect YamlCborError:
      discard loadAsCbor[int32](bytes("1c"))
    expect YamlConstructionError:
      discard loadAsCbor[int32](bytes("6161"))
    expect YamlConstructionError:
      discard loadAsCbor[int32](bytes("0102"))
    expect YamlConstructionError:
      discard loadAsCbor[int32]("")

  test "Conversion to YAML and JSON":
    let data = bytes("a26161016162820203")
    check cborToYaml(data) == "a: 1\nb: [2, 3]\n"
    check cborToYaml(bytes("a3616101616263666f6f6163f5"),
        jsonDumper().presentation) ==
        "{\n  \"a\": 1,\n  \"b\": \"foo\",\n  \"c\": true\n}\n"
    check yamlToCbor(cborToYaml(data)) == data
    expect YamlCborError:
      discard cborToYaml(bytes("ff"))
    expect YamlParserError:
      discard yamlToCbor("[")

  when not defined(gcArc) or defined(gcOrc):
    test "DOM":
      let node = loadAsCbor[YamlNode](bytes("a26161016162820203"))
      check node.kind == yMapping
      check node["b"][1] == newYamlNode("3")
      check Dumper().dumpCbor(node).hex == "a26161016162820203"
