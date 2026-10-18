#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## URI references as JSON Schema uses them: identifying schema resources,
## resolving ``$ref`` against base URIs, and validating the ``uri``,
## ``uri-reference``, ``iri`` and ``iri-reference`` formats.
##
## ``std/uri`` is not used because its ``combine`` does not implement
## RFC 3986, Section 5.2 (it mishandles ``..`` and empty paths) and its
## parser accepts anything. Here, ``parseReference`` splits any string the
## way RFC 3986, Appendix B does, and ``resolve`` follows Section 5.2.2
## exactly. Validation is separate, in ``isUri`` and friends, which check
## the full grammar of RFC 3986 and RFC 3987.

import std/strutils

type
  UriReference* = object
    ## The five components of a URI reference. A component that is absent
    ## differs from one that is empty: ``a:b?`` has an empty query and ``a:b``
    ## none.
    scheme*, authority*, path*, query*, fragment*: string
    hasScheme*, hasAuthority*, hasQuery*, hasFragment*: bool

proc parseReference*(s: string): UriReference {.raises: [].} =
  ## Splits ``s`` into its components following the regular expression of
  ## RFC 3986, Appendix B. Never fails; use ``isUriReference`` to check
  ## whether ``s`` is well-formed.
  var i = 0
  # scheme: up to the first ':' if it comes before any of '/?#'
  var j = 0
  while j < s.len and s[j] notin {':', '/', '?', '#'}: inc(j)
  if j < s.len and j > 0 and s[j] == ':':
    result.hasScheme = true
    result.scheme = s[0 ..< j]
    i = j + 1
  if i + 1 < s.len and s[i] == '/' and s[i + 1] == '/':
    result.hasAuthority = true
    j = i + 2
    while j < s.len and s[j] notin {'/', '?', '#'}: inc(j)
    result.authority = s[i + 2 ..< j]
    i = j
  j = i
  while j < s.len and s[j] notin {'?', '#'}: inc(j)
  result.path = s[i ..< j]
  i = j
  if i < s.len and s[i] == '?':
    result.hasQuery = true
    j = i + 1
    while j < s.len and s[j] != '#': inc(j)
    result.query = s[i + 1 ..< j]
    i = j
  if i < s.len and s[i] == '#':
    result.hasFragment = true
    result.fragment = s[i + 1 .. ^1]

proc `$`*(r: UriReference): string {.raises: [].} =
  ## Recomposes the reference (RFC 3986, Section 5.3).
  if r.hasScheme: result.add(r.scheme & ":")
  if r.hasAuthority: result.add("//" & r.authority)
  result.add(r.path)
  if r.hasQuery: result.add("?" & r.query)
  if r.hasFragment: result.add("#" & r.fragment)

proc removeDotSegments(path: string): string =
  ## RFC 3986, Section 5.2.4.
  var input = path
  while input.len > 0:
    if input.startsWith("../"): input = input[3 .. ^1]
    elif input.startsWith("./"): input = input[2 .. ^1]
    elif input.startsWith("/./"): input = input[2 .. ^1]
    elif input == "/.": input = "/"
    elif input.startsWith("/../") or input == "/..":
      input = "/" & input[(if input == "/..": 3 else: 4) .. ^1]
      let slash = result.rfind('/')
      result.setLen(max(slash, 0))
    elif input == "." or input == "..": input = ""
    else:
      var j = (if input[0] == '/': 1 else: 0)
      while j < input.len and input[j] != '/': inc(j)
      result.add(input[0 ..< j])
      input = input[j .. ^1]

proc resolve*(base: UriReference, reference: UriReference): UriReference
    {.raises: [].} =
  ## Resolves ``reference`` against ``base`` (RFC 3986, Section 5.2.2, strict
  ## mode). ``base`` should be absolute; if it is not, the result is as
  ## relative as ``base`` is, which is what JSON Schema needs for schemas
  ## that have no absolute URI.
  if reference.hasScheme:
    result = reference
    result.path = removeDotSegments(reference.path)
  else:
    result.hasScheme = base.hasScheme
    result.scheme = base.scheme
    if reference.hasAuthority:
      result.hasAuthority = true
      result.authority = reference.authority
      result.path = removeDotSegments(reference.path)
      result.hasQuery = reference.hasQuery
      result.query = reference.query
    else:
      result.hasAuthority = base.hasAuthority
      result.authority = base.authority
      if reference.path.len == 0:
        result.path = base.path
        if reference.hasQuery:
          result.hasQuery = true
          result.query = reference.query
        else:
          result.hasQuery = base.hasQuery
          result.query = base.query
      else:
        if reference.path[0] == '/':
          result.path = removeDotSegments(reference.path)
        else:
          # merge (Section 5.2.3)
          var merged: string
          if base.hasAuthority and base.path.len == 0:
            merged = "/" & reference.path
          else:
            let slash = base.path.rfind('/')
            merged = base.path[0 .. slash] & reference.path
          # a relative base keeps leading '..' segments that cannot be
          # removed; only remove dot segments if there is a root to stop at
          if merged.startsWith("/") or base.hasScheme or base.hasAuthority:
            result.path = removeDotSegments(merged)
          else:
            result.path = merged
        result.hasQuery = reference.hasQuery
        result.query = reference.query
  result.hasFragment = reference.hasFragment
  result.fragment = reference.fragment

