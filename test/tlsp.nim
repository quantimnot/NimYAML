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
    let replies = s.handle(request(7, "textDocument/hover"))
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
