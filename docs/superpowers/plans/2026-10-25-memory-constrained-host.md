# Memory-constrained Hosts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Huge YAML/JSON/CBOR files work inside a configurable memory limit on
any host, from microcontrollers (parser + event stream) to servers, choosing
the best input strategy per host (in-memory, mmap window, seek, stream).

**Architecture:** A `MemoryBudget` (yaml/memory.nim) is charged where memory
grows with input. A `YamlSource` (yaml/source.nim) gives every input a tier
and a `Stream` view; the lexer keeps reading `Stream`s (its buffer already
slides) and charges its buffer to the budget. The CLI reads every input
through sources and writes output lazily (one pulled `YamlStream` per
command), so streaming commands never hold the whole input or output.

**Tech Stack:** Nim 2.x (devel 2.3.1 locally), std/memfiles, std/streams,
std/unittest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-25-memory-constrained-host-design.md`

## Global Constraints

- Zero external dependencies; ORC is the default GC, ARC must still compile.
- Existing string/Stream APIs keep working unchanged (budget defaults to nil = unlimited).
- `memory.nim`, `source.nim` (callback and string parts), lexer and parser compile with `--os:any -d:useMalloc --mm:arc` (verified to work for the parser today).
- Stdout output may be partial on error with a non-zero exit; files are written to a temp file and renamed only on success; `-i` over several files renames only after all succeeded.
- A forced tier never overrides the limit; forced `stream` spools under `memory.spool` like a pipe.
- mmap is always a sliding window (default 64 MiB, capped at `limit div 2`), never the whole file.
- Exit code 3 = memory limit exceeded (documented in `yaml help` overview).
- Tests: build with `nim c -r test/<file>` (tasks are broken on this Nim); verify with `unittest` `check`, never `doAssert` (disabled by config.nims). Never comment out failing tests.

## Review Focus

1. Empty input and a file of size 0 on every tier — expect the same events as the in-memory path (stream start/end only), no mmap of length 0 (mmap fails on empty files).
2. Input whose size changes while read (log being appended) on the mapped/seek tiers — reads stop at the size seen at open; no crash. Test in Task 2.
3. CRLF line endings and a multi-byte UTF-8 character straddling a chunk/window boundary — identical output across tiers. Test in Task 2 (window 4 KiB, char at 4095).
4. A pipe input to a command that needs random access with `spool: off` — exit 3 with "needs random access" message, nothing partial written to files. Test in Task 4.
5. A limit smaller than one lexer chunk (e.g. `--memory-limit=1KiB`) — clean exit 3, never a crash or hang. Test in Task 3.

---

## Phase 1 — budget, sources, streaming commands

### Task 1: `yaml/memory.nim` — budget, sizes, host detection

**Files:** Create `yaml/memory.nim`; Test `test/tmemory.nim`; Modify `test/tests.nim` (import), `config.nims` (task `memoryTests`).

**Interfaces — Produces:**
```nim
type
  MemoryBudget* = ref object
    limit*: int       ## bytes; int.high = unlimited
    used*, peak*: int
  YamlMemoryLimitError* = object of ValueError
    operation*: string
    needed*, limit*: int
