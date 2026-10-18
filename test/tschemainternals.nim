#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests the building blocks of yaml/jsonschema beyond what the JSON Schema
# Test Suite exercises: the ECMA-262 regular expression engine, URI reference
# resolution, exact decimals, IDNA processing and the format checks.

import std/unittest
import "../yaml/private/ecmaregex", "../yaml/private/uri",
    "../yaml/private/decimal", "../yaml/private/idna", "../yaml/private/formats"


proc m(pattern, input: string): bool = compileEcmaRegex(pattern).contains(input)

suite "ECMA-262 regular expressions":
  test "anchors and escapes":
    check m("^abc$", "abc")
    check not m("^abc$", "abc\n")
    check m("^\\t$", "\t") and not m("^\\t$", "\\t")
    check m("^\\cC$", "\x03") and m("^\\cc$", "\x03")
    check m("^\\x41\\u0042\\u{43}$", "ABC")
    check m("^\\ud83d\\udc32$", "🐲")

  test "character class escapes":
    check m("^\\d$", "0") and not m("^\\d$", "߀") and m("^\\D$", "߀")
    check not m("^\\w$", "é") and m("^\\W$", "é")
    for s in [" ", "\t", "\v", "\f", "\xC2\xA0", "\xEF\xBB\xBF", "\n",
        "\xE2\x80\xA9", "\xE2\x80\x83"]:
      check m("^\\s$", s)
    check not m("^\\s$", "\x01") and not m("^\\s$", "–")
    check m("\\bfoo\\b", "a foo b") and not m("\\bfoo\\b", "afoo")

  test "Unicode properties":
    check m("\\p{Letter}cole", "l'école") and not m("\\p{Letter}cole", "L'ÉCOLE!")
    check m("^\\p{digit}+$", "৪২") and not m("^\\d+$", "৪২")
    check m("^\\p{Lu}\\P{Lu}$", "Ab") and m("^\\p{gc=Nd}$", "7")
    check m("^\\p{ASCII}+$", "abc") and not m("^\\p{ASCII}$", "é")

  test "code points, not bytes or UTF-16 units":
    check m("^🐲*$", "") and m("^🐲*$", "🐲🐲") and not m("^🐲*$", "🐉")
    check m("^.$", "🐲")

  test "quantifiers":
    check m("a{2,3}", "aa") and not m("^a{2,3}$", "aaaa")
    check m("^(a+)+$", "aaaa")
    check m("^(?:a*)*$", "aaa") and m("^(a*?)b", "aab")
    check m("^x{2,}$", "xxxxx") and not m("^x{2,}$", "x")

  test "alternatives and backtracking":
    check not m("^(a|ab)(c|bcd)(d*)$", "abce")
    check m("^(a|ab)(c|bcd)(d*)$", "abcd")

  test "groups and backreferences":
    check m("^(?<n>a)\\k<n>$", "aa") and not m("^(?<n>a)\\k<n>$", "ab")
    check m("^(a)\\1$", "aa")
    check m("^(?:(a)|b)+$", "ab")
    # captures are reset at the start of each iteration
    check m("^(z)((a+)?(b+)?(c))*$", "zaacbbbcac")
    check m("^(?:(a)|b)\\1$", "aa") and m("^(?:(a)|b)\\1$", "b")

  test "lookaround":
    check m("(?<=a+)b", "aab") and not m("(?<=a+)b", "cb")
    check m("(?<!x)b", "ab") and not m("(?<!x)b", "xb")
    check m("^(?=.*\\d)\\w+$", "ab1") and not m("^(?=.*\\d)\\w+$", "abc")
    check m("^(?!foo)\\w+$", "bar") and not m("^(?!foo)\\w+$", "food")
    check m("(?<=(\\d)(\\d))x\\2", "12x2")

  test "character classes":
    check not m("^[]$", "") and m("^[^]$", "x")
    check m("^[a-c\\d]+$", "a1c") and not m("^[^a-c]$", "b")
    check m("^[\\-]$", "-") and m("^[\\b]$", "\b")

  test "invalid patterns":
    for bad in ["^(abc]", "*a", "[z-a]", "\\", "a)", "[abc", "\\a",
        "(?P<name>x)", "(?P<n>a)(?P=n)", "(?#comment)a", "(?i)abc",
        "(?ims)abc", "a{", "x{2,1}", "\\1", "[\\d-z]", "(?<a>x)(?<a>y)",
        "\\k<missing>(?<a>x)", "\\p{Script=Greek}", "a**", "^*"]:
      check not isEcmaRegex(bad)

  test "valid patterns":
    for good in ["([abc])+\\s+$", "", "a|b", "a{2,3}", "[^a-z]", "a+?",
        "(?<name>x)", "(?<n>a)\\k<n>", "(?<=a+)b", "[]", "[^]", "\\cA",
        "\\p{L}", "\\P{gc=Lu}", "\\u{1F432}", "[\\-]", "\\/", "\\k<a>(?<a>x)"]:
      check isEcmaRegex(good)

  test "long input does not overflow the stack":
    var long = newString(200_000)
    for c in long.mitems: c = 'a'
    check m("^a*$", long) and m("^.*$", long) and m("^(?:a|b)*$", long)

  test "catastrophic backtracking is cut off":
    expect EcmaRegexError:
      discard m("^(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab")

