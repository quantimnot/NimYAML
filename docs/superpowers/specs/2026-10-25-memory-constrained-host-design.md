# Memory-constrained hosts — design

Date: 2026-10-25
Status: draft, awaiting approval (todo.yml `memory-constrained-host`);
builder-check questions answered 2026-10-25

## Intent

A huge YAML file has to be workable on a memory-constrained embedded device.
The range of hosts runs from microcontrollers up to massive servers, and the
behaviour is *progressive*: each host gets the best strategy it can support,
with mmap used where the host has it.

The user's rule: **all features MUST be accessible on constrained devices,
when possible.** Where a feature genuinely cannot run inside the limit, it
fails with a clear, early error rather than being OOM-killed.

## Goals

- G1. A configurable memory limit (`.yaml` config, CLI flag, compile-time
  default) that the library and the `yaml` CLI respect.
- G2. A source abstraction with progressive tiers (in-memory, mapped,
  seekable, sequential) chosen automatically per input and per host.
- G3. mmap via `std/memfiles` where the OS provides it (POSIX, Windows),
  with windowed mapping so 32-bit address spaces still work.
- G4. Every CLI command and library entry point that today reads a whole
  file (`readFile`/`readAll`) goes through the source abstraction instead.
- G5. Commands whose work is per-document or per-subtree hold at most one
  document/subtree, not the whole stream. Commands that can stream
  (convert, merge, format, lint, index build, indexed query, assignment)
  run in bounded memory regardless of file size.
- G6. The parser and event stream usable on a microcontroller
  (`--os:any`/standalone, no filesystem): caller-supplied read callback and
  a fixed buffer budget. *(User decision: microcontroller scope is the
  parser and event stream only — `memory.nim`, `source.nim`, lexer,
  parser, `YamlStream`. DOM, native construction, presenter, JSONPath and
  schema validation are not required to build there.)*
- G7. Exceeding the limit raises a dedicated error naming the operation,
  the estimated need, the limit, and the alternative (raise the limit, use
  the index, narrow the query).

## Non-goals

- The LSP server. Editors run on hosts with memory; `yaml lsp` keeps whole
  documents as now.
- Exact allocator-level accounting of every byte. The budget is enforced at
  the places that grow with input size (see "Accounting").
- A streaming JSON Schema validator in this project. Validation stays
  per-document DOM; a document larger than the limit fails with the limit
  error. (Tracked as a follow-up todo, see "Phasing".)
- Changing output formats or the on-disk index format.

## Anti-goals

- Slowing the common case. A small file on a big host must keep today's
  in-memory path and speed.
