#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[json, os, streams, strutils, unittest]
when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]
import ../tools/yamllsp

proc request(id: int, meth: string, params = newJObject()): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params}

proc notification(meth: string, params = newJObject()): JsonNode =
  %*{"jsonrpc": "2.0", "method": meth, "params": params}

proc didOpen(uri, text: string): JsonNode =
  notification("textDocument/didOpen", %*{"textDocument": {"uri": uri,
      "languageId": "yaml", "version": 1, "text": text}})

proc diagnosticsOf(replies: seq[JsonNode], uri: string): JsonNode =
  for r in replies:
    if r{"method"}.getStr() == "textDocument/publishDiagnostics" and
        r["params"]["uri"].getStr() == uri:
      return r["params"]["diagnostics"]
  nil

suite "LSP framing":
  test "frame and read back":
    let a = %*{"jsonrpc": "2.0", "id": 1, "method": "x"}
    let b = %*{"text": "é"}
    let s = newStringStream(frame(a) & frame(b))
    check readMessage(s) == a
    check readMessage(s) == b
    check readMessage(s).isNil

  test "header names are case-insensitive, other headers ignored":
    let s = newStringStream(
        "content-length: 2\r\nContent-Type: application/json\r\n\r\n{}")
    check readMessage(s) == newJObject()

  test "missing Content-Length":
    expect ValueError:
      discard readMessage(newStringStream("X: 1\r\n\r\n{}"))

suite "LSP positions":
  test "UTF-16 columns":
    check utf16Column("abc", 1) == 0
    check utf16Column("abc", 4) == 3
    check utf16Column("é", 3) == 1
    check utf16Column("😀x", 5) == 2
    check utf16Column("😀x", 6) == 3
    check utf16Column("ab", 5) == 4