proc resolve*(base, reference: string): string {.raises: [].} =
  ## Resolves the URI reference ``reference`` against ``base``.
  $resolve(parseReference(base), parseReference(reference))

proc withoutFragment*(uri: string): string {.raises: [].} =
  let hash = uri.find('#')
  result = if hash < 0: uri else: uri[0 ..< hash]

proc fragment*(uri: string): string {.raises: [].} =
  ## The fragment of ``uri`` without ``#``; empty if there is none.
  let hash = uri.find('#')
  result = if hash < 0: "" else: uri[hash + 1 .. ^1]

proc isAbsolute*(uri: string): bool {.raises: [].} =
  ## Whether ``uri`` has a scheme.
  parseReference(uri).hasScheme

proc hexValue(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  else: ord(c) - ord('A') + 10

proc percentDecode*(s: string): string {.raises: [].} =
  ## Decodes ``%XX`` sequences; leaves malformed ones as they are.
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and
        s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      result.add(char(hexValue(s[i + 1]) * 16 + hexValue(s[i + 2])))
      i += 3
    else:
      result.add(s[i])
      inc(i)

# ----------------------------------------------------------------------------
# Validation (RFC 3986, Section 3 and Appendix A; RFC 3987, Section 2.2)
# ----------------------------------------------------------------------------

const
  unreserved = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}
  subDelims = {'!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '='}

proc isIpv4*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is a dotted-quad IPv4 address (RFC 2673, Section 3.2):
  ## four decimal octets without leading zeros.
  let parts = s.split('.')
  if parts.len != 4: return false
  for part in parts:
    if part.len == 0 or part.len > 3: return false
    for c in part:
      if c notin Digits: return false
    if part.len > 1 and part[0] == '0': return false
    var value = 0
    for c in part: value = value * 10 + ord(c) - ord('0')
    if value > 255: return false
  result = true

proc isIpv6*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is an IPv6 address as in RFC 4291, Section 2.2, including
  ## the ``::`` shorthand and a trailing IPv4 address. Zone identifiers are
  ## not allowed.
  if s.len == 0: return false
  var
    groups = 0
    compressed = false
    i = 0
  if s.startsWith("::"):
    compressed = true
    i = 2
    if s.len == 2: return true
  elif s[0] == ':': return false
  while i < s.len:
    # a group: hex digits, or an IPv4 address at the end
    var j = i
    while j < s.len and s[j] in HexDigits: inc(j)
    if j < s.len and s[j] == '.':
      if not isIpv4(s[i .. ^1]): return false
      groups += 2
      i = s.len
      break
    if j == i or j - i > 4: return false
    inc(groups)
    i = j
    if i == s.len: break
    if s[i] != ':': return false
    inc(i)
    if i < s.len and s[i] == ':':
      if compressed: return false
      compressed = true
      inc(i)
      if i == s.len: break
    elif i == s.len: return false # trailing single ':'
  result = if compressed: groups <= 7 else: groups == 8


proc pctEncoded(s: string, i: var int): bool =
  if i + 2 < s.len and s[i] == '%' and
      s[i + 1] in HexDigits and s[i + 2] in HexDigits:
    i += 3
    return true
  result = false

proc ucsChar(s: string, i: var int, private: bool): bool =
  ## Consumes one UTF-8 encoded code point allowed in IRIs by RFC 3987
  ## (``ucschar``, or ``iprivate`` if ``private``).
  if i >= s.len or ord(s[i]) < 0x80: return false
  let
    c = ord(s[i])
    length = if c shr 5 == 0b110: 2 elif c shr 4 == 0b1110: 3
             elif c shr 3 == 0b11110: 4 else: 0
  if length == 0 or i + length > s.len: return false
  var cp = c and (0xFF shr (length + 1))
  for k in 1 ..< length:
    let b = ord(s[i + k])
    if b shr 6 != 0b10: return false
    cp = cp shl 6 or (b and 0x3F)
  let ok =
    if private:
      (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD) or
          (cp >= 0x100000 and cp <= 0x10FFFD)
    else:
      (cp >= 0xA0 and cp <= 0xD7FF) or (cp >= 0xF900 and cp <= 0xFDCF) or
          (cp >= 0xFDF0 and cp <= 0xFFEF) or
          (cp >= 0x10000 and cp <= 0xEFFFD and (cp and 0xFFFF) <= 0xFFFD)
  if ok: i += length
  result = ok

proc unreservedChar(s: string, i: var int, iri: bool): bool =
  if i < s.len and s[i] in unreserved:
    inc(i)
    return true
  result = iri and ucsChar(s, i, false)

proc pchar(s: string, i: var int, iri: bool, extra: set[char]): bool =
  if i < s.len and s[i] in subDelims + extra:
    inc(i)
    return true
  result = unreservedChar(s, i, iri) or pctEncoded(s, i)

proc ipLiteral(s: string): bool =
  ## ``IP-literal`` without the brackets.
  if s.len > 0 and s[0] in {'v', 'V'}:
    # IPvFuture
    var i = 1
    while i < s.len and s[i] in HexDigits: inc(i)
    if i == 1 or i >= s.len or s[i] != '.': return false
    inc(i)
    if i == s.len: return false
    while i < s.len:
      if s[i] notin unreserved + subDelims + {':'}: return false
      inc(i)
    return true
  result = isIpv6(s)

proc validAuthority(s: string, iri: bool): bool =
  var hostPart = s
  let at = s.rfind('@')
  if at >= 0:
    var i = 0
    while i < at:
      if not pchar(s, i, iri, {':'}) or i > at: return false
    hostPart = s[at + 1 .. ^1]
  # port
  var host = hostPart
  if hostPart.len > 0 and hostPart[0] == '[':
    let close = hostPart.find(']')
    if close < 0: return false
    if not ipLiteral(hostPart[1 ..< close]): return false
    let rest = hostPart[close + 1 .. ^1]
    if rest.len > 0:
      if rest[0] != ':': return false
      for c in rest[1 .. ^1]:
        if c notin Digits: return false
    return true
  let colon = hostPart.rfind(':')
  if colon >= 0:
    for c in hostPart[colon + 1 .. ^1]:
      if c notin Digits: return false
    host = hostPart[0 ..< colon]
  # reg-name (covers IPv4address)
  var i = 0
  while i < host.len:
    if not pchar(host, i, iri, {}): return false
  result = true

proc validPath(s: string, iri: bool): bool =
  var i = 0
  while i < s.len:
    if s[i] == '/': inc(i)
    elif not pchar(s, i, iri, {':', '@'}): return false
  result = true

proc validQueryOrFragment(s: string, iri, query: bool): bool =
  var i = 0
  while i < s.len:
    if s[i] in {'/', '?'}: inc(i)
    elif query and iri and ucsChar(s, i, true): discard
    elif not pchar(s, i, iri, {':', '@'}): return false
  result = true

proc validReference(s: string, iri, requireScheme: bool): bool =
  let r = parseReference(s)
  if requireScheme and not r.hasScheme: return false
  if r.hasScheme:
    if r.scheme[0] notin Letters: return false
    for c in r.scheme:
      if c notin Letters + Digits + {'+', '-', '.'}: return false
  if r.hasAuthority:
    if not validAuthority(r.authority, iri): return false
    if r.path.len > 0 and r.path[0] != '/': return false
  elif r.path.startsWith("//"): return false
  elif not r.hasScheme:
    # relative-part: the first segment of a relative path must not have ':'
    let slash = r.path.find('/')
    let first = if slash < 0: r.path else: r.path[0 ..< slash]
    if ':' in first: return false
  if not validPath(r.path, iri): return false
  if r.hasQuery and not validQueryOrFragment(r.query, iri, true): return false
  if r.hasFragment and not validQueryOrFragment(r.fragment, iri, false):
    return false
  result = true

proc isUri*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is a ``URI`` as defined by RFC 3986 (with a scheme).
  validReference(s, false, true)

proc isUriReference*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is a ``URI-reference`` as defined by RFC 3986.
  validReference(s, false, false)

proc isIri*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is an ``IRI`` as defined by RFC 3987.
  validReference(s, true, true)

proc isIriReference*(s: string): bool {.raises: [].} =
  ## Whether ``s`` is an ``IRI-reference`` as defined by RFC 3987.
  validReference(s, true, false)