- Silent failure. Any error (limit, parse, presenter) gives a non-zero
  exit status and a diagnostic. Outputs written to files go to a temp file
  renamed only on success, so files are all-or-nothing. *(User decision:
  output to stdout/pipes is streamed and may be partial when a later
  document fails; the non-zero exit status is the signal. This changes
  today's convert/merge behaviour, which prints nothing on error.)*
- New external dependencies.

## Facts the design relies on (devel a519ec2)

- The lexer already streams: `SourceBuffer` (lex.nim:45-65) fetches 8 KiB
  chunks from a `Stream` and `compactBuffer` (lex.nim:1062-1086) drops
  consumed bytes between events. String input sets `compactAt: int.high` and
  is never compacted. A single huge scalar or line is fully buffered.
- Feed parser (`YamlFeedParser`, parser.nim:307) and checkpoints
  (`YamlCheckpoint`, parser.nim:492; `resume` :882/:898) exist; checkpoints
  carry an absolute byte offset.
- The CLI reads every input whole: yamlcli.nim:335-336, :741, :863, :965,
  :1177; yamllint.nim:103/:107; yamlexpand.nim:51; cbor.nim:451;
  presenter.nim:1428 (format with comments); toolconfig/lint read config
  files whole (small, untouched by this design).
- Random-access consumers: `edit.nim` splices strings by byte offset
  (:374); `spans.nim` indexes `source[offset]` and builds `lineStarts`
  (:123, :228, :369); `nodeindex.nim` reads slices with
  `setFilePos`+`readChars` (:416) and hashes the whole file with FNV-1a
  after an mtime mismatch (:524); presenter `attachComments` uses
  `source.splitLines` (:1357).
- DOM consumers: jsonschema (`validate(YamlNode)`), jsonpath
  (`queryLocated(YamlNode)`), diff, patch, canonical/jcs, query without an
  index. All construct one DOM per document already.
- `convert` collects all inputs into one `BufferYamlStream` before writing
  (yamlcli.nim:597-605); `merge` does the same.
- No platform conditionals exist except `when defined(windows)` in
  schemacache.nim:67; `std/memfiles` is not used.
- `.yaml` config: `ToolConfig` has sections `lint`, `validate`, `format`,
  `index`, each a sparse object of `Option` fields with accessor procs,
  `resolved()`, `$`, and range checks in `parseToolConfig`. No user/project
  layering; the nearest config file wins.

## Design

### D1. `MemoryBudget`

A small value type in a new module `yaml/memory.nim`:

```nim
type
  MemoryBudget* = object
    limit*: int        ## bytes; int.high = unlimited
    used: int          ## bytes reserved by budgeted allocations
  YamlMemoryLimitError* = object of YamlError
    operation*: string ## e.g. "query: building document 3"
    needed*, limit*: int
```

- `reserve(b, n, operation)` / `release(b, n)`; `reserve` raises
  `YamlMemoryLimitError` when `used + n > limit`.
- Passed by `var` (or held by `ref` in long-lived objects such as the
  lexer). Default parameter `unlimitedBudget()` keeps every existing API
  source-compatible.
- Limit resolution order: CLI `--memory-limit`, then `.yaml` `memory.limit`,
  then compile-time `-d:yamlMemoryLimit=<bytes>`, then `auto`.
- `auto`: a fraction (builder's call, start at 50%) of the detected
  available memory — cgroup v2 `memory.max`/v1 `memory.limit_in_bytes`,
  then `/proc/meminfo` MemAvailable on Linux; `sysctl hw.memsize` on macOS;
  `GlobalMemoryStatusEx` on Windows; unlimited when nothing is detectable
  and no compile-time default exists.
- Sizes are written with units: `64KiB`, `16MiB`, `1GiB`, plain bytes, or
  `auto`/`unlimited`.

### D2. Accounting — where the budget is charged

Enforced at the allocations that grow with input, not globally:

| Consumer | Charged |
|---|---|
| Lexer `SourceBuffer.data` | buffer growth (window + longest token/line) |
| Scalar content | scalar length while being assembled |
| Event buffers (`BufferYamlStream`, presenter `buffered`, spans `parsedEvents`) | per event, estimate = fixed overhead + content length |
| DOM construction | per node, estimate = fixed node overhead + scalar/key length |
| Index lookup LRU, spans `lineStarts` | per entry |
| In-memory and spooled sources | whole source size |

Typed construction (`load`/`loadAs[T]` into user types): the generic
`constructChild` paths in native.nim charge `sizeof(T)` per constructed
object/ref plus string and seq growth; user-written `constructObject`
hooks are charged only for the scalars and events they consume.
*(Builder-check call: this under-counts exotic custom hooks, which is
accepted and documented.)*

A DOM is therefore refused early (while constructing) instead of after the
OS has run out. The fixed overheads are constants measured once under ORC
on 64-bit and recorded in `memory.nim`; tests check they are not
under-estimates (see Testing).

### D3. `YamlSource` — progressive tiers

A new module `yaml/source.nim`:

```nim
type
  SourceTier* = enum
    stInMemory   ## whole content in a string (today's behaviour)
    stMapped     ## memfiles mapping, possibly windowed
    stSeekable   ## file handle, pread into a bounded page cache
    stSequential ## pipe/stdin/callback; forward-only
  YamlSource* = ref object
    tier*: SourceTier
    size*: int64          ## -1 when unknown (sequential)
    name*: string
    ...
```

Operations:

- `read(src, offset, dest: var openArray[char]): int` — random access for
  the first three tiers.
- `slice(src, first, last): string` and, for mapped/in-memory,
  `view(src, first, last): openArray[char]` (zero-copy, `lent`/`toOpenArray`).
- `stream(src, offset = 0): Stream` — a forward Stream for the lexer.
  For `stMapped` and `stInMemory` the lexer reads straight from the view
  (no copy; compaction is a no-op because nothing was copied).
- `lines(src, first)` iterator for line-based consumers (lint, comments).
- `openSource(path | stdin | callback, budget, policy)` chooses the tier.

Tier selection for a file of size `S` with limit `L`, policy `auto`:

1. `S <= L div 4` (builder may tune the ratio) → `stInMemory`. This keeps
   the fast path for small files on big hosts.
2. else, mmap available and allowed → `stMapped`. The mapping is always a
   sliding window (default 64 MiB, capped by `L div 2`), remapped on access
   outside it, on 32-bit and 64-bit alike. *(Builder-check call: mapping
   the whole file on 64-bit would leave every touched page resident in
   RSS with no memory pressure, breaking the peak-RSS bound.)* Windows
   already passed by the lexer are unmapped as compaction advances, so
   resident file pages stay within the window.
3. else, the file is seekable → `stSeekable` with a page cache of
   `min(L div 8, 1 MiB)` in 4 KiB pages, LRU.
4. else (pipe, stdin, callback) → `stSequential`.

Mapped pages are charged to the budget for the active window (and any
window pinned by a `view` still in use). mmap is preferred because it
avoids copies and lets the OS page from the file, not because its pages
are free.

`policy` comes from `memory.source: auto|memory|mmap|seek|stream` and lets
users (and tests) force a tier. `memory.mmap: auto|on|off` is a shorthand
that disables tier 2. *(Builder-check call:)* forcing a tier never
overrides the limit — forced `memory` on a file larger than the limit
raises the limit error; forced `stream` still spools when a command needs
random access, governed by `memory.spool` exactly as for a pipe.

**Random access over a sequential input (spool).** When a command needs
random access and the input is `stSequential`, the source spools to a temp
file and then upgrades to mapped/seekable — when `memory.spool` is `auto`
(the default) and a writable temp dir exists. With `spool: off`, or no
filesystem, the command raises the limit error naming the reason
("needs random access; input is a pipe").

**Microcontrollers.** `openSource(read: proc (offset: int64, dest: var
openArray[char]): int, size = -1, budget)` lets firmware back a source with
flash, SD card, or a network transport. If the callback supports offsets
the source is random-access; otherwise sequential. `memory.nim` and
`source.nim`, the lexer and the parser compile with `--os:any`;
`memfiles`/`os` imports are behind `when defined(posix) or
defined(windows)`. If `std/streams` doesn't build under `--os:any`, the
lexer reads from `YamlSource` directly and the `Stream` overloads become
desktop-only wrappers (builder's call which way, decided by trying it).

### D4. The lexer on a source

- `init(lex, source: YamlSource, budget)` replaces the string/Stream split
  internally (the existing overloads wrap a source).
- Mapped/in-memory sources: the lexer indexes the view directly; no
  `SourceBuffer.data` copy at all.
- Seekable/sequential: today's chunked buffer and compaction, with buffer
  growth charged to the budget. A token or line longer than the remaining
  budget raises the limit error naming the line.
- Long scalars: for event consumers that only pass scalars through
  (convert, format without comments), add an opt-in chunked scalar event
  (`yamlScalarChunk`? builder's call on the shape) so a 1 GB block scalar
  does not have to fit. Consumers that need the whole scalar (DOM, schema)
  still charge it in full. This is the one part of the design that touches
  the public event type; if it proves too invasive, it moves to phase 3
  and huge single scalars fail with the limit error instead.

### D5. Per-command behaviour

| Command | Today | Under this design |
|---|---|---|
| convert/as/to | collects all inputs | streams document by document to output; CBOR input via a streaming decoder on the source |
| merge | collects | streams per document |
| format (no comments) | stream | source-backed stream, bounded |
| format (comments) | readAll + all events + splitLines | per-document event buffer (charged); comment lines read via `src.lines`/`read` instead of `splitLines` |
| format --write/--check | whole string compare | write to temp + compare streams chunk-wise; rename on success |
| lint | whole string | source-backed `parseRecovering`; line checks through `src.lines` |
| validate | per-doc buffered events, DOM if schema | same, charged; doc over the limit → limit error naming the document |
| query (indexed) | slices via setFilePos; full-file hash on mtime change | slices via `src.read`; fingerprint hash streams in chunks |
| query (no index) | DOM per document | **streaming evaluator** for JSONPath segments that don't need siblings (name, index, wildcard, descendant, slices with non-negative bounds); filter selectors build a DOM only for each candidate child; negative indices/slices buffer up to the needed count. Queries the evaluator can't handle fall back to per-document DOM (charged). |
| assignment (`=`) | splice the whole string | spans via source; output written by copying unchanged byte ranges from the source to a temp file, then rename |
| index build | whole string + all events | spans over the source; entries written incrementally; `lineStarts` replaced by line tracking from event marks |
| patch, diff, canonical/jcs | DOM per document | unchanged algorithmically, DOM charged; over the limit → limit error. Patch file read through a source too. |
| expand | whole string | source-backed stream |
| lsp | whole text | unchanged (non-goal) |

Library entry points (`load`, `loadAs`, `loadMultiDoc`, `dump`, presenter,
`sourceSpans`, `buildIndex`, `assign`, `rename`) gain `YamlSource` and
`budget` overloads; existing string/Stream overloads stay and use an
unlimited budget, so no caller breaks.

### D6. Configuration

New `.yaml` section, following the existing section pattern (sparse
object, accessor with defaults, `resolved()`, `$`, range checks):

```yaml
memory:
  limit: auto        # auto | unlimited | <size>
  source: auto       # auto | memory | mmap | seek | stream
  mmap: auto         # auto | on | off
  map-window: 64MiB  # windowed mapping size on 32-bit / fallback
  page-cache: auto   # seekable-tier cache size
  spool: auto        # auto | on | off
  spool-dir: auto    # temp dir for spooling
```

CLI: `--memory-limit=<size>` and `--source=<tier>` on every data command,
overriding the config. `yaml config` prints the resolved values, including
the detected host memory and the tier each input got (`--verbose`).

### D7. Errors

`YamlMemoryLimitError` message shape:

```
huge.yaml:120034:5: memory limit exceeded: query needs ~212 MiB to build
document 3 (limit 64 MiB). Use `yaml index huge.yaml`, narrow the path, or
raise memory.limit.
```

The CLI exits with a dedicated status (builder's call on the number,
documented in help) so scripts can tell the limit error from a parse error.

## Testing

- Generated inputs, not committed fixtures: a test helper writes a
  50–200 MB YAML file into the job tmp dir (many documents; one huge
  document; one huge block scalar; deep nesting).
- Each streaming command runs under `--memory-limit=256KiB` for the
  forced tiers `mmap`, `seek`, `stream` on the large inputs, and for all
  four tiers (including `memory`) on small inputs with a limit that fits;
  checks identical output across tiers and against today's output.
  Forced `memory` on a large input asserts the limit error.
- Peak memory is checked with `getMaxMem()` (ORC) from inside the test
  process, and with `/usr/bin/time -l` / `-v` for CLI runs, asserting
  peak RSS stays within limit + a fixed baseline.
- DOM commands: a document just under and just over the limit; the
  first succeeds, the second raises `YamlMemoryLimitError` before the
  process grows past limit + baseline.
- Accounting constants: a test builds DOMs of known shapes and asserts
  `getOccupiedMem` delta ≤ charged estimate × 1.25 and ≥ estimate × 0.5,
  so estimates stay honest across Nim versions.
- `--os:any` compile check of `yaml/memory.nim`, `yaml/source.nim`, the
  lexer and parser with a callback source, plus a host-side run of the
  same code with the callback backed by a string, producing the event
  stream for a yaml-test-suite sample.
- Partial stdout: convert of a stream whose 3rd document is invalid
  prints documents 1–2, then exits non-zero; with `-o file` the file is
  not created or left unchanged.
- 32-bit windowed mapping: forced by `map-window: 1MiB` on 64-bit hosts.
- Existing suites (`nim test`, yaml-test-suite, JSON-Schema-Test-Suite)
  keep passing unchanged.

## Phasing

1. `memory.nim`, `source.nim` (all four tiers + spool + callback), config
   section and CLI flags, lexer on sources, limit error. Convert, merge,
   format (both modes), lint, expand, indexed query, fingerprint hashing
   moved onto sources.
2. Spans and index build over sources; assignment by range copy; DOM
   charging for validate/patch/diff/canonical/non-indexed query; streaming
   JSONPath evaluator.
3. Chunked scalar events for pass-through commands (if deferred from D4),
   and a follow-up todo `streaming-json-schema` for validating documents
   larger than the limit.

Each phase ends with all suites green and is committed separately.

## Left to the builder

- Exact ratios/defaults (in-memory threshold, auto fraction, page size,
  window size), within the shapes above.
- Internal structure of the page cache and window remapping.
- Exit status number for the limit error.
- Whether the lexer's direct-view path is a separate code path or the
  buffer pointing at the mapped memory.
