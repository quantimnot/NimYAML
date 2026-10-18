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
 * Default values: NimYAML uses its own `{.defaultVal: "foo".}` pragma.
   It currently cannot process default values introduced in Nim 2.0.

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
 * **Starved attempts are redone from the start of the event: small chunks
   into large events are quadratic.** The parser saves its state before each
   event and rolls back an attempt that runs out of input; after the next
   `feed`, it parses that event again from its beginning. Flow collections
   (`[...]`, `{...}`) are parsed as a whole before their first event is
   produced, so a large flow collection counts as one large event. Measured
   with `-d:release`: an 80 KB flow sequence takes 0.01 s when fed in 4 KiB
   chunks, but 0.49 s in 64-byte chunks (a 40 KB one: 0.12 s); a 550 KB block
   scalar takes 0.01 s in 64 KiB chunks, 0.1 s in 4 KiB chunks and 0.8 s in
   512-byte chunks. **Feed chunks of a few KiB or more**; if your transport
   delivers tiny pieces (e.g. small socket reads), buffer them before calling
   `feed`. Calling `tryNext` again without feeding anything is cheap: it
   returns `false` immediately. With reasonable chunks, feeding a document
   made of many small events is about 1.75× slower than parsing it as a
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

## Developers

Nix users can `nix develop` to get a devshell with the required Nim version. You'll need to have Flakes enabled.

```bash
nim test # runs all tests
nim lexerTests # run lexer tests
nim parserTests # run parser tests (git-clones yaml-dev-kit)
nim feedTests # compare feed parser against the string parser on yaml-test-suite
nim checkpointTests # resume from checkpoints after every event of yaml-test-suite
nim nativeTests # runs native value tests
nim quickstartTests # run tests for quickstart snippets from documentation
nim clean # guess
nim build # build a library
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