suite "URI references":
  test "RFC 3986, Section 5.4":
    let base = "http://a/b/c/d;p?q"
    for (reference, expected) in [("g:h", "g:h"), ("g", "http://a/b/c/g"),
        ("./g", "http://a/b/c/g"), ("g/", "http://a/b/c/g/"),
        ("/g", "http://a/g"), ("//g", "http://g"), ("?y", "http://a/b/c/d;p?y"),
        ("g?y", "http://a/b/c/g?y"), ("#s", "http://a/b/c/d;p?q#s"),
        ("g#s", "http://a/b/c/g#s"), (";x", "http://a/b/c/;x"),
        ("", "http://a/b/c/d;p?q"), (".", "http://a/b/c/"),
        ("./", "http://a/b/c/"), ("..", "http://a/b/"), ("../", "http://a/b/"),
        ("../g", "http://a/b/g"), ("../..", "http://a/"),
        ("../../", "http://a/"), ("../../g", "http://a/g"),
        ("../../../g", "http://a/g"), ("../../../../g", "http://a/g"),
        ("/./g", "http://a/g"), ("/../g", "http://a/g"),
        ("g.", "http://a/b/c/g."), (".g", "http://a/b/c/.g"),
        ("g..", "http://a/b/c/g.."), ("..g", "http://a/b/c/..g"),
        ("./../g", "http://a/b/g"), ("./g/.", "http://a/b/c/g/"),
        ("g/./h", "http://a/b/c/g/h"), ("g/../h", "http://a/b/c/h"),
        ("g;x=1/./y", "http://a/b/c/g;x=1/y"), ("g;x=1/../y", "http://a/b/c/y"),
        ("g?y/./x", "http://a/b/c/g?y/./x"), ("g#s/../x", "http://a/b/c/g#s/../x")]:
      check resolve(base, reference) == expected

  test "URNs and relative bases":
    check resolve("urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed",
        "#/$defs/bar") == "urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed#/$defs/bar"
    check resolve("", "#foo") == "#foo"
    check resolve("", "a/b") == "a/b"

  test "validation":
    check isUri("http://[2001:db8::1]:80/a?b#c")
    check not isUri("//foo") and not isUri("http://a b") and not isUri("a")
    check isUriReference("//foo") and isUriReference("#/a%20b")
    check not isUriReference("\\\\WINDOWS\\fileshare")
    check isIri("http://ƒøø.ßår/?∂éœ=πîx#πîüx") and not isUri("http://ƒøø.ßår/")
    check isIpv6("::ffff:192.168.0.1") and isIpv6("1::") and isIpv6("::")
    check not isIpv6("1:::2") and not isIpv6("12345::") and not isIpv6("1:2:3")
    check isIpv4("192.168.0.1") and not isIpv4("087.10.0.1") and
        not isIpv4("256.0.0.1")