const yamlMemoryLimit* {.intdefine.} = 0  ## compile-time default; 0 = none
proc newMemoryBudget*(limit = int.high): MemoryBudget
proc reserve*(b: MemoryBudget, bytes: int, operation: string) {.raises: [YamlMemoryLimitError].}  # nil b: no-op
proc release*(b: MemoryBudget, bytes: int) {.raises: [].}                                         # nil b: no-op
proc available*(b: MemoryBudget): int  # int.high for nil
proc parseSize*(text: string): int {.raises: [ValueError].}  # "123", "64KiB", "16MiB", "1GiB", "2TiB", "unlimited"; also KB/MB/GB as 1000-based
proc formatSize*(bytes: int): string   # "64 MiB", "1.5 GiB", "512 B", "unlimited"
proc hostMemory*(): int                # bytes usable by this process; -1 unknown
proc autoLimit*(): int                 # hostMemory div 2, else yamlMemoryLimit, else int.high
proc memoryLimitError*(e: ref Exception): ref YamlMemoryLimitError  # walks e.parent chain; nil if none
proc describe*(e: ref YamlMemoryLimitError): string  # "memory limit exceeded: <operation> needs ~X (limit Y)"
```
hostMemory: Linux cgroup v2 `/sys/fs/cgroup/memory.max`, v1 `/sys/fs/cgroup/memory/memory.limit_in_bytes`, then `/proc/meminfo` MemAvailable; macOS `sysctlbyname("hw.memsize")`; Windows `GlobalMemoryStatusEx.ullAvailPhys`; all behind `when defined(...)`; other OS → -1. Module imports only system + strutils so it builds with `--os:any`.

- [ ] Step 1: tests `parseSize` (`"64KiB" == 65536`, `"1GiB" == 1 shl 30`, `"10MB" == 10_000_000`, `"unlimited" == int.high`, `expect ValueError: "12XB"`, `"-1"`), `formatSize(64 shl 20) == "64 MiB"`, `reserve` past limit raises with `needed`/`limit` set and leaves `used` unchanged, `release` lowers `used`, `peak` tracks max, nil budget never raises, `hostMemory() > 0` on macOS/Linux, `autoLimit() == hostMemory() div 2`, `memoryLimitError` finds the error two parents deep.
- [ ] Step 2: run `nim c -r test/tmemory.nim` → fails (module missing).
- [ ] Step 3: implement.
- [ ] Step 4: run → passes.
- [ ] Step 5: commit "memory: MemoryBudget, sizes, host memory detection".

### Task 2: `yaml/source.nim` — progressive input tiers

**Files:** Create `yaml/source.nim`; Test `test/tsource.nim`; Modify `test/tests.nim`, `config.nims`.

**Interfaces — Consumes:** Task 1. **Produces:**
```nim
type
  SourceTier* = enum stInMemory = "memory", stMapped = "mmap", stSeekable = "seek", stSequential = "stream"
  TierChoice* = enum tcAuto = "auto", tcMemory = "memory", tcMmap = "mmap", tcSeek = "seek", tcStream = "stream"
  Switch* = enum swAuto = "auto", swOn = "on", swOff = "off"
  SourcePolicy* = object
    choice*: TierChoice       # default tcAuto
    mmap*: Switch             # default swAuto (off disables stMapped)
    mapWindow*: int           # 0 = default 64 MiB; capped at limit div 2
    pageCache*: int           # 0 = min(limit div 8, 1 MiB)
    spool*: Switch            # auto: spool when random access needed and a temp dir is writable
    spoolDir*: string         # "" = getTempDir()
  ReadProc* = proc (offset: int64, dest: var openArray[char]): int {.closure, gcsafe, raises: [IOError].}
  YamlSource* = ref object    # fields private except:
    tier*: SourceTier
    size*: int64              # -1 unknown
    name*: string
    budget*: MemoryBudget
  YamlSourceError* = object of IOError  # e.g. random access on a sequential source