suite "LSP server":
  test "initialize":
    var s: Server
    let replies = s.handle(request(1, "initialize"))
    check replies.len == 1
    check replies[0]["id"].getInt() == 1
    check replies[0]["result"]["capabilities"]["textDocumentSync"]["change"].getInt() == 1

  test "didOpen publishes diagnostics":
    var s: Server
    let diags = s.handle(didOpen("untitled:a", "a: 1\na: 2\n")).diagnosticsOf("untitled:a")
    check diags.len == 1
    check diags[0]["range"] == %*{"start": {"line": 1, "character": 0},
        "end": {"line": 1, "character": 1}}
    check diags[0]["severity"].getInt() == 1
    check diags[0]["code"].getStr() == "duplicate-key"
    check diags[0]["source"].getStr() == "nimyaml"

  test "positions are UTF-16":
    var s: Server
    let diags = s.handle(didOpen("untitled:a", "é: yes\n")).diagnosticsOf("untitled:a")
    check diags.len == 1
    check diags[0]["range"] == %*{"start": {"line": 0, "character": 3},
        "end": {"line": 0, "character": 6}}
    check diags[0]["severity"].getInt() == 2

  test "didChange replaces the text, didClose clears":
    var s: Server
    discard s.handle(didOpen("untitled:a", "a: 1\na: 2\n"))
    let changed = s.handle(notification("textDocument/didChange", %*{
        "textDocument": {"uri": "untitled:a", "version": 2},
        "contentChanges": [{"text": "a: 1\n"}]}))
    check changed.diagnosticsOf("untitled:a").len == 0
    discard s.handle(didOpen("untitled:b", "a: 1\na: 2\n"))
    let closed = s.handle(notification("textDocument/didClose",
        %*{"textDocument": {"uri": "untitled:b"}}))
    check closed.diagnosticsOf("untitled:b").len == 0

  test "config from the file system, reloaded on save":
    let dir = getTempDir() / ("yamllsp-test-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let config = dir / ".nimyaml-lint.yaml"
    writeFile(config, "rules:\n  truthy: {level: error}\n")
    let uri = "file://" & dir / "x.yaml"
    var s: Server
    let opened = s.handle(didOpen(uri, "k: yes\n")).diagnosticsOf(uri)
    check opened.len == 1
    check opened[0]["severity"].getInt() == 1
    writeFile(config, "rules:\n  truthy: {level: off}\n")
    let saved = s.handle(notification("textDocument/didSave",
        %*{"textDocument": {"uri": "file://" & config}}))
    check saved.diagnosticsOf(uri).len == 0
    writeFile(config, "rules:\n  nope: {}\n")
    let invalid = s.handle(notification("textDocument/didSave",
        %*{"textDocument": {"uri": "file://" & config}})).diagnosticsOf(uri)
    check invalid.len == 2
    check invalid[0]["code"].getStr() == "config"
    check "unknown rule: nope" in invalid[0]["message"].getStr()

  test "unknown requests and notifications":
    var s: Server
    let replies = s.handle(request(7, "textDocument/formatting"))
    check replies.len == 1
    check replies[0]["error"]["code"].getInt() == -32601
    check s.handle(notification("$/whatever")).len == 0

  test "shutdown, then exit":
    var s: Server
    let replies = s.handle(request(2, "shutdown"))
    check replies[0]["result"].kind == JNull
    discard s.handle(notification("exit"))
    check s.exited
    check s.exitCode == 0

  test "exit without shutdown":
    var s: Server
    discard s.handle(notification("exit"))
    check s.exited
    check s.exitCode == 1

suite "LSP directive features":
  const stream = """%GLOBAL TAG !e! tag:example.com,2000:
%GLOBAL SCHEMA https://x.example/global.json
--- !e!a 1
...
%TAG !e! tag:local:
%SCHEMA https://x.example/second.json
--- !e!b 2
...
--- !e!c 3
"""
  proc at(meth, uri: string, line, character: int): JsonNode =
    request(1, meth, %*{"textDocument": {"uri": uri},
        "position": {"line": line, "character": character}})

  proc answer(s: var Server, msg: JsonNode): JsonNode =
    s.handle(msg)[0]["result"]

  test "capabilities":
    var s: Server
    let c = s.answer(request(1, "initialize"))["capabilities"]
    check c["hoverProvider"].getBool()
    check c["definitionProvider"].getBool()
    check c["completionProvider"]["triggerCharacters"] == %["%", " "]
    check c.hasKey("documentLinkProvider")

  test "byteColumn inverts utf16Column":
    for (line, units) in [("abc", 2), ("é:x", 1), ("😀x", 2), ("ab", 5)]:
      check utf16Column(line, byteColumn(line, units)) == units

  test "completion of directive names":
    var s: Server
    discard s.handle(didOpen("untitled:c", "%\n%GLOBAL \n%GL\nkey: %\n"))
    var labels: seq[string]
    for item in s.answer(at("textDocument/completion", "untitled:c", 0, 1)):
      labels.add(item["label"].getStr())
    check labels == @["YAML", "TAG", "SCHEMA", "GLOBAL"]
    labels.setLen(0)
    for item in s.answer(at("textDocument/completion", "untitled:c", 1, 8)):
      labels.add(item["label"].getStr())
    check labels == @["YAML", "TAG", "SCHEMA"]
    check s.answer(at("textDocument/completion", "untitled:c", 2, 3)).len == 4
    check s.answer(at("textDocument/completion", "untitled:c", 3, 6)).len == 0

  test "hover on a global directive":
    var s: Server
    discard s.handle(didOpen("untitled:h", stream))
    let r = s.answer(at("textDocument/hover", "untitled:h", 0, 3))
    let text = r["contents"]["value"].getStr()
    check "%TAG !e! tag:example.com,2000:" in text
    check "Global" in text
    check "all 3 documents" in text
    check "except document 2, which overrides it" in text
    check r["range"]["start"] == %*{"line": 0, "character": 0}

  test "hover on a per-document directive":
    var s: Server
    discard s.handle(didOpen("untitled:h", stream))
    let tag = s.answer(at("textDocument/hover", "untitled:h", 4, 2))
    check "document 2 only" in tag["contents"]["value"].getStr()
    check "Overrides the global `%TAG !e! tag:example.com,2000:` (line 1)" in
        tag["contents"]["value"].getStr()
    let schema = s.answer(at("textDocument/hover", "untitled:h", 5, 2))
    check "https://x.example/second.json" in schema["contents"]["value"].getStr()

  test "hover on an ignored directive":
    var s: Server
    discard s.handle(didOpen("untitled:i", "a\n...\n%GLOBAL YAML 1.2\n--- b\n"))
    let r = s.answer(at("textDocument/hover", "untitled:i", 2, 2))
    check "misplaced-global-directive" in r["contents"]["value"].getStr()

  test "hover on document markers":
    var s: Server
    discard s.handle(didOpen("untitled:h", stream))
    let second = s.answer(at("textDocument/hover", "untitled:h", 6, 1))
    let text = second["contents"]["value"].getStr()
    check "**Document 2**" in text
    check "`%TAG !e! tag:local:` (document, line 5)" in text
    check "tag:example.com" notin text # overridden
    check "<https://x.example/second.json> (%SCHEMA, line 6)" in text
    let thirdHover = s.answer(at("textDocument/hover", "untitled:h", 8, 0))
    let third = thirdHover["contents"]["value"].getStr()
    check "`%TAG !e! tag:example.com,2000:` (global, line 1)" in third
    check "(%GLOBAL SCHEMA, line 2)" in third
    let ending = s.answer(at("textDocument/hover", "untitled:h", 3, 0))
    check "**Document 1**" in ending["contents"]["value"].getStr()
    check s.answer(at("textDocument/hover", "untitled:h", 2, 6)).kind == JNull

  test "definition and document links of schema references":
    var s: Server
    discard s.handle(didOpen("untitled:h", stream))
    let d = s.answer(at("textDocument/definition", "untitled:h", 5, 12))
    check d["uri"].getStr() == "https://x.example/second.json"
    check s.answer(at("textDocument/definition", "untitled:h", 5, 3)).kind == JNull
    let links = s.answer(request(1, "textDocument/documentLink",
        %*{"textDocument": {"uri": "untitled:h"}}))
    var targets: seq[string]
    for l in links: targets.add(l["target"].getStr())
    check targets == @["https://x.example/global.json",
        "https://x.example/second.json"]
    check links[1]["range"] == %*{"start": {"line": 5, "character": 8},
        "end": {"line": 5, "character": 37}}

  test "relative schema references resolve against the document":
    let dir = getTempDir() / ("yamllsp-schema-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "s.yaml", "{type: object, required: [name]}\n")
    let uri = "file://" & dir / "x.yaml"
    var s: Server
    let diags = s.handle(didOpen(uri, "%SCHEMA s.yaml\n--- {age: 3}\n"))
        .diagnosticsOf(uri)
    check diags.len == 1
    check diags[0]["code"].getStr() == "schema-validation"
    check diags[0]["range"]["start"] == %*{"line": 1, "character": 4}
    let link = s.answer(request(1, "textDocument/documentLink",
        %*{"textDocument": {"uri": uri}}))
    check link[0]["target"].getStr() == "file://" & dir / "s.yaml"

  test ".yaml config: lint rules and schema validation, reloaded on save":
    let dir = getTempDir() / ("yamllsp-config-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "s.yaml", "{type: object, required: [name]}\n")
    let config = dir / ".yaml"
    writeFile(config, "lint: {rules: {truthy: {level: off}}}\n" &
        "validate: {schema: false}\n")
    let uri = "file://" & dir / "x.yaml"
    var s: Server
    check s.handle(didOpen(uri, "%SCHEMA s.yaml\n--- {age: yes}\n"))
        .diagnosticsOf(uri).len == 0
    writeFile(config, "")
    let saved = s.handle(notification("textDocument/didSave",
        %*{"textDocument": {"uri": "file://" & config}})).diagnosticsOf(uri)
    check saved.len == 2
    writeFile(config, "nope: 1\n")
    let invalid = s.handle(notification("textDocument/didSave",
        %*{"textDocument": {"uri": "file://" & config}})).diagnosticsOf(uri)
    check invalid[0]["code"].getStr() == "config"
    check "Unknown field" in invalid[0]["message"].getStr()

  test "directive diagnostics":
    var s: Server
    let diags = s.handle(didOpen("untitled:d", "%SCHEMA s.json\n--- a\n"))
        .diagnosticsOf("untitled:d")
    check diags.len == 1
    check diags[0]["code"].getStr() == "unresolvable-schema-uri"
    check diags[0]["severity"].getInt() == 1

suite "LSP semantic tokens":
  proc legend(): JsonNode =
    var s: Server
    s.handle(request(1, "initialize"))[0]["result"]["capabilities"][
        "semanticTokensProvider"]["legend"]

  proc highlights(text: string): seq[string] =
    ## The decoded tokens of ``text`` as ``"line text type[+modifier]"``;
    ## ``text`` must be ASCII so that UTF-16 offsets are byte offsets.
    let types = legend()["tokenTypes"]
    let modifiers = legend()["tokenModifiers"]
    var s: Server
    discard s.handle(didOpen("untitled:t", text))
    let data = s.handle(request(1, "textDocument/semanticTokens/full",
        %*{"textDocument": {"uri": "untitled:t"}}))[0]["result"]["data"]
    let lines = text.splitLines()
    var line, start = 0
    for i in countup(0, data.len - 1, 5):
      if data[i].getInt() > 0: start = 0
      line += data[i].getInt()
      start += data[i + 1].getInt()
      var entry = $line & " " &
          lines[line][start ..< start + data[i + 2].getInt()] & " " &
          types[data[i + 3].getInt()].getStr()
      for bit in 0 ..< modifiers.len:
        if (data[i + 4].getInt() and (1 shl bit)) != 0:
          entry.add("+" & modifiers[bit].getStr())
      result.add(entry)

  test "capability":
    check "property" in legend()["tokenTypes"].to(seq[string])
    check legend()["tokenModifiers"] == %["declaration"]

  test "directives and markers":
    check highlights("%GLOBAL TAG !e! tag:x,2000: # c\n%YAML 1.2\n" &
        "%SCHEMA s.json\n--- !e!a b\n...\n") == @[
      "0 %GLOBAL keyword", "0 TAG keyword", "0 !e! namespace",
      "0 tag:x,2000: string", "0 # c comment",
      "1 %YAML keyword", "1 1.2 number",
      "2 %SCHEMA keyword", "2 s.json string",
      "3 --- keyword", "3 !e! type", "3 a type", "3 b string",
      "4 ... keyword"]

  test "keys, values, properties and comments":
    check highlights("# top\nkey: \"two\n  lines\"  # c\n? &a k\n: *a\n" &
        "n: [1, true, ~, x, \"q\": !!str 2.5]\n") == @[
      "0 # top comment",
      "1 key property", "1 : operator", "1 \"two string",
      "2 lines\" string", "2 # c comment",
      "3 ? operator", "3 &a variable+declaration", "3 k property",
      "4 : operator", "4 *a variable",
      "5 n property", "5 : operator", "5 [ operator", "5 1 number",
      "5 , operator", "5 true keyword", "5 , operator", "5 ~ keyword",
      "5 , operator", "5 x string", "5 , operator", "5 \"q\" property",
      "5 : operator", "5 !! type", "5 str type", "5 2.5 number",
      "5 ] operator"]

  test "block scalars: header, its comment, content":
    check highlights("- |- # h\n  text\n\n  # not a comment\n- > \n x\n") == @[
      "0 - operator", "0 |- operator", "0 # h comment",
      "1 text string", "3 # not a comment string",
      "4 - operator", "4 > operator", "5 x string"]

  test "lexer errors skip to the next document":
    check highlights("a: \"x\n--- b # c\n") == @[
      "0 a property", "0 : operator", "1 --- keyword", "1 b string",
      "1 # c comment"]

  test "UTF-16 positions":
    var s: Server
    discard s.handle(didOpen("untitled:u", "é: 😀 # ü\n"))
    let data = s.handle(request(1, "textDocument/semanticTokens/full",
        %*{"textDocument": {"uri": "untitled:u"}}))[0]["result"]["data"]
    var triples: seq[(int, int, int)]
    for i in countup(0, data.len - 1, 5):
      triples.add((data[i].getInt(), data[i + 1].getInt(), data[i + 2].getInt()))
    # key, `:`, value, comment: deltas from the previous start, UTF-16 lengths
    check triples == @[(0, 0, 1), (0, 1, 1), (0, 2, 2), (0, 3, 3)]

  test "unknown document":
    var s: Server
    let r = s.handle(request(1, "textDocument/semanticTokens/full",
        %*{"textDocument": {"uri": "untitled:none"}}))[0]["result"]
    check r["data"].len == 0

suite "LSP block scalars":
  proc blockScalars(text: string): JsonNode =
    var s: Server
    discard s.handle(didOpen("untitled:b", text))
    s.handle(request(1, "nimyaml/blockScalars",
        %*{"textDocument": {"uri": "untitled:b"}}))[0]["result"]

  test "literal with key and header comment":
    check blockScalars("setup: | # python\n  import os\n\n  print(1)\n\nnext: 1\n") ==
        %*[{"line": 0, "style": "literal", "start": 1, "end": 3, "indent": 2,
            "comment": "python", "key": "setup"}]

  test "nested, in sequences, with properties":
    check blockScalars("jobs:\n  b:\n    - run: |-\n        echo\n" &
        "    - \"q k\": !t &a |+ #sh  \n        x\n    - |\n      y\n") == %*[
      {"line": 2, "style": "literal", "start": 3, "end": 3, "indent": 8,
       "key": "run"},
      {"line": 4, "style": "literal", "start": 5, "end": 5, "indent": 8,
       "comment": "sh", "key": "q k"},
      {"line": 6, "style": "literal", "start": 7, "end": 7, "indent": 6}]

  test "indentation indicator, leading blank lines, folded":
    check blockScalars("- |2\n\n    x\n  y\n- >\n a\n b\n") == %*[
      {"line": 0, "style": "literal", "start": 1, "end": 3, "indent": 2},
      {"line": 4, "style": "folded", "start": 5, "end": 6, "indent": 1}]

  test "a value is a key only in its own mapping":
    check blockScalars("a:\n- |\n  x\n") == %*[
      {"line": 1, "style": "literal", "start": 2, "end": 2, "indent": 2}]

  test "empty block scalars, documents, lexer errors":
    check blockScalars("a: |\nb: \"x\n--- |\n x\n...\n--- |\n") == %*[
      {"line": 2, "style": "literal", "start": 3, "end": 3, "indent": 1}]

  test "CRLF and unknown documents":
    check blockScalars("k: |\r\n  x\r\n") == %*[
      {"line": 0, "style": "literal", "start": 1, "end": 1, "indent": 2,
       "key": "k"}]
    var s: Server
    check s.handle(request(1, "nimyaml/blockScalars",
        %*{"textDocument": {"uri": "untitled:none"}}))[0]["result"] == %*[]

suite "LSP grid":
  proc grid(text: string, json = false): JsonNode =
    var s: Server
    s.handle(request(1, "nimyaml/grid",
        %*{"text": text, "json": json}))[0]["result"]

  proc gridEdit(params: JsonNode): JsonNode =
    var s: Server
    s.handle(request(1, "nimyaml/gridEdit", params))[0]

  test "documents as typed trees, members in document order":
    check grid("b: [1, x, true, ~, 1.5]\na: {c: \"2\"}\n---\n- 1e3\n") == %*{
      "documents": [
        {"kind": "object", "members": [
          ["b", {"kind": "array", "items": [
            {"kind": "number", "text": "1"}, {"kind": "string", "text": "x"},
            {"kind": "boolean", "text": "true"},
            {"kind": "null", "text": "~"},
            {"kind": "number", "text": "1.5"}]}],
          ["a", {"kind": "object", "members": [
            ["c", {"kind": "string", "text": "2"}]]}]]},
        {"kind": "array", "items": [{"kind": "number", "text": "1e3"}]}]}

  test "aliases are followed, cycles are cut":
    let one = %*{"kind": "array", "items": [{"kind": "number", "text": "1"}]}
    check grid("a: &x [1]\nb: *x\n") == %*{"documents": [
      {"kind": "object", "members": [["a", one], ["b", one]]}]}
    check grid("&x [*x]\n") == %*{"documents": [
      {"kind": "array", "items": [{"kind": "cycle"}]}]}

  test "json with comments":
    check grid("// c\n{\"a\": null}\n", json = true) == %*{"documents": [
      {"kind": "object", "members": [
        ["a", {"kind": "null", "text": "null"}]]}]}

  test "errors have a position":
    let r = grid("a: 1\nb: [\n")
    check r["documents"] == %*[]
    check r["error"]["line"].getInt() >= 1
    check r["error"]["message"].getStr().len > 0

  test "assign in one document":
    check gridEdit(%*{"text": "a: 1  # c\n---\na: 1\n", "document": 1,
        "path": ["a"], "value": "2"})["result"] ==
        %*{"text": "a: 1  # c\n---\na: 2\n"}
    check gridEdit(%*{"text": "- {k: [x]}\n", "document": 0,
        "path": [0, "k", 0], "value": "\"1\""})["result"] ==
        %*{"text": "- {k: [\"1\"]}\n"}

  test "rename":
    check gridEdit(%*{"text": "a: 1\n", "document": 0, "path": ["a"],
        "name": "it's"})["result"] == %*{"text": "\"it's\": 1\n"}

  test "json":
    check gridEdit(%*{"text": "{\"a\": 1}", "json": true, "document": 0,
        "path": ["a"], "value": "\"x\""})["result"] ==
        %*{"text": "{\"a\": \"x\"}"}

  test "failures are errors":
    let r = gridEdit(%*{"text": "a: 1\nb: 2\n", "document": 0,
        "path": ["a"], "name": "b"})
    check r{"result"}.isNil
    check "already has a member" in r["error"]["message"].getStr()
    check gridEdit(%*{"text": "a: 1\n", "document": 0, "path": ["z"],
        "value": "2"})["error"]["message"].getStr() == "no such node: $['z']"

suite "LSP path at a position":
  proc pathAt(text: string, line, character: int, json = false): JsonNode =
    var s: Server
    s.handle(request(1, "nimyaml/pathAt", %*{"text": text, "json": json,
        "position": {"line": line, "character": character}}))[0]["result"]

  proc pointerAt(text: string, line, character: int, json = false): string =
    let r = pathAt(text, line, character, json)
    if r.kind == JNull: "null" else: r["pointer"].getStr()

  test "values, keys and items of block and flow collections":
    let doc = "a:\n  b: [1, {c/d: x}]\n  e f: y\nz: [t]\n"
    check pointerAt(doc, 0, 0) == "/a"
    check pointerAt(doc, 1, 2) == "/a/b"
    check pointerAt(doc, 1, 7) == "/a/b/0"
    check pointerAt(doc, 1, 12) == "/a/b/1/c~1d"
    check pointerAt(doc, 1, 15) == "/a/b/1/c~1d"
    # just after a node is still on it
    check pointerAt(doc, 1, 17) == "/a/b/1"
    check pointerAt(doc, 1, 18) == "/a/b"
    check pointerAt(doc, 2, 7) == "/a/e f"
    check pointerAt(doc, 3, 4) == "/z/0"

  test "pointer, path, segments and document":
    check pathAt("a:\n  - {c/d: x, e f: y, g_1: z}\n", 1, 18) == %*{
        "document": 0, "segments": ["a", 0, "e f"], "documents": 1,
        "pointer": "/a/0/e f", "path": "$.a[0]['e f']"}
    check pathAt("a: 1\n", 0, 3)["path"].getStr() == "$.a"
    check pathAt("~/: 1\n", 0, 3)["pointer"].getStr() == "/~0~1"

  test "the root and other documents":
    check pathAt("x\n", 0, 0)["pointer"].getStr() == ""
    check pathAt("x\n", 0, 0)["path"].getStr() == "$"
    let r = pathAt("a: 1\n---\nb: [2]\n", 2, 4)
    check r["document"].getInt() == 1
    check r["documents"].getInt() == 2
    check r["pointer"].getStr() == "/b/0"

  test "multi-line scalars":
    check pointerAt("a: |\n  x\n  y\nb: 1\n", 2, 2) == "/a"
    check pointerAt("a: >\n  x\n\nb: 1\n", 1, 1) == "/a"

  test "json, with comments":
    let doc = "{\n  // c\n  \"a\": [1, {\"b\": true}]\n}\n"
    check pointerAt(doc, 2, 15, json = true) == "/a/1/b"
    check pointerAt(doc, 2, 3, json = true) == "/a"

  test "a text with an error still has paths before it":
    check pointerAt("a:\n  b: 1\nc: [\n", 1, 5) == "/a/b"
    check pointerAt("a:\n  b: 1\nc: [\n", 2, 3) == "/c"
    # the parser reports no events of a flow collection that is not closed
    check pointerAt("a: [1, 2\n", 0, 7) == "/a"

  test "nothing outside the documents":
    check pathAt("", 0, 0).kind == JNull
    check pointerAt("# c\n", 0, 1) == "null"

  proc paths(text: string, json = false): JsonNode =
    var s: Server
    s.handle(request(1, "nimyaml/paths",
        %*{"text": text, "json": json}))[0]["result"]["nodes"]

  test "every node in document order, members from their keys":
    let r = paths("a:\n  b: [x, y]\nc: é\n---\n- 1\n")
    var pointers: seq[string]
    for node in r: pointers.add($node["document"] & node["pointer"].getStr())
    check pointers == @["0", "0/a", "0/a/b", "0/a/b/0", "0/a/b/1", "0/c",
        "1", "1/0"]
    check r[2] == %*{"document": 0, "pointer": "/a/b", "path": "$.a.b",
        "range": {"start": {"line": 1, "character": 2},
                  "end": {"line": 1, "character": 11}}}
    check r[3]["value"].getStr() == "x"
    check r[5]["range"]["start"] == %*{"line": 2, "character": 0}
    check r[5]["value"].getStr() == "é"

  test "long values are cut, whole characters":
    let r = paths("a: " & "é".repeat(50) & "\n")
    check r[1]["value"].getStr() == "é".repeat(40) & "…"

  test "json, and a text with an error":
    check paths("{\"a\": [true]}", json = true).len == 3
    check paths("a: 1\nb: [\n").len == 3

suite "LSP semantic diff":
  proc diffOf(old, new: string, json = false, patch = false): JsonNode =
    var s: Server
    s.handle(request(1, "nimyaml/diff", %*{"old": {"text": old},
        "new": {"text": new, "json": json}, "patch": patch}))[0]["result"]

  proc range(startLine, startCharacter, endLine, endCharacter: int): JsonNode =
    %*{"start": {"line": startLine, "character": startCharacter},
       "end": {"line": endLine, "character": endCharacter}}

  test "changes with their paths, values and ranges":
    let r = diffOf("a: 1\nb: [x, y]\n", "b: [x, z, y]\na: 2\n")
    check r["documents"] == %*[1, 1]
    check r["changes"].len == 2
    let changed = r["changes"][0]
    check changed["kind"].getStr() == "changed"
    check changed["oldPointer"].getStr() == "/a"
    check changed["newPath"].getStr() == "$.a"
    check changed["old"].getStr() == "1"
    check changed["new"].getStr() == "2"
    # a member from its key
    check changed["oldRange"] == range(0, 0, 0, 4)
    check changed["newRange"] == range(1, 0, 1, 4)
    let added = r["changes"][1]
    check added["kind"].getStr() == "added"
    check added["newPointer"].getStr() == "/b/1"
    check not added.hasKey("old")
    check added["newRange"] == range(0, 7, 0, 8)
    # where it is not: the collection around it (here a member)
    check added["oldRange"] == range(1, 0, 1, 9)

  test "the same, however written":
    check diffOf("{a: 1, b: [x]}", "{\"b\": [\"x\"], // c\n\"a\": 1.0}",
        json = true)["changes"].len == 0

  test "documents only one text has":
    let r = diffOf("a: 1\n", "a: 1\n--- x\n")
    check r["documents"] == %*[1, 2]
    check r["changes"].len == 1
    check r["changes"][0]["kind"].getStr() == "added"
    check r["changes"][0]["document"].getInt() == 1
    check r["changes"][0]["new"].getStr() == "x"

  test "the JSON Patch":
    check diffOf("a: 1\n", "a: 2\n", patch = true)["patch"].getStr() ==
        "- op: replace\n  path: /a\n  value: 2\n"
    check "\"op\": \"replace\"" in diffOf("a: 1\n", "{\"a\": 2}", json = true,
        patch = true)["patch"].getStr()
    check not diffOf("a: 1\n", "a: 1\n--- x\n", patch = true).hasKey("patch")

  test "a text that does not load":
    let r = diffOf("a: 1\n", "a: [\n")
    check r["changes"].len == 0
    check r["error"]["side"].getStr() == "new"
    check r["error"]["message"].getStr().len > 0
