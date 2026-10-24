#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/jcs. The test vectors of the JCS reference implementations (a
# git submodule) pair JSON inputs with their canonical forms; the inputs are
# loaded with NimYAML, since JSON is YAML. RFC 8785 Appendix B lists number
# serializations by IEEE 754 bit pattern, which pin down ecmaNumber, and the
# remaining tests cover how YAML reads as JSON and what JCS must refuse.

import std/[os, unittest]
import "../yaml", "../yaml/dom", "../yaml/jcs"

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

proc node(yaml: string): YamlNode = loadAs[YamlNode](yaml)

suite "JCS reference test vectors":
  let testdata = currentSourcePath.parentDir / "json-canonicalization" /
      "testdata"
  for file in ["arrays", "french", "structures", "unicode", "values", "weird"]:
    test file:
      let expected = readFile(testdata / "output" / file & ".json")
      check canonicalJson(node(readFile(testdata / "input" / file & ".json"))) ==
          expected

const appendixB = [
  (0x0000000000000000'u64, "0"),
  (0x8000000000000000'u64, "0"),
  (0x0000000000000001'u64, "5e-324"),
  (0x8000000000000001'u64, "-5e-324"),
  (0x7fefffffffffffff'u64, "1.7976931348623157e+308"),
  (0xffefffffffffffff'u64, "-1.7976931348623157e+308"),
  (0x4340000000000000'u64, "9007199254740992"),
  (0xc340000000000000'u64, "-9007199254740992"),
  (0x4430000000000000'u64, "295147905179352830000"),
  (0x44b52d02c7e14af5'u64, "9.999999999999997e+22"),
  (0x44b52d02c7e14af6'u64, "1e+23"),
  (0x44b52d02c7e14af7'u64, "1.0000000000000001e+23"),
  (0x444b1ae4d6e2ef4e'u64, "999999999999999700000"),
  (0x444b1ae4d6e2ef4f'u64, "999999999999999900000"),
  (0x444b1ae4d6e2ef50'u64, "1e+21"),
  (0x3eb0c6f7a0b5ed8c'u64, "9.999999999999997e-7"),
  (0x3eb0c6f7a0b5ed8d'u64, "0.000001"),
  (0x41b3de4355555553'u64, "333333333.3333332"),
  (0x41b3de4355555554'u64, "333333333.33333325"),
  (0x41b3de4355555555'u64, "333333333.3333333"),
  (0x41b3de4355555556'u64, "333333333.3333334"),
  (0x41b3de4355555557'u64, "333333333.33333343"),
  (0xbecbf647612f3696'u64, "-0.0000033333333333333333"),
  (0x43143ff3c1cb0959'u64, "1424953923781206.2"),
]

suite "RFC 8785 Appendix B":
  for (bits, expected) in appendixB:
    test expected:
      check ecmaNumber(cast[float64](bits)) == expected

  test "NaN and infinities have no JSON form":
    for bits in [0x7fffffffffffffff'u64, 0x7ff0000000000000'u64,
        0xfff0000000000000'u64]:
      expect YamlJcsError:
        discard ecmaNumber(cast[float64](bits))

suite "ECMAScript number layout":
  test "plain and scientific":
    check ecmaNumber(1.0) == "1"
    check ecmaNumber(-1.5) == "-1.5"
    check ecmaNumber(100.0) == "100"
    check ecmaNumber(1e20) == "100000000000000000000"
    check ecmaNumber(1e21) == "1e+21"
    check ecmaNumber(1.5e21) == "1.5e+21"
    check ecmaNumber(0.1) == "0.1"
    check ecmaNumber(1e-6) == "0.000001"
    check ecmaNumber(1.5e-7) == "1.5e-7"
    check ecmaNumber(123e-20) == "1.23e-18"

suite "JCS on YAML":
  test "YAML notation is canonicalized":
    check canonicalJson(node("""
numbers: [1.0e+3, .5, -0.0, +15]
"café": ok
flags: [true, ~, "true"]
""")) == """{"café":"ok","flags":[true,null,"true"],"numbers":[1000,0.5,0,15]}"""

  test "aliases are expanded":
    check canonicalJson(node("{a: &x [1], b: *x}")) == """{"a":[1],"b":[1]}"""

  test "tags decide types":
    check canonicalJson(node("[!!str 1, !!float 2, !custom 3, '4']")) ==
        """["1",2,"3","4"]"""

  test "large integers round like doubles":
    check canonicalJson(node("[9007199254740993, 18446744073709551616]")) ==
        "[9007199254740992,18446744073709552000]"

  test "control characters":
    check canonicalJson(node("\"\\u0001\\u001f\\u007f\\t/\"")) ==
        "\"\\u0001\\u001f\x7f\\t/\""

  test "non-string keys are refused":
    for yaml in ["{1: one}", "{[a]: b}", "{null: x}"]:
      expect YamlJcsError:
        discard canonicalJson(node(yaml))

  test "names spelled twice are refused":
    expect YamlJcsError:
      discard canonicalJson(node("{a: 1, \"a\": 2}"))

  test "cycles are refused":
    expect YamlJcsError:
      discard canonicalJson(node("&a [*a]"))

  test "infinity is refused":
    expect YamlJcsError:
      discard canonicalJson(node("[.inf]"))
