# NimYAML for JavaScript

NimYAML, the `yaml` command and the `yamllsp` language server, compiled
with Nim's JavaScript backend into ES modules that run in Node, Bun, Deno
and browsers. It is the same code as the native build, not a port: what
the JavaScript backend lacks — files, standard streams, raw memory — the
library reaches through a *host* that the embedder installs, and the rest
compiles unchanged. The native suites check the native build; the yaml
command's own suite, `test/tyamlcli.nim`, also runs against this one (all
67 tests pass).

## Building

```sh
node js/build.mjs           # or: nim jsModules   (Nim on PATH, or $NIM)
node js/build.mjs --debug   # without -d:release, with Nim's stack traces
```

This writes `js/dist/nimyaml.mjs` (about 4.4 MB, 650 KB gzipped), which
every module below imports. `dist/` is built, not committed.
`js/nimyaml_js.nim` is what is compiled: each `nimyaml_X` proc there is the
export `X`, taking and returning strings (JSON text in, `{ok}`/`{error}`
envelopes out). The modules turn those into an API.

## As a package

`js/` is the bun package `nimyaml.js` (private, not published). Register it
once from this folder, then link it where it is used:

```sh
cd js && bun link                         # registers nimyaml.js → this folder
# in the package that uses it, package.json:
#   "dependencies": { "nimyaml.js": "link:nimyaml.js" }
bun install                               # node_modules/nimyaml.js → js/
```

A link is to this folder as it is, so `dist/` must be built here first
(`node js/build.mjs`) and is rebuilt here when the Nim sources change.
webstack's `yaml-language` (its CodeMirror plugin) uses it this way, and
its static server mounts the link at `/js/`, the folder's name.

## The library: `yaml.mjs`

```js
import * as Y from "./js/yaml.mjs";

Y.load("a: [1, x]")                         // { a: [1, "x"] }
Y.loadAll("--- 1\n--- 2\n")                 // [1, 2]
Y.load("[0x1F, 1_000, .inf, .nan]")         // [31, 1000, Infinity, NaN]
Y.dump({ a: 1, n: "80" })                   // 'a: 1\nn: "80"\n'
Y.dump(value, { style: "json" })            // default, block, minimal, canonical, explanatory, json
Y.lint("a: 1\na: 2\n")                      // [{rule: "duplicate-key", severity, message, start, end}]
Y.validate({ a: "x" }, schema)              // JSON Schema output, {valid, errors}; format: flag/basic/detailed/verbose
Y.query(value, "$.a[*]")                    // [{path, value}]
Y.applyPatch(value, patch)                  // RFC 6902
Y.applyMergePatch(value, patch)             // RFC 7396; also createMergePatch
Y.diff(oldValue, newValue)                  // the JSON Patch between them
Y.inferSchema([doc1, doc2])                 // a JSON Schema
Y.canonicalize(value)                       // RFC 8785 text
Y.expandDirectives(text)                    // %GLOBAL/%SCHEMA expanded
Y.assign(text, "$.a", "42")                 // {text, count}, comments and styles kept
Y.set("# head\n", ["files", "save-delay"], 10) // "# head\nfiles:\n  save-delay: 10\n"; adds what is missing
Y.remove(text, "$.files['save-delay']")     // the member and the comments above it; empty mappings go too
```

Errors are `YamlError`s, with `kind` (the Nim exception) and, for an error
in the input, `line`, `column` and `lineContent`.

## The command: `cli.mjs`, `bin/yaml.mjs`

```sh
node js/bin/yaml.mjs format -i config.yaml    # as the native `yaml`
```

```js
import { run } from "./js/cli.mjs";
import { memoryHost } from "./js/hosts/memory.mjs";

const host = memoryHost({ files: { "/a.yaml": "a: 1\n" } });
run(["$.a = 2", "-i", "/a.yaml"], { host });   // exit code 0
host.text("/a.yaml");                         // "a: 2\n"
```

## Hosts

The host is a plain object of synchronous methods, bytes as `Uint8Array`;
`yaml/private/jshost.nim` documents the contract.

* `hosts/memory.mjs` — files in a map, streams in strings. With `onMiss`,
  it reports the paths it was asked for and did not know, which is how the
  language server's worker asks the page for files.
* `hosts/node.mjs` — the real file system and streams, through `node:`
  modules (Node, Bun, Deno), with the optional methods: symbolic links and
  permissions are kept by in-place writes, and files larger than the
  memory budget allows are read by seeking.

## The language server: `lsp/`

The server follows the design of Rei's stage 2 developer tools (its
`stage2-design.md`, §4.3 and §6.1): a pure step core, and a small driver
per host that is the only code naming one.

* `lsp/core.mjs` — `createCore().step(messages)` →
  `{out, save, read, exited, exitCode}`. A batch is checked once per
  document (`handleBatch` in `tools/yamllsp.nim`); a request a later edit
  in the batch made stale is answered `ContentModified`. `read` lists the
  files the server needed and the host did not have.
* `lsp/driver.mjs` — the event loop: queues messages, steps the whole
  queue, carries out `out`, `save` and `read`, and feeds answers back as
  `nimyaml/filesChanged`.
* `lsp/server-worker.mjs` — the driver in a browser's **dedicated worker**,
  talking whole messages by `postMessage`. It owns no file system: it asks
  the page for files. It keeps open documents in OPFS (`lsp/opfs.mjs`):
  debounced 300 ms per document, written whole through a sync access handle,
  retried while another window holds the file. At start, before the server
  loads, it hands the page what OPFS holds.
* `lsp/transport.mjs` — the page's side: `startServer({readFile,
  persist})` returns the `transport` for `@codemirror/lsp-client`, the
  `restored` documents and `flush`; `flushOnHide` sends the editor's text
  on `pagehide`, since a dedicated worker dies with its page.
* `lsp/stdio.mjs` — the driver over standard streams, for editors that
  start a process: `node js/lsp/stdio.mjs`.

A dedicated worker rather than a service worker: the editor is its only
client, `FileSystemSyncAccessHandle` exists only in dedicated workers, and
a service worker may be stopped whenever idle, losing the open documents.

```js
import { LSPClient } from "@codemirror/lsp-client";
import { startServer, flushOnHide } from "nimyaml.js/lsp/transport";

const server = startServer({ persist: true, readFile: (path) => myFiles.get(path) ?? null });
const client = new LSPClient().connect(server.transport);
flushOnHide(server, () => openDocuments());   // [{uri, text}]
```

## Tests

```sh
node --test js/test/                 # library, command, core, driver, stdio, OPFS logic
deno test -A js/test/worker.test.mjs # the worker, in a real Web Worker (or bun test)
node js/test/browser/run.mjs         # the worker in headless Chromium, with real OPFS
YAML_CLI_COMMAND="node js/bin/yaml.mjs" nim c -r test/tyamlcli.nim
```

## What differs from native

* Standard input is read whole: there are no pipes to read in parts, so
  `yaml lsp` (which reads its input as it comes) is served by
  `lsp/stdio.mjs` instead.
* A host without `size`/`readAt` reads every file whole; without
  `isLink`/`realpath`/`mode`/`chmod` it has no links and no permissions.
* Without a memory budget set, nothing is charged: the host's memory is
  not known.