suite "Decimals":
  proc d(s: string): Decimal =
    check parseDecimal(s, result)

  test "parsing":
    var x: Decimal
    check not parseDecimal("0x1F", x) and not parseDecimal("1e", x) and
        not parseDecimal(".", x) and not parseDecimal("inf", x)
    check $d("1.0") == "1" and $d("-1.5e-10") == "-1.5e-10"
    check $d("0.0010") == "0.001" and $d("12e2") == "1200" and $d("-0") == "0"

  test "comparison":
    check d("972783798187987123879878123.18878137") <
        d("972783798187987123879878123.188781371")
    check d("1") == d("1.000") and d("-2") < d("-1") and d("0.1") < d("1")
    check d("1e400") > d("9e399") and d("-1e-400") < d("0")

  test "multiples":
    var multiple: bool
    check isMultipleOf(d("0.0075"), d("0.0001"), multiple) and multiple
    check isMultipleOf(d("0.00751"), d("0.0001"), multiple) and not multiple
    check isMultipleOf(d("1e308"), d("0.5"), multiple) and multiple
    check isMultipleOf(d("4.5"), d("1.5"), multiple) and multiple
    check isMultipleOf(d("35"), d("1.5"), multiple) and not multiple
    check d("1.0").isInteger and not d("1.5").isInteger and d("1e3").isInteger

suite "IDNA host names":
  test "valid names":
    for name in ["hostname", "www.example.com", "실례.테스트",
        "xn--ihqwcrb4cv8a8dqg056pqjye", "l·l", "xn--NXASMQ6B", "１２３",
        "a​b", "café.com", "a。b", "بي‌بي"]:
      check isIdnaHostname(name)

  test "invalid names":
    for name in ["", ".", "a..b", "example.", "-hello", "hello-", "xn--X",
        "̀hello", "a·l", "ـߺ", "ب٠۰",
        "क‍ष", "aא", "0a.א", "xn--example-",
        "xn---9uc", "a_b"]:
      check not isIdnaHostname(name)

  test "ASCII host names":
    check isHostname("xn--9n2bp8q.xn--9t4b11yi5a")
    check not isHostname("xn--07jt112bpxg.xn--9t4b11yi5a")
    check isHostname("a--b.com")
    check not isHostname("ab--cd.example") and isHostname("ab--cd.example", idna = false)
    check not isHostname("Kelvin.example.com")

suite "Formats":
  test "dates and times":
    check isDateTime("1998-12-31T23:59:60Z")
    check isTime("15:59:60-08:00") and not isTime("23:59:60+01:00")
    check not isDate("2021-02-29") and isDate("2020-02-29") and
        not isDate("2100-02-29") and isDate("2000-02-29")
    check isDuration("P1Y2M3DT4H5M6S") and isDuration("P2W") and
        not isDuration("P1Y2D") and not isDuration("PT") and
        not isDuration("P1WT1H")

  test "e-mail addresses":
    check isEmail("\"joe bloggs\"@example.com") and isEmail("a@[IPv6:::1]")
    check not isEmail("te..st@example.com") and not isEmail("a@b@c.org")
    check isIdnEmail("δοκιμή@example.com") and not isEmail("δοκιμή@example.com")

  test "pointers and identifiers":
    check isJsonPointer("/a~1b/~0") and not isJsonPointer("/~2")
    check isRelativeJsonPointer("0#") and isRelativeJsonPointer("1/a") and
        not isRelativeJsonPointer("01") and not isRelativeJsonPointer("-1")
    check isUuid("2EB8AA08-AA98-11EA-B4AA-73B441D16380") and
        not isUuid("2eb8aa08-aa98-11ea-b4aa-73b441d1638")
