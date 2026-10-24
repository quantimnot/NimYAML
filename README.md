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
   separated by `...` lines. Use `dumpJsonLines` for
   [JSON Lines](#json-lines).
 * **Anchors are local to each document.** A `ref` that occurs in two values
   gets an anchor and aliases within each document, but is written out in full
   in every document it appears in. When loading, each document gets its own
   copy, so identity across documents is lost.
 * **An empty list yields an empty string**, a stream with no documents.
   `loadMultiDoc` reads it back as an empty `seq`; `load` rejects it.

## JSONC

JSON loads with `load`, as YAML is a superset of it. JSONC (JSON with
comments, as in VS Code's `settings.json` or `tsconfig.json`) adds `//` and
`/* */` comments and trailing commas; `loadJsonc` and `loadAsJsonc` load it:

```nim
import yaml

type Config = object
  name: string
  ports: seq[int]

let c = loadAsJsonc[Config]("""{
  "name": "web", // the service
  "ports": [80, 443, /* https */],
}""")
```

`stripJsonComments` replaces the comments by spaces, keeping line breaks, and
the result is parsed as YAML. Positions in errors are those of the input. To
write JSONC, write JSON with `jsonDumper()`.

### Caveats

 * **Lenient.** As with `load`, any YAML is accepted, not only JSONC.
 * **Comments are dropped.** They are not part of the loaded value, so
   loading and dumping a JSONC file loses them.
 * **The input is read whole.** A `Stream` is read into a string before
   parsing.

## JSON Lines

[JSON Lines](https://jsonlines.org/) (`.jsonl`, also NDJSON) holds one JSON
value per line. `dumpJsonLines` writes each value on a line of its own, and
`loadJsonLines` reads them back:

```nim
import yaml

type Item = object
  name: string
  count: int

let s = jsonLinesDumper().dumpJsonLines(@[Item(name: "a", count: 1),
                                          Item(name: "b", count: 2)])
# {"name": "a", "count": 1}
# {"name": "b", "count": 2}

var items: seq[Item]
loadJsonLines(s, items)
```

The `jsonLines` iterator yields each value as soon as its line has been read,
so a large file does not need to fit in memory:

```nim
for item in jsonLines[Item](newFileStream("items.jsonl")):
  echo item.name
```

Both also accept a `string` or `Stream`, and `dumpJsonLines` writes to a
`Stream` as well.

### Caveats

 * **Lenient.** Each line is loaded like the input of `load`, so a line may
   hold any YAML that fits on one line, not only JSON.
 * **Blank lines are skipped**, though JSON Lines does not allow them. Lines
   end with LF or CRLF.
 * **Any dumper writes single lines.** `dumpJsonLines` overrides the
   dumper's newline style and line length so that each value takes one line;
   only a JSON dumper such as `jsonLinesDumper()` makes the lines JSON.
 * **Positions.** The line of an error is that of the input; its line
   content is that of the offending line.

## CBOR

[CBOR](https://www.rfc-editor.org/rfc/rfc8949) is a binary format with the
data model of JSON plus byte strings, tags and more number types. The module
`yaml/cbor` (also exported by `yaml`) reads and writes it as `YamlStream`, so
CBOR loads into and dumps from Nim values and the DOM like YAML does:

```nim
import yaml

type Item = object
  name: string
  count: int32

let data = Dumper().dumpCbor(Item(name: "a", count: 1))
# a2 64 6e616d65 61 61 65 636f756e74 01: {"name": "a", "count": 1}
assert loadAsCbor[Item](data) == Item(name: "a", count: 1)

echo cborToYaml(data)                           # name: a\ncount: 1
echo cborToYaml(data, jsonDumper().presentation) # as JSON
let again = yamlToCbor("name: a\ncount: 1")     # == data
```

Input holding several data items, a CBOR sequence (RFC 8742), is a stream
of several documents: `loadCborSequence` and `dumpCborSequence` load and
dump one value per data item. `parseCbor` and `presentCbor` are the
event-level reader and writer.

Integers, floats, booleans and null become scalars with the non-specific tag
`?` and content that the core schema resolves to their type, text strings
get the tag `!` and byte strings are `!!binary`. Tags 0 and 1 become
`!!timestamp`, tags 2 and 3 (bignums) integers, and tags 28 and 29 (shared
values) anchors and aliases, so `ref` objects keep their sharing. Other
tags are kept as `tag:nimyaml.org,2016:cbor:N`. The module documentation
lists the whole mapping.

`presentCbor` writes the preferred serialization: the shortest argument and
float encodings that keep their value, and definite lengths.

### Caveats

 * **Not streaming.** `parseCbor` reads its events lazily, but takes all of
   its input at once; `presentCbor` returns all of its output at once,
   since definite lengths are only known at the end of a collection.
 * **Untyped YAML scalars are resolved by the core schema.** Writing YAML as
   CBOR turns plain `1`, `1.5`, `true` and `null` into numbers, booleans
   and null, all other scalars into text strings. Timestamps are text
   strings unless tagged `!!timestamp`. Tags without a CBOR counterpart
   are dropped.
 * **Nested tags** other than the shareable tag 28 are rejected, since a
   YAML node has a single tag. Tags 21 to 24, 32 to 36 and 55799 are
   dropped when reading.
 * **Positions.** An error's `mark` has `line` 1 and the byte offset plus
   one as `column`.

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
   such as JSONPath, raise `YamlFragmentError` (use `yaml/jsonpath` for
   JSONPath queries). Splitting the URI and fetching
   the resource are up to you.

## JSONPath

`yaml/jsonpath` selects nodes from a `YamlNode` graph with [JSONPath][8]
queries (RFC 9535). It implements the whole RFC (all selectors, the
descendant segment, filters, the function well-typedness rules and the
standard functions `length`, `count`, `match`, `search` and `value`) and
passes the [JSONPath Compliance Test Suite][9]:

```nim
import yaml, yaml/[dom, jsonpath]

let root = loadAs[YamlNode]("""
store:
  book:
    - {title: Sayings of the Century, price: 8.95, tags: [quotes]}
    - {title: Moby Dick, price: 22.99, isbn: 0-553-21311-3}
""")
for node in root.query("$.store.book[?@.price < 10].title"):
  echo node.content                    # Sayings of the Century
for found in root.queryLocated("$..book[?@.isbn]"):
  echo found.path                      # $['store']['book'][1]
echo root.query("$..book[?match(@.title, 'M.*')]").len  # 1
```

`parseJsonPath` parses and type-checks a query once, so it can be applied to
many documents; malformed or ill-typed queries raise `YamlJsonPathError`
with the byte offset of the problem in `pos`. `query` returns the selected
nodes, `queryLocated` also their Normalized Paths (`$['store']['book'][1]`).
Both accept a `JsonPath` or a query string.

### Caveats

 * **Requires ORC.** Like `yaml/fragment`, the module builds on the DOM API
   and is not imported by `import yaml`.
 * **Scalars are typed by their tag.** A query sees the document as JSON:
   quoted scalars and `!!str` are strings, plain scalars are resolved with the
   core schema (`1.5` is a number, `true` a boolean, `~` null), and scalars
   with other tags are strings. So `$[?@.v == 1]` matches `v: 1` and
   `v: !!float 1`, but not `v: "1"`.
 * **Only string keys name members**, under the same rule as for JSON
   Pointers above. Members with keys like `0`, `!custom k` or `[a, b]` are
   not selected by any selector, not even `*` or `..`, because no Normalized
   Path could name them.
 * **Member order is unspecified.** `YamlNode` does not preserve mapping
   order, so `*`, `..` and filters visit members in no particular order; RFC
   9535 permits this. Sequence order is preserved.
 * **Aliases are followed; cycles are cut.** A node reachable along several
   paths is selected once per path. On a cyclic graph, `..` does not descend
   into a node that is already an ancestor of the current one, so `$..*`
   terminates. Merge keys (`<<`) are not applied.
 * **Results are the document's nodes.** They are not copies; modifying one
   modifies the document.
 * **I-Regexp, with anchors.** `match` and `search` use NimYAML's own
   [I-Regexp][10] engine (RFC 9485, including Unicode categories like
   `\p{Lu}`). It runs in linear time, so untrusted patterns cannot cause
   catastrophic backtracking. Following the compliance suite rather than the
   letter of RFC 9485, `^` and `$` outside brackets anchor at the start and
   end of the string; write `\^` or `[$]` for the literal characters. An
   invalid pattern makes the function return false, as RFC 9535 specifies.

## JSON Schema

`yaml/jsonschema` validates `YamlNode` graphs against [JSON Schema][11],
with schemas written in YAML or JSON. It supports drafts 2020-12 (the
default), 2019-09, 07, 06 and 04, and passes the [JSON Schema Test
Suite][12]: all validation tests of these drafts, including the optional
ones (formats, big numbers, ECMA-262 regular expressions, cross-draft
references), the output tests and the annotation tests.

```nim
import yaml, yaml/[dom, jsonschema]

let schema = compile(loadAs[YamlNode]("""
type: object
required: [name]
properties:
  name: {type: string, minLength: 1}
  age: {type: integer, minimum: 0}
"""))
let person = loadAs[YamlNode]("{name: Ada, age: -1}")
echo schema.isValid(person)                  # false
for error in schema.validate(person).errors:
  echo error.instanceLocation, ": ", error.error
  # /age: -1 is less than the minimum of 0
```

`compile` resolves all references up front, so a missing schema or a
malformed keyword raises `JsonSchemaError` there and not during validation.
References are resolved through a `SchemaRegistry`, which knows the
meta-schemas of all supported dialects (including JSON Hyper-Schema),
schemas added with `addSchema`, and whatever its optional `SchemaLoader`
returns:

```nim
let registry = newSchemaRegistry(proc(uri: string): YamlNode
    {.closure, raises: [CatchableError].} =
  if uri.startsWith("https://example.com/schemas/"):
    result = loadAs[YamlNode](readFile("schemas" / uri.extractFilename)))
registry.addSchema(loadAs[YamlNode](readFile("common.yaml")),
    "https://example.com/common")
let config = registry.compile(loadAs[YamlNode](readFile("config.schema.yaml")))
```

`isValid` stops at the first failing keyword. `validate` evaluates the
whole schema: `errors` and `annotations` give the flat lists of the *basic*
output format, `toYaml` renders the flag, basic, detailed or verbose output
format of JSON Schema 2020-12 as a `YamlNode`, and `outputTree` gives the
full tree. `checkSchema` validates a schema against its meta-schema.

### Caveats

 * **Requires ORC.** The module builds on the DOM API and is not imported by
   `import yaml`.
 * **Instances are read as JSON**, the same way `yaml/jsonpath` reads them:
   scalars are typed by their tag (plain scalars by the core schema, so
   `"1"` is a string and `1` an integer), only string keys are object
   members, and aliases are followed. A member whose key is `1` or `[a]` is
   invisible to every keyword, including `additionalProperties: false`.
   YAML's `.inf` and `.nan` are numbers but not integers.
 * **Numbers are exact.** They are compared as the decimals they are written
   as: `0.0075` is a multiple of `0.0001`, and integers have no size limit.
 * **Cyclic instances** (aliases referring to their ancestors) are accepted:
   a schema that reaches a node it is already validating assumes it is valid
   there. A schema that applies itself to the same instance without
   descending into it (`$ref: '#'`) raises `JsonSchemaError`.
 * **`format` is an annotation** unless `ValidationOptions.formatAssertion`
   is set or the dialect includes the format-assertion vocabulary. All
   formats of the specification are checked exactly by their RFCs;
   `idn-hostname` follows IDNA2008 with UTS 46 processing (mapping, NFC,
   Punycode, the contextual and Bidi rules), with Unicode 18.0 tables
   generated by `tools/genidnatables.nim`. `contentEncoding` (base64) and
   `contentMediaType` (`application/json`) are only checked with
   `contentAssertion`.
 * **Regular expressions are ECMA-262**, in Unicode mode, matched by a
   built-in backtracking engine (lookaround, backreferences, named groups,
   `\p{..}` for General Categories). Unicode properties other than General
   Categories, like `\p{Script=Greek}`, are not supported. Matching gives up
   with `JsonSchemaError` after a fixed number of steps, so a pathological
   pattern cannot hang validation.
 * **No network access.** Without a loader, only the bundled meta-schemas
   and added schemas can be referenced.

## JSON Hyper-Schema

`yaml/hyperschema` applies a [JSON Hyper-Schema][13] to an instance and
resolves its links: for every Link Description Object of a subschema that
validates part of the instance, `links` computes the context and target
URIs from the URI Templates of `href`, `anchor` and `base`, with variables
taken from the instance (through `templatePointers`, absolute or relative
JSON Pointers), and skips links whose `templateRequired` variables have no
value:

```nim
import yaml, yaml/[dom, jsonschema, hyperschema]

let schema = compile(loadAs[YamlNode]("""
$schema: https://json-schema.org/draft/2020-12/hyper-schema
base: https://example.com/api/
links:
  - {rel: self, href: "things/{id}", templateRequired: [id]}
  - rel: search
    href: "things{?q}"
    hrefSchema: {properties: {q: {type: string}}}
"""))
for link in schema.links(loadAs[YamlNode]("{id: 12345}"),
    "https://example.com/api/things/12345"):
  if link.acceptsInput:
    echo link.rel, " ", link.resolveTarget(loadAs[YamlNode]("{q: bolts}"))
  else:
    echo link.rel, " ", link.targetUri
# self https://example.com/api/things/12345
# search https://example.com/api/things?q=bolts
```

Links that accept client input (through `hrefSchema`) carry
`hrefInputTemplates` and `hrefPrepopulatedInput` instead of a target;
`resolveTarget` validates the input against `hrefSchema` and computes it.
`toYaml` renders links in the output format of the specification. The
examples of the specification serve as tests, as there is no official test
suite. See the module documentation for where the implementation has to
interpret the specification.

## URI Templates

`yaml/uritemplate` expands [URI Templates][14] (RFC 6570) at all four
levels and passes the [uritemplate-test][15] suite:

```nim
import yaml/uritemplate

let vars = {"id": tv"jo", "fields": tv(@["name", "age"])}.toTemplateVars
echo expand("/users/{id}{?fields*}", vars)   # /users/jo?fields=name&fields=age
```

`templateValue` converts `YamlNode` values, and `expandPartially` expands
only some variables, leaving the others as template expressions.

## `%SCHEMA` and `%GLOBAL` Directives

NimYAML gives meaning to two directive names that YAML 1.2 reserves:

```yaml
%GLOBAL TAG !e! tag:example.com,2000:
%GLOBAL SCHEMA schemas/service.json
--- !e!service {name: a}
...
%SCHEMA schemas/special.json      # overrides the global schema here
--- !e!service {name: b}
...
--- !e!service {name: c}          # !e! and the global schema apply again
```

* `%SCHEMA <uri-reference>` names the JSON Schema of the document that
  follows it. A relative reference resolves against the URI the stream was
  read from (`initYamlParser(sourceUri = ...)`); without one, it is an error.
  At most one per document.
* `%GLOBAL <directive>` wraps a `YAML`, `TAG` or `SCHEMA` directive (whose
  parameters are read exactly as on their own line) and makes it apply to
  every document of the stream. It is only allowed before the first
  document. A document's own `%YAML`, `%SCHEMA` or `%TAG` for the same handle
  overrides the global one for that document only.

Each `yamlStartDoc` event reports the effective `version` and `handles`, and
in `directives` the effective `schema`, every declaration in effect with its
origin (global or per-document) and position, and the problems found in the
directive block. Misuse never makes the YAML invalid, because every such line
is a valid reserved directive: the directive is ignored and an issue is
recorded instead, which `lint` reports under these ids:

| rule | default | reports |
|---|---|---|
| `unknown-directive` | warning | a reserved directive (YAML 1.2, §6.8, says to ignore it with a warning) |
| `invalid-schema-directive` | error | `%SCHEMA` without exactly one URI reference |
| `duplicate-schema-directive` | error | a second `%SCHEMA` in one document |
| `unresolvable-schema-uri` | error | a relative schema reference without source URI |
| `misplaced-global-directive` | error | `%GLOBAL` after the first document |
| `missing-global-directive` | error | `%GLOBAL` without a directive |
| `nested-global-directive` | error | `%GLOBAL GLOBAL` |
| `duplicate-global-directive` | error | a second global `YAML` or `SCHEMA`, or the same `TAG` handle twice |
| `unknown-global-directive` | warning | `%GLOBAL` with another directive (ignored) |
| `schema-source` | info | a document that names its schema in more than one way |

With `initYamlParser(directiveExtensions = false)`, `GLOBAL` and `SCHEMA` are
reserved directives like any other.

`yaml/documentschema` decides which schema a document is validated against,
highest first: its `%SCHEMA`, a `%GLOBAL SCHEMA`, a
`# yaml-language-server: $schema=<uri>` modeline in the document, a top-level
`$schema` key. Schemas are never merged. `yaml/schemavalidation` validates
every document against its schema (with `yaml/jsonschema`) and returns
diagnostics (`schema-validation`, `schema-unavailable`) positioned at the
offending nodes.

### Portable YAML

Other YAML processors ignore both directives, as the specification asks
them to. For `%GLOBAL TAG` that changes the meaning: they reject later
documents that use the handle. `yaml/portable` rewrites such input so that
any YAML 1.2 processor reads every document the same way, keeping comments
and layout:

```nim
import yaml/portable
echo expandDirectives(source)   # %GLOBAL lines become per-document directives
echo expandDirectives(source, ExpandOptions(schemas: soModeline))
  # ... and %SCHEMA becomes a yaml-language-server modeline
```

The same is available as `tools/yamlexpand.nim`
(`yamlexpand [--modeline] [FILE]`). When dumping events instead, the
presenter writes each document's directives with
`PresentationOptions(outputVersion: ovDocument, schemaDirective: sdDirective)`
(or `sdModeline`).

### Caveats

 * **Not standard YAML.** YAML 1.2 says there is no way to define private
   directives (§6.8). Use `yamlexpand` before handing such files to other
   tools.
 * **Comments before a directive block belong to the previous document.**
   A document's source starts at its first directive, so a modeline between
   `...` and the next document's directives counts for the document before.
 * **Schema references are not fetched.** The tools read `file:` schemas
   only; other schemas must be added to the `SchemaRegistry`.

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

plus the directive rules listed under
[`%SCHEMA` and `%GLOBAL` Directives](#schema-and-global-directives).

Rules are configured in the `lint` section of the `.yaml` (or `.yaml.yaml`)
config, found by walking up from the linted file's directory (see
[The `yaml` Command](#the-yaml-command)):

```yaml
lint:
  rules:
    line-length: {level: warning, max: 100}
    truthy: {level: off}
```

A `.nimyaml-lint.yaml` holding just the `rules` is still read in place of a
`.yaml` config.

Two tools use it, `yaml lint` and the language server `yaml lsp` (JSON-RPC
over stdio, full document sync), both commands of the `yaml` tool; the
standalone `tools/yamllint.nim`
(`yamllint [--config:FILE] [--no-schema] FILE...`) and `tools/yamllsp.nim`
still work the same way. Both also validate
documents against the JSON Schema they declare (`file:` schemas only). The
language server publishes the diagnostics of open documents and offers
completion of directive names, hover on directives (effective value, global
or per-document, overrides) and on `---`/`...` markers (the directives and
schema in effect), go-to-definition and document links on schema
references, and syntax highlighting (semantic tokens) as NimYAML's lexer
reads the text: keys, scalars by resolved type (numbers, booleans, null),
tags, anchors, aliases, `%GLOBAL`/`%SCHEMA` and other directives, and
comments.

Editor bindings for the language server live in `editors/`. Both start
`yaml lsp` with `yaml` from `PATH` by default, so put the built binary there
or point them at it:

* **VS Code**: `editors/vscode` is a small extension. Package and install it
  with
  ```bash
  cd editors/vscode && npm install
  npx @vscode/vsce package --allow-missing-repository --skip-license
  code --install-extension nimyaml-yamllsp-0.2.0.vsix
  ```
  Set `nimyaml.yamllsp.path` to use a binary that is not on `PATH` (and
  `nimyaml.yamllsp.args` to `[]` for the standalone `yamllsp`), and run
  *NimYAML: Restart yamllsp* after rebuilding it. It runs alongside other
  YAML extensions. It also provides embedded languages: code in a literal
  block scalar whose language is named (`query: | # sql`) gets that
  language's highlighting and the features of its extension; see
  [editors/vscode/README.md](editors/vscode/README.md).
* **Helix**: merge `editors/helix/languages.toml` into
  `~/.config/helix/languages.toml`, or copy it to `.helix/languages.toml` in a
  project. `hx --health yaml` shows whether `yaml` was found.

## The `yaml` Command

`tools/yamlcli.nim` is a single command line tool for everything above.
Build it as `yaml` with `nim yaml config.nims` or
`nim c -d:release -o:yaml tools/yamlcli.nim`, and see `yaml help COMMAND`:

```bash
yaml lint [--config:FILE] [--no-schema] [FILE...]      # all lint rules + schemas
yaml validate [--config:FILE] [--no-schema] [FILE...]  # YAML spec + schemas only
yaml format [--write | --check] [--drop-comments] [FILE...]
yaml convert [--from:FORMAT] yaml|json|jsonc|jsonl|cbor [FILE...]  # also: as, to
yaml query [--to:FORMAT] [--paths] '$.servers[*].port' [FILE...]
yaml '$.servers[*].port' [FILE...]                     # the same
yaml expand [--modeline] [FILE]                        # portable %GLOBAL
yaml lsp                                               # language server, stdio
yaml help [COMMAND]
```

Commands read standard input when no file is given. Exit codes: 0 on
success, 1 if an input is invalid, has error diagnostics or (with
`format --check`) is not formatted, 2 for usage, I/O and config errors.

`validate` reports only what makes a file invalid (syntax errors, duplicate
keys, undefined aliases, directive errors, schema violations); `lint` adds
the style rules. `convert` reads the format of each file from its extension
(`.json`, `.jsonc`, `.jsonl`/`.ndjson`, `.cbor`, YAML otherwise) and writes
the documents of all files as one stream; JSON output has one value per
document, with scalars typed by the YAML core schema. `query` applies a
JSONPath to each document and writes the selected nodes as documents.

One config file, `.yaml` or `.yaml.yaml` (not both in one directory), found
by walking up from each file's directory, configures `lint`, `validate`,
`format` and the language server. Every key is optional:

```yaml
lint:
  rules:
    line-length: {max: 100}
validate:
  schema: true          # validate against the declared JSON Schemas
format:
  style: default        # minimal, explanatory, json, json-lines, block-only
  indentation: 2
  max-line-length: 80   # 0 for no limit
```

### Caveats

 * `format` cannot keep comments, so it refuses files that have them unless
   given `--drop-comments`. It also drops the original scalar and
   collection styles; the `format` section decides them.
 * The language server only speaks stdio (`--stdio` is accepted and
   ignored).
 * There are no parser options in the config yet.

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
nim yamlcliTests config.nims # yaml command line tool; .yaml config
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
[8]: https://www.rfc-editor.org/rfc/rfc9535
[9]: https://github.com/jsonpath-standard/jsonpath-compliance-test-suite
[10]: https://www.rfc-editor.org/rfc/rfc9485
[11]: https://json-schema.org/
[12]: https://github.com/json-schema-org/JSON-Schema-Test-Suite
[13]: https://json-schema.org/draft/2019-09/json-schema-hypermedia
[14]: https://www.rfc-editor.org/rfc/rfc6570
[15]: https://github.com/uri-templates/uritemplate-test
