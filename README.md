# NimYAML - YAML implementation for Nim

![Test Status](https://github.com/flyx/NimYAML/actions/workflows/action.yml/badge.svg)

NimYAML is a pure Nim YAML implementation without any dependencies other than
Nim's standard library. It enables you to serialize Nim objects to a YAML stream
and back. It also provides a low-level event-based API.

Documentation, examples and an online demo are available [here][1]. Releases are
available as tags in this repository and can be fetched via nimble:

    nimble install yaml

## Status

This library is stable.
NimYAML passes all tests of the current [YAML 1.2 test suite][4].
This project follows [SemVer][5].

I am committed to maintaining the library, but will seldom introduce new features.
PRs are welcome.

## Dependencies

NimYAML requires Nim 2.0.0 or later.
The last version supporting Nim 1.6.x is `v1.1.0`.
Use this in your `.nimble` file if you haven't migrated to Nim 2.x yet:

```nim
requires "yaml ^= 1.1.0"
```

## Missing Features

Be aware that serialization currently doesn't support the following features in types that are used for loading and dumping:

 * Polymorphism: If a field has a type `ref Parent`, you cannot load a `ref Child` into it.
 * Generic objects: The code auto-generating loading and dumping functions currently cannot process instances of generic objects anywhere in the type you want to load/dump.

## Incremental Parsing

Besides parsing a complete `string` or a blocking `Stream`, the low-level API
offers `YamlFeedParser` for input that arrives in chunks, e.g. from a socket,
an async pipe or a message queue. You push input with `feed`, pull events with
`tryNext` or the `events` iterator, and call `finish` once all input has been
fed. When the input fed so far does not suffice for the next event, the parser
reports that instead of treating the end of the buffer as the end of input, and
resumes from the same point after the next `feed`.

```nim
import yaml/[parser, data]

let fp = newYamlFeedParser(initYamlParser())
for chunk in ["key: va", "lue\nlist: [1,", " 2]\n"]: # chunks as they arrive
  fp.feed(chunk)
  for event in fp.events:              # yields all events available so far
    echo event
fp.finish()                            # no more input
for event in fp.events:                # remaining events up to yamlEndStream
  echo event
assert fp.finished
```

`tryNext(fp, e)` returns `true` and sets `e` when an event could be produced,
and `false` when more input is required or the stream has already ended
(`fp.finished` tells the two apart).

### Caveats

 * **Events lag behind the input.** An event is only produced once the input
   proves it complete, which usually means the parser has seen the *next*
   token, and that token may be on the next line. A trailing newline is not
   enough: after feeding `"list: [1, 2]\n"` you get the events up to the
   `list` key, while the flow sequence is held back until the first character
   of the following line arrives, because `[1, 2]` could still turn out to be
   an implicit key. Likewise, a plain scalar may continue on the next line,
   and the events closing the last document are only produced after `finish`
   or an explicit `---`/`...` marker. For line-oriented protocols this means
   the events of a message's last line come out only with the next message or
   with `finish`. Ending each document with a `...` line releases all of its
   content events, up to the closing `yamlEndMap`/`yamlEndSeq`, right away;
   only `yamlEndDoc` itself then waits for the next byte. Even
   `yamlStartStream` requires at least one fed byte.
 * **Large scalars are cheap in any chunk size; large flow collections in
   small chunks are not.** The parser saves its state before each event and
   rolls back an attempt that runs out of input; it then parses that event
   again from its beginning once there is reason to expect success. For
   scalars (plain, quoted and block), a *completion gate* scans only the newly
   fed bytes for anything that could end the scalar or make it invalid (a
   closing quote, a less indented line, `: `, ` #`, a document marker, an
   invalid escape, …) and skips the attempt until it finds one. This makes
   feeding a large scalar linear: measured with `-d:release`, a 1 MB quoted
   scalar fed one byte at a time takes 35 ms, a 1 MB plain scalar full of
   URLs (`http://…`, colons that do not end it) 8 ms in 16-byte chunks, and a
   550 KB block scalar under 10 ms in 512-byte chunks. The gate is designed
   never to hold back an event or an error that could already be produced,
   and the tests check this for every yaml-test-suite input at several chunk
   sizes; it is disabled by `finish`.
   Flow collections (`[...]`, `{...}`), however, are parsed as a whole before
   their first event is produced, and every attempt re-parses the collection
   so far: an 80 KB flow sequence takes 0.01 s when fed in 4 KiB chunks, but
   0.5 s in 64-byte chunks (a 40 KB one: 0.13 s), growing quadratically.
   **For large flow collections (e.g. JSON), feed chunks of a few KiB or
   more**; if your transport delivers tiny pieces, buffer them before calling
   `feed`. Calling `tryNext` again without feeding anything is cheap: it
   returns `false` immediately. With reasonable chunks, feeding a document
   made of many small events is about 1.8× slower than parsing it as a
   complete string.
 * **Memory is bounded by the event in progress, not by the input.** Consumed
   input is discarded between events, but everything from the start of the
   event in progress (for a flow collection: the whole collection) plus all
   input fed but not yet parsed stays buffered. `feed` never blocks or applies
   back-pressure, so drain `events` after every `feed`.
 * **Errors are raised late, but precisely.** A `YamlParserError` is only
   raised once the fed input proves that it is invalid *and* the line
   containing the error is complete (or `finish` was called). Its position,
   message and line content then match those reported for the same input
   given as a string. An error may therefore surface only with a later
   `feed` or with `finish`. After an error, every further `tryNext` raises the
   same error again; create a new parser to continue.
 * **Event level only.** `YamlFeedParser` yields `Event`s; it is not a
   `YamlStream` and cannot be passed to `load`, `construct` or the DOM API
   directly. If you need those, collect the events of one document, from
   `yamlStartDoc` to `yamlEndDoc` (without `yamlStartStream` and
   `yamlEndStream`), into a `YamlStream`:

   ```nim
   import yaml/[native, stream]
   let buf = newBufferYamlStream()
   for e in fp.events:
     if e.kind notin {yamlStartStream, yamlEndStream}: buf.put(e)
   # ... once buf holds yamlEndDoc:
   var s: YamlStream = buf
   var person: Person
   construct(s, person)
   ```
 * **Usage rules.** `feed` after `finish` raises `ValueError`. A feed parser
   is not thread-safe, and it does no I/O itself: you drive it from your own
   event loop.

`Stream` input to `parse` has one behaviour change: errors raised by the
`Stream` while reading are now reported by the first `next` call that needs
the missing data, as a `YamlStreamError` whose message starts with
"Encountered stream error" and whose cause chain leads to the original
exception. Previously, the first read happened inside `parse` itself.

## Checkpoints

A parser can be checkpointed between two events and resumed later from that
point, e.g. after a crash while processing a huge file, or in another process.
`checkpoint` captures the state of a parser returned by `parse` (or `resume`)
or of a `YamlFeedParser`. The result is a plain `YamlCheckpoint` object that
you can store with NimYAML itself. To resume, supply the original input from
byte `cp.offset` on:

```nim
import std/streams
import yaml, yaml/[parser, stream]

var events = initYamlParser().parse(newFileStream("big.yaml"))
for i in 0 ..< 1000: discard events.next()
writeFile("big.checkpoint", Dumper().dump(events.checkpoint()))

# later, possibly in another process:
var cp: YamlCheckpoint
load(readFile("big.checkpoint"), cp)
let input = newFileStream("big.yaml")
input.setPosition(cp.offset)
events = initYamlParser().resume(cp, input) # continues with event #1001
```

`resume(parser, cp, s: string)` takes the input from `cp.offset` on as a string
(e.g. `input[cp.offset .. ^1]`), and `newYamlFeedParser(parser, cp)` resumes as
a feed parser, to which you feed the input from `cp.offset` on.

### Caveats

 * **You must supply exactly the same input.** Resuming continues with the
   bytes you supply from `cp.offset` on, without checking that they are the
   bytes the checkpoint was taken on. Changed or wrongly positioned input
   yields wrong events or errors, not a diagnostic.
 * **`offset` lies before the parser's position.** The parser keeps the start
   of the current line and of the most recent token, so `cp.offset` usually
   points somewhat before the end of the input consumed so far, and some input
   is read again on resume. Offsets are absolute byte offsets in the original
   input, also for checkpoints of a resumed parser. If you passed a `Stream`
   that was not at position 0, offsets are relative to where parsing started.
 * **Parser state only.** A checkpoint covers the parser, not what consumes its
   events. If you construct Nim values or a DOM from the events (`load`,
   `construct`, `loadAs`, …), that partial result and its state (e.g. anchors
   seen so far) are not part of the checkpoint; aliases after the checkpoint
   may refer to anchors defined before it. Checkpoint at document boundaries
   if you need to resume construction.
 * **Size: avoid checkpoints inside flow collections.** Between block-style
   events a checkpoint is small (about 1 KB dumped as YAML). But the parser
   reads a flow collection (`[...]`, `{...}`) as a whole before emitting its
   first event, and a checkpoint taken while those events are being emitted
   contains all that are still pending, in a verbose form: 10 events into a
   49 KB top-level flow sequence of 5000 items, the dumped checkpoint is
   1.2 MB, about 24 times the input. For JSON-like input made of one huge
   array or object, checkpoints are therefore of little use.
 * **Same version only; corrupted checkpoints are rejected, crafted ones are
   not.** `YamlCheckpoint`'s fields are internal; don't modify them. A
   checkpoint can only be resumed by a NimYAML version with the same
   `checkpointVersion`. Each checkpoint carries a checksum over all its
   fields, so a checkpoint that was damaged in storage (or edited without
   updating the checksum) is rejected with `ValueError`, as are a few
   structurally impossible states. The checksum is not cryptographic: a
   checkpoint crafted with a matching checksum can make `resume` produce wrong
   events or even raise a `Defect` (e.g. `IndexDefect`), which aborts the
   program with `--panics:on`. Do not resume checkpoints from untrusted
   sources.
 * **Short input is only partly detected.** `resume` with a `string` raises
   `ValueError` if the string is shorter than the input the checkpoint has
   already read. Otherwise, missing or wrong input yields wrong events or
   errors (see the first caveat).
 * **When checkpointing fails.** `checkpoint` raises `ValueError` for a
   `YamlStream` that does not come from `parse` or `resume`, and for a parser
   or feed parser that has raised an error (including a failure of its input
   `Stream`): its state is inconsistent from that point on.
 * **Feed parser specifics.** A feed parser's checkpoint does not include
   input that was fed but not yet parsed, nor whether `finish` was called:
   after resuming, feed from `cp.offset` on and call `finish` again. A
   checkpoint taken after `yamlEndStream` resumes as a finished parser. A
   checkpoint of a feed parser that has not produced any event yet can only be
   resumed with `newYamlFeedParser`. A peeked event (see `peek`) is part of
   the checkpoint, also when resuming a `YamlStream` checkpoint as feed
   parser.
 * **Settings come from the resuming parser.** `resume` uses the settings of
   the `YamlParser` you call it on (e.g. `issueWarnings`), not those of the
   parser the checkpoint was taken from.

## Document Starts

In a stream of several documents (logs, Kubernetes manifests, …), each
document can be parsed on its own, without the documents before it. After a
`yamlStartDoc` event, `documentStart` tells where the source of that document
begins: the byte `offset` and `line` of the line holding its first directive,
its `---` marker or, for a document without either, its first content. Record
these to index a stream, and later parse from any of them:

```nim
import yaml/[parser, stream, data]

var starts: seq[YamlDocumentStart]
let events = initYamlParser().parse(input)
for e in events:
  if e.kind == yamlStartDoc: starts.add(events.documentStart())

# later: parse the third document and all after it
let start = starts[2]
for e in initYamlParser().parse(input[start.offset .. ^1], start):
  echo e
```

The new stream starts with `yamlStartStream`; its events, positions and
further document starts are the same as those of the original stream. There is
also a `Stream` variant (seek to `start.offset` first) and
`newYamlFeedParser(parser, start)`. `%YAML` and `%TAG` directives belong to the
document they precede, so they are part of what you parse from its start.
This is much cheaper than a checkpoint, but only possible at document starts.
As with checkpoints, the input you supply must be the original input from
`start.offset` on; this is not checked.

## Error Recovery

`parseRecovering` parses like `parse`, but when a document turns out to be
invalid, it records the error, drops the document and continues with the next
one:

```nim
let events = initYamlParser().parseRecovering(input)
for e in events:
  echo e # only events of valid documents
for err in events.errors:
  echo "line ", err.error.mark.line, ": ", err.error.msg,
    " (continued at line ", err.resumedAt.line, ")"
```

### Caveats

 * **Where parsing continues.** After an error, parsing continues at the next
   line that starts with a `---` marker, or after the next line that starts
   with a `...` marker (a marker is followed by whitespace or the end of the
   line). Everything in between is skipped, including any content that would
   have been valid. Parsing never continues within the document that failed,
   and an invalid document without a later marker ends the stream.
 * **Whole documents are buffered.** To be able to drop an invalid document
   without having emitted part of it, the stream holds back the events of
   each document until it is complete. Memory use is therefore proportional
   to the largest document, unlike `parse`, where it is proportional to the
   largest event. Use `parse` for huge single documents.
 * **Only YAML errors are recovered from.** A failure of the input `Stream`
   is raised as with `parse`.
 * **Not combinable with everything.** There is no feed parser variant, and
   `checkpoint` does not accept a recovering stream. `documentStart` works.
   The stream is a regular `YamlStream`: the high-level `load` procs do not
   recover from errors, but you can process the recovering stream's events
   like those of `parse`.

## Dumping Multiple Documents

`dumpMultiDoc` is the counterpart of `loadMultiDoc`: it dumps each value as a
document of its own, all in one YAML stream.

```nim
import yaml

type Item = object
  name: string
  count: int

let s = Dumper().dumpMultiDoc(@[Item(name: "a", count: 1),
                                Item(name: "b", count: 2)])
# name: a
# count: 1
# ...
# name: b
# count: 2
var items: seq[Item]
loadMultiDoc(s, items) # @[Item(name: "a", count: 1), Item(name: "b", count: 2)]
```

There is also a variant that writes to a `Stream`. Any `seq` or array of a
type that `dump` accepts works, including `YamlNode`s.

### Caveats

 * **Documents are separated by `...`.** The presenter ends each document but
   the last with a `...` line; `---` only appears where the dumper writes
   directives anyway (e.g. `canonicalDumper`). This is valid YAML, but if you
   need `---` separators, e.g. for tools that split on them, post-process the
   output.
 * **Not JSON.** With `jsonDumper()`, each document is JSON, but the result as
   a whole is not, nor is it JSON Lines: the documents are pretty-printed and
   separated by `...` lines.
 * **Anchors are local to each document.** A `ref` that occurs in two values
   gets an anchor and aliases within each document, but is written out in full
   in every document it appears in. When loading, each document gets its own
   copy, so identity across documents is lost.
 * **An empty list yields an empty string**, a stream with no documents.
   `loadMultiDoc` reads it back as an empty `seq`; `load` rejects it.

## Fragment Identifiers

`yaml/fragment` resolves URI fragment identifiers such as `doc.yaml#/a/b` or
`doc.yaml#*anchor` against YAML input, as defined for the `application/yaml`
media type by [RFC 9512][6]. Split the fragment off the URI and pass it with
the content:

```nim
import yaml, yaml/fragment

const doc = """
servers:
  - &prod {host: example.com, port: 443}
  - {host: localhost, port: 8080}
"""
echo resolveFragment(doc, "/servers/1/host").content # localhost
echo resolveFragment(doc, "#/servers/0/port").content # 443 (leading # is ignored)
echo resolveFragment(doc, "*prod")["host"].content # example.com
echo resolveFragment(doc, "").kind # yMapping: the root node
```

| Fragment | References | Defined for |
|---|---|---|
| empty | the root node | single-document streams |
| `/a/0` | the node at that [JSON Pointer][7], traversing aliases | single-document streams |
| `*name` | the first node with anchor `name`, in any document | all streams |

`resolveFragment` percent-decodes the fragment first. If you already hold a
`YamlNode`, `resolvePointer(root, "/a/0")` evaluates a JSON Pointer on it
without parsing again, and `resolveAnchor(input, "name")` finds an anchor
directly; neither of them percent-decodes. All three raise `YamlFragmentError`
if the fragment is malformed or references no node; RFC 9512 leaves that case
to the application. Parser errors are raised as usual.

### Caveats

 * **Requires ORC.** The module builds on the DOM API, which is not available
   with `--mm:arc`. It is not imported by `import yaml`.
 * **The input is parsed for every call.** `resolveFragment` and
   `resolveAnchor` construct a `YamlNode` graph of the document (for anchors:
   of each document up to the one with the anchor). To resolve many pointers
   against the same content, load it once with `loadAs[YamlNode]` and use
   `resolvePointer`.
 * **JSON Pointers need a single document.** RFC 9512 defines the empty
   fragment and JSON Pointers only for single-document streams, so they raise
   `YamlFragmentError` for a stream with several documents (or none). To
   reference a node in a multi-document stream, give it an anchor and use
   `*name`. If you want to apply a pointer to a particular document anyway,
   load the documents with `loadMultiDoc` and call `resolvePointer` on one.
 * **JSON Pointers only match string keys.** A pointer can only traverse what
   the JSON data model can express. A mapping key matches a pointer token if it
   is a quoted scalar, has the tag `!!str`, or is a plain scalar that the core
   schema does not resolve to null, a boolean, an integer or a float. So
   `#/0` does not reach `0: x`, but does reach `"0": x`; timestamps such as
   `2001-12-14` count as strings, because the core schema does not include
   them. Nodes under complex keys (e.g. `? [a, b]`) cannot be reached with a
   pointer at all; use an anchor.
 * **Merge keys are not applied.** NimYAML does not resolve the YAML 1.1 merge
   key `<<`, so `#/book/<<` references the merged mapping, and keys merged
   into `book` are not visible at `#/book/…`. RFC 9512 notes that this differs
   between implementations.
 * **Cycles are fine, `-` is not.** A pointer follows aliases, also cyclic
   ones; since every token takes one step, resolution always terminates. The
   JSON Pointer token `-` (past the end of an array) references no node, and
   indexes with leading zeros are rejected.
 * **The first anchor wins.** If an anchor name is defined several times,
   `*name` references the first definition in the stream, as RFC 9512
   specifies, even though aliases after a redefinition refer to the later
   node. RFC 9512 recommends unique anchor names and names that need no
   percent-encoding.
 * **The result is part of its document's graph.** The returned node shares
   its children with the rest of the document, including nodes reached through
   aliases; modifying it modifies those as well.
 * **Only RFC 9512's fragment syntax.** Media types with the `+yaml` suffix
   (e.g. `application/openapi+yaml`) define their own fragment syntax;
   whether it matches is up to that type's specification. Other fragment forms,
   such as JSONPath, raise `YamlFragmentError`. Splitting the URI and fetching
   the resource are up to you.

## Linting

`yaml/lint` lints YAML sources: `lint(source, config)` returns diagnostics
(rule id, severity, range, message) sorted by position. It parses once with
`parseRecovering` and runs these rules:

| rule | default | reports |
|---|---|---|
| `syntax` | error | invalid documents |
| `duplicate-key` | error | a scalar key repeated in one mapping |
| `complex-key` | warning | a sequence or mapping used as a key |
| `undefined-alias` | error | an alias without an earlier anchor in its document |
| `unused-anchor` | warning | an anchor no alias refers to |
| `truthy` | warning | plain `yes`/`no`/`on`/`off`/`y`/`n` (booleans in YAML 1.1) |
| `trailing-spaces` | warning | whitespace at the end of a line |
| `line-length` | warning | lines longer than `max` (120) characters |
| `tabs` | error | tabs in indentation |
| `final-newline` | warning | no line break at the end of the file |

Rules are configured in `.nimyaml-lint.yaml`, found by walking up from the
linted file's directory:

```yaml
rules:
  line-length: {level: warning, max: 100}
  truthy: {level: off}
```

Two tools use it: `tools/yamllint.nim` (`yamllint [--config:FILE] FILE...`,
exit code 1 if there are errors, 2 for usage, I/O or config errors) and
`tools/yamllsp.nim`, a language server (JSON-RPC over stdio, full document
sync) that publishes the diagnostics of open documents. Build them with
`nim yamllint config.nims` and `nim yamllsp config.nims`, or
`nim c -d:release tools/yamllint`.

## Developers

Nix users can `nix develop` to get a devshell with the required Nim version. You'll need to have Flakes enabled.

```bash
nim test config.nims # runs all tests
nim lexerTests config.nims # run lexer tests
nim parserTests config.nims # run parser tests (git-clones yaml-dev-kit)
nim feedTests config.nims # compare feed parser against the string parser on yaml-test-suite
nim checkpointTests config.nims # resume from checkpoints after every event of yaml-test-suite
nim documentTests config.nims # parse from document starts; error recovery
nim lintTests config.nims # diagnostics, lint rules and lint config
nim yamllintTests config.nims # yamllint command line tool
nim lspTests config.nims # yamllsp language server
nim fragmentTests config.nims # fragment identifiers; multi-document dumping
nim nativeTests config.nims # runs native value tests
nim quickstartTests config.nims # run tests for quickstart snippets from documentation
nim clean config.nims # guess
nim build config.nims # build a library
```

When debugging crashes in this library, use the `d:debug` compile flag to enable printing of the internal stack traces for calls to `internalError` and `yAssert`.

### Web Documentation

The online documentation on [nimyaml.org][1], including the
testing ground, is generated via [Nix Flake][3].

You can build & run the docs server at via

```bash
nix run .#webdocs
```

It can be deployed to NixOS by importing the Flake's NixOS module and then doing

```nix
services.nimyaml-webdocs.enable = true;
```

This will run the documentation server locally at `127.0.0.1:5000`.
Since there isn't much of a use-case for third parties to host this documentation, there is no support for running the server without Nix.

## License

[MIT][2]

## Support this Project

If you want to support this project financially, there's a GitHub Sponsor button to the right.

 [1]: https://nimyaml.org
 [2]: copying.txt
 [3]: https://nixos.wiki/wiki/Flakes
 [4]: https://github.com/yaml/yaml-test-suite
 [5]: https://semver.org
 [6]: https://www.rfc-editor.org/rfc/rfc9512.html#section-1.2
 [7]: https://www.rfc-editor.org/rfc/rfc6901
