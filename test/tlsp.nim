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

  test "directive diagnostics":
    var s: Server
    let diags = s.handle(didOpen("untitled:d", "%SCHEMA s.json\n--- a\n"))
        .diagnosticsOf("untitled:d")
    check diags.len == 1
    check diags[0]["code"].getStr() == "unresolvable-schema-uri"
    check diags[0]["severity"].getInt() == 1