proc sourceOf*(content: string, name = "<string>", budget: MemoryBudget = nil): YamlSource  # stInMemory, charges content.len
proc openSource*(path: string, budget: MemoryBudget = nil, policy = SourcePolicy(), randomAccess = false): YamlSource
proc openSource*(f: File, name: string, budget: MemoryBudget = nil, policy = SourcePolicy(), randomAccess = false): YamlSource  # stdin/pipes; seekable regular files use the file path rules
proc openSource*(read: ReadProc, size = -1'i64, name = "<callback>", budget: MemoryBudget = nil, randomAccess = false): YamlSource  # os:any-safe
proc randomAccess*(src: YamlSource): bool
proc read*(src: YamlSource, offset: int64, dest: var openArray[char]): int  # sequential: only offset == current position, else YamlSourceError
proc slice*(src: YamlSource, first, last: int64): string                   # inclusive bounds, clipped at size
proc newSourceStream*(src: YamlSource, offset = 0'i64): Stream             # forward Stream for the lexer; readDataStr/readData/atEnd/getPosition
proc readAll*(src: YamlSource, operation: string): string                   # charges size; for callers still needing the whole text
proc close*(src: YamlSource)
```
Tier rule for `tcAuto`, file size S, limit L: `S <= L div 4` → memory; mmap allowed and `when defined(posix) or defined(windows)` → mapped (window via `memfiles.open(path, mappedSize = pageSize, allowRemap = true)` + `mapMem`/`unmapMem`, window offset aligned down to 64 KiB, window charged to budget); else seekable (LRU of 4 KiB pages up to pageCache, charged); pipes → sequential (64 KiB read buffer, charged). Spool: copy to `spoolDir/yaml-spool-<pid>-<n>`, reopen by the file rules, delete on `close`. Size fixed at open (Review Focus 2). Empty file: mapped tier falls back to in-memory "" (Review Focus 1).

- [ ] Step 1: tests — for each forced choice (memory/mmap/seek/stream) on a generated 300 KiB file with CRLF lines and a 3-byte UTF-8 char at offset 4095 (`mapWindow = 4096`, `pageCache = 8192`): `readAll` equal to file content; `read(offset 4094, 4 bytes)` correct on random tiers; `slice(10, 19)` correct; `newSourceStream(src, 1000)` reads content[1000..^1]; sequential `read` backwards raises `YamlSourceError`; budget `peak <= window/page cache + 64 KiB` for mapped/seek; auto tier picks memory for 1 KiB file with 1 MiB limit, mmap for 300 KiB file with 256 KiB limit, seek when `mmap = swOff`; stdin-like `File` of a pipe (osproc `startProcess("cat")`) with `randomAccess = true` spools and reports `stSeekable` or `stMapped`, with `spool = swOff` raises `YamlMemoryLimitError` whose operation contains "needs random access"; callback source reads same bytes; empty file on all tiers gives "" and `size == 0`; file appended after open still reads only original size.
- [ ] Step 2: run `nim c -r test/tsource.nim` → fails.
- [ ] Step 3: implement.
- [ ] Step 4: run → passes.
- [ ] Step 5: commit "source: progressive YamlSource tiers with mmap window, page cache, spool".

### Task 3: lexer and parser charge the budget; parse sources

**Files:** Modify `yaml/private/lex.nim:45-65,165-195,948-966,1030-1086`, `yaml/parser.nim:20-130,202-285` (YamlParser field, init, parse overloads), `yaml/loading.nim` if it constructs parsers internally (pass-through only); Test `test/tmemory.nim` (new suite "lexer budget"), `test/tosany.nim` (compile check driver, run by test).

**Interfaces — Consumes:** Tasks 1–2. **Produces:**
```nim
# lex.nim
proc init*(lex: var Lexer, source: Stream, offset = 0, line = 1, budget: MemoryBudget = nil)
proc initFeed*(lex: var Lexer, offset = 0, line = 1, budget: MemoryBudget = nil)
# parser.nim
YamlParser.budget*: MemoryBudget              # set by init/initYamlParser(..., budget = nil)
proc parse*(p: YamlParser, src: YamlSource): YamlStream            # newSourceStream(src); string-tier sources use the string path
proc parse*(p: YamlParser, src: YamlSource, start: YamlDocumentStart): YamlStream
```
SourceBuffer gets `budget` and `charged` fields: growth in `fetch`/`feed` reserves the delta with operation "reading line N" (N = current line), `compactBuffer` releases what it drops. A reservation failure is stored as `b.error` (so it surfaces as a LexerError → YamlParserError whose parent is the `YamlMemoryLimitError`) and `fetch` returns EndOfFile. String input is never charged (its source already was).

- [ ] Step 1: tests — parsing a generated 5 MB stream of small documents via `parse(openSource(path, newMemoryBudget(256 shl 10), SourcePolicy(choice: tcSeek)))` yields the same events as `parse(readFile(path))` and budget `peak < 256 KiB`; a single 300 KiB plain scalar line with limit 128 KiB raises `YamlStreamError` whose `memoryLimitError` is not nil and whose operation names line 1; limit `1KiB` on any input raises the limit error, no hang (Review Focus 5); feed parser with a budget charges fed data; `tosany`: `execCmdEx("nim c --os:any -d:useMalloc --mm:arc --compileOnly ... test/osany/parse.nim")` exits 0, where `test/osany/parse.nim` parses via a callback source; host run of the same file (without `--os:any`) prints the events of `a: [1, 2]`.
- [ ] Step 2: run → fails.
- [ ] Step 3: implement.
- [ ] Step 4: run `nim c -r test/tmemory.nim`, `nim c -r test/tparser.nim`, `nim c -r test/tfeed.nim`, `nim c -r test/tcheckpoint.nim` → pass.
- [ ] Step 5: commit "lexer, parser: charge the memory budget, parse YamlSource".

### Task 4: config section, CLI flags, limit errors

**Files:** Modify `yaml/toolconfig.nim` (MemoryConfig, accessors, resolved, `$`, checks, module doc), `tools/yamlcli.nim` (global options, describe, exit 3, help text); Test `test/tyamlcli.nim` (suites "memory config", "memory cli").

**Interfaces — Consumes:** Tasks 1–3. **Produces:**
```nim
# toolconfig.nim
MemoryConfig* {.sparse.} = object
  limit*: Option[string]            ## auto | unlimited | size; none: auto
  source*: Option[TierChoice]
  mmap*: Option[Switch]
  mapWindow* {.yamlKey: "map-window".}: Option[string]
  pageCache* {.yamlKey: "page-cache".}: Option[string]   ## auto | size
  spool*: Option[Switch]
  spoolDir* {.yamlKey: "spool-dir".}: Option[string]     ## auto | path
ToolConfig.memory* {.defaultVal: MemoryConfig().}: MemoryConfig
proc memoryLimit*(config: ToolConfig): int          # parseSize or autoLimit
proc sourcePolicy*(config: ToolConfig): SourcePolicy
# yamlcli.nim (private)
var memoryOverride: tuple[limit: Option[int], source: Option[TierChoice]]  # from --memory-limit:/=, --source:/=, removed from args in run()
proc budgetFor(file: string): MemoryBudget
proc policyFor(file: string): SourcePolicy
proc openInput(file: string, randomAccess = false): YamlSource   # "" or "-" = stdin
```
`parseToolConfig` rejects bad sizes ("memory: limit: …"). `$` prints the section with `# detected host memory: X` after `limit`. `describe` prints `name:line:col: memory limit exceeded: …. Raise memory.limit or use --memory-limit` when `memoryLimitError(e)` is not nil; `run` maps any exception carrying a limit error to exit 3. Overview gains "Exit code 3 if the memory limit is exceeded" and `--memory-limit`/`--source` lines; `configHelp` gains the memory section.

- [ ] Step 1: tests — `parseToolConfig("memory: {limit: 64KiB, source: seek, mmap: off}")` gives `memoryLimit == 65536`, policy choice tcSeek, mmap swOff; `memory: {limit: lots}` raises ToolConfigError; `yaml config --print` contains `memory:` and `limit: auto`; `yaml convert json --memory-limit=1KiB a.yaml` exits 3 with "memory limit exceeded"; `yaml index --memory-limit=64KiB --source=stream` on a piped… (index takes files: use `yaml query '$.a = 1' --source=stream` via stdin with `memory: {spool: off}` in a config dir) exits 3 with "needs random access" (Review Focus 4); `yaml help` mentions exit code 3; `--verbose` prints `NAME: tier mmap, limit 1 MiB` per input to stderr.
- [ ] Step 2: run `nim c -r test/tyamlcli.nim` → new tests fail.
- [ ] Step 3: implement.
- [ ] Step 4: run → pass.
- [ ] Step 5: commit "toolconfig, yaml: memory section, --memory-limit, --source, exit code 3".

### Task 5: inputs as sources — JSONC/JSONL filters, streaming CBOR

**Files:** Modify `yaml/loading.nim:75` (add stream filter beside `stripJsonComments`), `yaml/cbor.nim:190-455` (buffered reader), `tools/yamlcli.nim` (`Input` → source-based, `events`); Test `test/tcbor.nim`, `test/tjson.nim` (or the existing JSONC test file), `test/tyamlcli.nim`.

**Interfaces — Produces:**
```nim
proc newJsonCommentStripStream*(input: Stream): Stream   # loading.nim; same output as stripJsonComments, positions preserved (comments → spaces)
proc newJsonLinesStream*(input: Stream): Stream          # yamlcli or loading.nim: "--- " before each non-blank line, as jsonLinesAsYaml
proc parseCbor*(input: Stream, budget: MemoryBudget = nil): YamlStream  # reads through a 64 KiB refilled window; byte/text strings charged while held
# yamlcli.nim
proc events(src: YamlSource, format: DataFormat, budget: MemoryBudget): YamlStream
```
The CBOR stream reader keeps `pos` absolute (marks unchanged) and reads definite strings by length, refilling.

- [ ] Step 1: tests — for each JSONC sample in the existing tests, `readAll(newJsonCommentStripStream(newStringStream(x))) == stripJsonComments(x)` including a comment split across 8 KiB chunk boundaries; JSONL stream equals `jsonLinesAsYaml`; `parseCbor(newStringStream(x))` events equal `parseCbor(x)` for every existing CBOR test vector and for a 2 MB generated CBOR document read with budget 256 KiB (peak < 256 KiB); CLI convert of the existing `b.jsonc`, `c.jsonl` and a `.cbor` file gives unchanged outputs.
- [ ] Step 2: run → fail.
- [ ] Step 3: implement; switch `events()` and `readInputs` callers to sources (`readInputs` returns `seq[tuple[name: string, src: YamlSource]]`, opened lazily per input so only one is open at a time).
- [ ] Step 4: run `nim c -r test/tcbor.nim`, `nim c -r test/tyamlcli.nim` → pass.
- [ ] Step 5: commit "inputs: JSONC/JSONL stream filters, streaming CBOR decoder, CLI inputs as sources".

### Task 6: lazy output — convert, merge, -i via temp files; presenter lookahead cap

**Files:** Modify `tools/yamlcli.nim:397-483,583-613,787-933`, `yaml/presenter.nim:845-887` (lookahead cap); Test `test/tyamlcli.nim`, `test/tpresenter.nim`.

**Interfaces — Produces (yamlcli.nim, private):**
```nim
proc normalizing(s: YamlStream, resolveTags: bool): YamlStream       # per-event version of `normalize`
proc writeStream(output: Stream, events: YamlStream, format: DataFormat, yamlStyle: FormatConfig)  # events: full stream incl. start/end
proc writeFileAtomically(file: string, write: proc (s: Stream)): string  # writes <file>.yaml-tmp-<pid>, returns temp path; caller renames
proc commitFiles(temps: seq[tuple[temp, file: string]])              # rename all + refreshIndex; on any earlier error the caller removes temps
proc concatenated(inputs: seq[...], each: proc (src): YamlStream): YamlStream  # one start/end stream around the documents of all inputs, opened in order
```
JSON/JSONL: each document is presented as its own stream through a stream wrapper that drops trailing whitespace and ends it with one `\n` (exactly `renderEach`'s `strip(leading = false) & "\n"`), so nothing per document is buffered. Presenter `checkSingleLine`: stop scanning once `length` reaches the max line length (result unchanged: it was false anyway); with no max line length stop at `maxSingleLineLookahead = 65536` characters and choose block style (documented in `PresentationOptions.condenseFlow` docs).

- [ ] Step 1: tests — all existing convert/merge/patch CLI expectations unchanged; `yaml convert json` of a 3-document file whose 3rd document is invalid prints the first 2 documents and exits 1; `yaml merge -i x.yaml y.yaml` where y.yaml is invalid leaves x.yaml unchanged and no `*.yaml-tmp-*` files remain; presenter: a flow sequence of 100 000 scalars with `maxLineLength = some(80)` produces the same output as before (compare against `present` output of git devel computed in-test from the old code path via block style expectation: it is block); with `maxLineLength = none` and > 65 536 characters it is block; RSS test is in Task 9.
- [ ] Step 2: run → fail.
- [ ] Step 3: implement.
- [ ] Step 4: run `nim c -r test/tyamlcli.nim`, `nim c -r test/tpresenter.nim` → pass.
- [ ] Step 5: commit "yaml: lazy output for convert and merge, atomic -i, presenter lookahead cap".

### Task 7: format in bounded memory

**Files:** Modify `yaml/presenter.nim:1300-1520` (doTransform: no full buffering without comments; per-document buffering with comments; attachComments over a document's text), `yaml/dumping.nim:235-262` (YamlSource overloads), `tools/yamlcli.nim:487-581`; Test `test/tcomments.nim`, `test/tyamlcli.nim`.

**Interfaces — Produces:**
```nim
proc transform*(input: YamlSource, output: Stream, options = PresentationOptions(), resolveToCoreYamlTags = false)  # presenter.nim
proc transform*(dumper: Dumper, input: YamlSource, output: Stream, resolveToCoreYamlTags = false)                  # dumping.nim
```
Without comments: events are normalized lazily and presented as they come. With comments: the parser runs with `keepComments`; events and comments of one document are buffered (charged to the source's budget per event: 64 bytes + content length), the document's text is `src.slice(docStartOffset, docEndOffset)`, and `attachComments` gets that text plus the document's first line number so its line indexes stay right. `hasComments` scans a source stream. `--check` compares through a stream that reads the source alongside the formatted output; `--write` writes to a temp file and renames only if different.

- [ ] Step 1: tests — every existing tcomments case gives identical output through the `YamlSource` overload on tiers memory and seek; a 3-document input with comments in each formats identically to the string path; CLI `format --check` and `--write` expectations unchanged.
- [ ] Step 2: run → fail.
- [ ] Step 3: implement.
- [ ] Step 4: run `nim c -r test/tcomments.nim`, `nim c -r test/tpresenter.nim`, `nim c -r test/tyamlcli.nim` → pass.
- [ ] Step 5: commit "format: stream without comments, per-document with comments".

### Task 8: query, canonical, patch, diff, index fingerprint, lint/validate/expand on sources

**Files:** Modify `tools/yamlcli.nim` (query, documents, canonical, diff, patch, index read), `yaml/nodeindex.nim:181-195,506-545` (`fingerprintFile`), `tools/yamllint.nim:95-110` + `yaml/lint.nim:352` + `yaml/schemavalidation.nim:88` (`YamlSource` overloads), `tools/yamlexpand.nim` + `yaml/portable.nim:113`; Tests `test/tnodeindex.nim`, `test/tlint.nim`, `test/tportable.nim`, `test/tyamlcli.nim`.

**Interfaces — Produces:**
```nim
proc fingerprintFile*(path: string, mtime = 0'i64): SourceFingerprint  # nodeindex; FNV-1a over 64 KiB chunks, same value as fingerprint(readFile(path))
proc lint*(src: YamlSource, config = defaultConfig(), sourceUri = ""): seq[Diagnostic]
proc validateDocuments*(src: YamlSource, registry: SchemaRegistry, sourceUri = "", options = ValidationOptions()): seq[Diagnostic]
proc expandDirectives*(src: YamlSource, output: Stream, options = ExpandOptions(), sourceUri = "")
```
Query results are written lazily (a `concatenated` stream of `represent(found.node)` per match); per-document DOMs read from the source stream. Lint: `LintContext.source` becomes a line provider (`lineText(n)` from a bounded cache over `src`); rules that read `ctx.source` directly are switched to it. Assignment keeps reading the whole text via `readAll(src, "query: assignment")` (charged) until Task 13.

- [ ] Step 1: tests — `fingerprintFile(p) == fingerprint(readFile(p))` (hash and size); all existing lint/validate/expand/query/canonical/patch/diff expectations unchanged; `lint(openSource(p, policy = seek))` equals `lint(readFile(p))` on all lint test inputs; `expandDirectives(src, out)` equals the string result on all portable tests.
- [ ] Step 2: run → fail.
- [ ] Step 3: implement.
- [ ] Step 4: run the four test files → pass.
- [ ] Step 5: commit "query, lint, validate, expand, index: read inputs through sources".

### Task 9: constrained-run harness

**Files:** Create `test/tconstrained.nim`, `test/genhuge.nim` (generator procs); Modify `test/tests.nim`, `config.nims` (task `constrainedTests`).

**Interfaces — Produces:** `proc genManyDocs(path: string, bytes: int)`, `genHugeDoc`, `genFlatFlowSeq` in genhuge.nim; `proc peakRss(cmd: seq[string], input = ""): tuple[output: string, code, rssBytes: int]` using `/usr/bin/time -l` (macOS, bytes) or `-v` (Linux, KiB).

- [ ] Step 1: tests — generate 64 MB many-docs file, 64 MB single document; for `convert json`, `convert cbor`, `merge`, `format`, `format --drop-comments`, `lint`, `query '$.k'` (per-document), `index` (Task 13 adds), `canonical` (per document): run with `--memory-limit=1MiB` for `--source=mmap|seek|stream`, outputs identical to an unlimited run (compare file hashes), `rssBytes <= baseline + 1 MiB + 4 MiB`, where baseline is the RSS of the same command on a 1 KiB file; `--source=memory` on the 64 MB file exits 3.
- [ ] Step 2: run `nim c -r test/tconstrained.nim` → passes for the commands Phase 1 covered; the DOM-on-huge-document cases are expected to exit 3 (asserted).
- [ ] Step 3: commit "test: constrained runs of the yaml tool on generated huge inputs".

## Phase 2 — DOM charging, spans, assignment, streaming JSONPath

### Task 10: charge DOM and typed construction

**Files:** Modify `yaml/dom.nim` (construct), `yaml/native.nim` (`constructChild` generic paths), `yaml/loading.nim` (`load*`/`loadAs*` budget overloads); Test `test/tmemory.nim` suite "construction".

**Interfaces — Produces:** `ConstructionContext.budget*: MemoryBudget`; `proc construct*(s: var YamlStream, target: var YamlNode, budget: MemoryBudget)`; `proc load*[K](input: Stream | string | YamlSource, target: var K, budget: MemoryBudget)`; constants `nodeOverhead*`, `objectOverhead*` in memory.nim. Charges: per YamlNode `nodeOverhead + content.len`, per generic object/ref `sizeof(T)`, per string/seq growth its length × element size. Charges are released when construction fails, kept by the caller otherwise (budget released when the command's document is done).

- [ ] Step 1: tests — DOM of a 10 000-entry mapping charges between 0.5× and 1.25× the `getOccupiedMem()` delta; a document just under the limit constructs, one 2× over raises `YamlMemoryLimitError` before `getOccupiedMem()` grows past limit + 1 MiB; `loadAs[seq[Obj]]` charges similarly.
- [ ] Step 2–4: fail, implement, pass (`tmemory`, `tdom`, `tnative`).
- [ ] Step 5: commit "dom, native: charge construction to the memory budget". CLI DOM commands pass their budget (query, patch, diff, canonical, validate) and release after each document.

### Task 11: spans and index build over sources

**Files:** Modify `yaml/spans.nim`, `yaml/nodeindex.nim:229-260,546-602`, `tools/yamlcli.nim` (index command, writeSource/refreshIndex from file); Test `test/tnodeindex.nim`.

**Interfaces — Produces:** `proc sourceSpans*(src: YamlSource, json = false): SourceSpans` (streams events; line starts tracked from marks, not a table over the text); `proc buildIndex*(src: YamlSource, spans: SourceSpans, mode = imAll, json = false, mtime = 0'i64): YamlIndex` (digests computed from `src.slice` per entry); `proc refreshIndex*(file: string, settings: IndexSettings, json = false)` reading the file through a source.

- [ ] Steps: tests that both overloads give equal indexes on all tnodeindex inputs and on a 64 MB generated file under 1 MiB (added to tconstrained); fail; implement; pass; commit "spans, index: build over sources".

### Task 12: assignment by range copy

**Files:** Modify `yaml/edit.nim:350-430`, `tools/yamlcli.nim` (assigned, -i); Test `test/tedit.nim`.

**Interfaces — Produces:** `proc assign*(src: YamlSource, path: JsonPath, value: string, output: Stream, options = PresentationOptions(), json = false): int` (count); copies unchanged byte ranges with `src.read` in 64 KiB chunks between edits. CLI writes to stdout directly or to a temp file for -i.

- [ ] Steps: test equality with the string `assign` on all tedit cases and tiers seek/stream(spooled); add 64 MB assignment to tconstrained; fail; implement; pass; commit "edit: assignment over sources by range copy".

### Task 13: streaming JSONPath evaluator

**Files:** Create `yaml/jsonpathstream.nim`; Modify `tools/yamlcli.nim` (query uses it when supported); Test `test/tjsonpathstream.nim`.

**Interfaces — Produces:** `proc streamable*(path: JsonPath): bool` (segments: name, index ≥ 0, wildcard, descendant, slice with non-negative start/end and positive step, filter selectors); `iterator queryStream*(s: YamlStream, path: JsonPath, budget: MemoryBudget): tuple[path: string, node: YamlNode]` (per document; builds a DOM only for selected nodes and for each candidate child a filter tests). Non-streamable paths (negative indices/slices, negative steps) fall back to per-document DOM.

- [ ] Steps: test that for every RFC 9535 compliance test case where `streamable` is true and the input is valid, `queryStream` gives the same nodes and normalized paths in the same order as `queryLocated`; a 64 MB single-document query `$.items[*].id` under 1 MiB in tconstrained; fail; implement; pass; commit "jsonpath: streaming evaluator for query".

## Phase 3 — follow-ups

### Task 14: todo and docs

**Files:** Modify `todo.yml` (move `memory-constrained-host` to done with its features; add `streaming-json-schema` and `chunked-scalar-events` todos), `README.md` (memory limits section), `CHANGELOG.md`.

- [ ] Step 1: write; Step 2: full suite `nim c -r test/tests.nim` and `nim c -r test/tconstrained.nim` pass; Step 3: commit "todo, docs: memory-constrained hosts".

Chunked scalar events (spec D4) are deferred to the `chunked-scalar-events` todo, as D4 allows: a single scalar larger than the limit fails with the limit error, which Task 3 tests.
