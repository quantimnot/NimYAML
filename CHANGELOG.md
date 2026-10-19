## Unreleased

Features:

 * added `YamlFeedParser`, a push-style parser for input that arrives in
   chunks (`newYamlFeedParser`, `feed`, `finish`, `tryNext`, `events`).
   `tryNext` returns `false` when more input is needed and resumes once more
   input has been fed. See the README for caveats: events lag behind the
   input by up to one token, and feeding large flow collections in small
   chunks costs time quadratic in the collection size. A completion gate
   makes feeding large scalars in small chunks linear.
 * added checkpoints: `checkpoint` captures the state of a parser or feed
   parser between two events as plain, serializable data; `resume` and
   `newYamlFeedParser(parser, checkpoint)` continue parsing from it, given
   the input from `checkpoint.offset` on. See the README for caveats.
 * added `documentStart` and `parse(parser, input, start)` (also for streams
   and `newYamlFeedParser`): record where each document of a stream begins
   and parse from any document on, without the documents before it.
 * added `parseRecovering`: after an invalid document, records the error and
   continues with the next document (see the README for caveats).
 * added `yaml/diagnostics` and `yaml/lint`: a lint engine with syntax,
   mapping key, anchor and text rules, configured by `.nimyaml-lint.yaml`,
   plus the `tools/yamllint` command line tool and the `tools/yamllsp`
   language server.
 * the lexer no longer depends on `std/lexbase`; consumed input is dropped
   between events, so memory use for `Stream` input stays bounded.
 * new module `yaml/fragment` resolves RFC 9512 fragment identifiers
   (`#`, `#/json/pointer`, `#*anchor`) against YAML input
 * added `resolveRelativePointer` to `yaml/fragment`, which evaluates Relative
   JSON Pointers (draft-hha-relative-json-pointer-00, e.g. `1/0`, `0+1#`)
   from a starting location given as a JSON Pointer
 * new module `yaml/jsonpath` implements JSONPath (RFC 9535) on `YamlNode`
   graphs: `parseJsonPath`, `query` and `queryLocated` (nodes with their
   Normalized Paths). All selectors, filters and the standard functions
   `length`, `count`, `match`, `search` and `value` are supported, and the
   JSONPath Compliance Test Suite passes (added as a submodule). `match` and
   `search` use a new built-in, linear-time I-Regexp (RFC 9485) engine with
   Unicode General Category support, so there is still no dependency on PCRE.
 * added `dumpMultiDoc`, which dumps several values as documents of a single
   YAML stream (counterpart of `loadMultiDoc`)
 * new module `yaml/jsonschema` validates `YamlNode` graphs against JSON
   Schema drafts 2020-12, 2019-09, 07, 06 and 04: `compile`, `isValid`,
   `validate` with the flag, basic, detailed and verbose output formats,
   annotations, `SchemaRegistry` with an optional `SchemaLoader`, and
   `checkSchema`. Numbers are compared exactly; formats (including
   `idn-hostname` with IDNA2008/UTS 46) are checked with `formatAssertion`.
   The JSON Schema Test Suite (added as a submodule) passes completely,
   including its optional, output and annotation tests. Patterns are matched
   by a new built-in ECMA-262 regular expression engine.
 * new module `yaml/hyperschema` discovers and resolves the links of JSON
   Hyper-Schema (`links`, `resolveTarget`, `toYaml`)
 * new module `yaml/uritemplate` expands RFC 6570 URI Templates at all
   levels; the uritemplate-test suite (added as a submodule) passes
 * NimYAML's own directives `%SCHEMA <uri-reference>` (the JSON Schema of the
   document, resolved against the new parser option `sourceUri`) and
   `%GLOBAL <directive>` (a `YAML`, `TAG` or `SCHEMA` directive for every
   document of the stream, overridable per document). Enabled by default;
   `initYamlParser(directiveExtensions = false)` treats them as reserved
   directives. `yamlStartDoc` events carry the effective schema, the
   declarations in effect with origin and position, and directive issues
   (`directives` field); feed parsers, checkpoints, `parse(start)` and error
   recovery keep the global directives
 * reserved directives are now reported (`unknown-directive`), as YAML 1.2
   §6.8 asks; misuse of `%SCHEMA`/`%GLOBAL` is reported by nine further lint
   rules, and `schema-source` reports documents that name their schema in
   more than one way
 * new modules `yaml/documentschema` (which schema a document declares:
   `%SCHEMA` > `%GLOBAL SCHEMA` > `yaml-language-server` modeline >
   `$schema` key) and `yaml/schemavalidation` (validates each document
   against it, as diagnostics)
 * new module `yaml/portable` and tool `tools/yamlexpand`: expand global
   directives into per-document ones (optionally `%SCHEMA` into a modeline),
   so that other YAML processors read the stream the same way; presenter
   options `outputVersion = ovDocument` and `schemaDirective`
 * `yamllint` and `yamllsp` validate documents against their schema; the
   language server adds completion, hover, go-to-definition and document
   links for directives and schema references
 * added editor bindings for `yamllsp`: a VS Code extension in
   `editors/vscode` and a Helix `languages.toml` in `editors/helix`

Changes:

 * parameters of reserved directives are lexed one token per parameter
   (`ns-directive-parameter`), not as one token for the rest of the line
 * `YamlDocumentStart` has new fields `index` and `globals`; the checkpoint
   format version is now 2 (checkpoints of version 1 cannot be resumed)
 * `lint` takes an optional `sourceUri`
 * `parse(Stream)` no longer reads from the stream itself. Errors raised by
   the `Stream` are reported by the first `next` that needs the data, as
   "Encountered stream error" with the original exception in the cause
   chain, also when the read fails in the middle of a token.

Bugfixes:

 * properties of a root scalar on a `---` line (`--- !!str a`) were also
   applied to the root of the next document, which then failed with "Only
   one tag allowed per node" if it had a tag of its own
 * a flow collection on a `---` line (`--- {a: b}`, YAML 1.2 example 9.4)
   was rejected as "Illegal content at `---`"
 * an alias on a `---` line (`--- *a`) was rejected as "Illegal content at
   `---`"
 * a second `%TAG` for the same handle in one document silently replaced the
   first; it is now an error, as YAML 1.2 §6.8.2 says
 * error recovery parsed a document with directives that failed on or before
   its `---` line again from that line: the error was recorded twice, or the
   document came back without its directives
 * a JSON-style surrogate pair escape like `"\uD83D\uDCA9"` in a
   double-quoted scalar now yields the one character it encodes instead of
   two invalid surrogate code points
 * the start position of the root collection of a document that begins with
   `---` on a line of its own referred to the previous document
 * a failing internal assertion crashed with SIGSEGV (when not raised inside
   an exception handler) instead of reporting the failure
 * loading YAML with a redefined anchor into a `YamlNode` no longer crashes;
   aliases refer to the latest definition
 * `==` on `YamlNode` now returns `true` when comparing a cyclic node with
   itself

## 2.2.1

Bugfixes:

 * fixed a compilation error when compiling with mm:atomicArc flag (#148)

## 2.2.0

Features:

 * added `yamlKey` annotation that lets you load/write an object field
   from/to a YAML value with a key different from the field name. (#146)

Bugfixes:

 * Fixed a bug that made presenter sometimes emit incorrect YAML
   in a mapping with long entries (#143)

## 2.1.1

Bugfixes:

 * Fixed a bug that prevented float values to be serialized (#141)

## 2.1.0

Features:

 * New pragmas ``scalar`` and ``collection`` allow you to modify the
   presentation style used for certain types and object fields.
   Defined in new module ``yaml/style``.
 * The presenter now honors the node style set in the events it presents,
   if possible. So if a scalar is set to be a literal block scalar, it is
   presented as such unless impossible or presenter options specifically
   prevent this.
 * The presenter can now output single-quoted scalars. It only does so when
   this scalar style is explicitly set on an event.

Changes:

 * renamed ``canonicalDumper`` / ``setCanonicalStyle`` to
   ``explanatoryDumper`` / ``setExplanatoryStyle`` because it was
   a misnomer and there is nothing canonical about this output style.
   The terminology *canonical* was carried over from PyYAML, but the
   YAML specification uses that term for different things.
   The old names are kept with a ``deprecated`` pragma.
 * The ``explanatoryDumper`` now automatically enables the
   tag shorthand ``!n!``, because in this style you want that for readability.

Bugfixes:

 * Fixed a bug that prevented instances of generic types to be used in ``Option``
   fields (e.g. ``Option[seq[string]]``) (#101)
 * Fixed a bug that caused invalid indentation when dumping with certain
   settings (#140)
 * Fixed parsing errors for verbatim tags in flow style (#140)
 * Fixed a bug that caused presentation of block scalars in
   flow collections (#140)
 * Fixed a bug that sometimes caused the last word of a folded block scalar
   not to be presented.
 * Fixed maximum line length not properly implemented in presenter in a number
   of cases.
 * Fixed a bug that prevented the presenter from outputting compact
   flow mappings in cMixed mode.
 * Fixed block scalars as mapping keys not being presented properly.
 * Added workaround for a regression bug in Nim 2.0.2
   (https://github.com/nim-lang/Nim/issues/23112)

## 2.0.0

Breaking Changes:

 * Requires Nim 2.x
 * ``yaml/serialization`` has been split into
   ``yaml/native`` (low-level API to load a ``YamlStream`` into Nim vars),
   ``yaml/loading`` (high-level loading API) and
   ``yaml/dumping`` (high-level dumping API).
 * Dumping API now has a ``Dumper`` object.
   All dumping procs require an instance of this object.
   Previous parameters ``tagStyle``, ``handles`` and ``options`` have been
   moved into this object.
 * Constants with default values have been removed in favor of default values
   for object fields.
 * Low-level native API for loading and dumping has undergone changes to
   parameter order. Serialization and deserialization context is now first
   parameter, to be able to use prefix notation.
 * Removed ``PresentationStyle``; instead ``Dumper`` can be initialized with
   presets mirroring the former values of ``PresentationStyle``.
 * Removed deprecated ``YamlDocument`` type from DOM API.
   Use ``YamlNode`` instead.

Features:

 * Can now load and dump fields of the parent type(s) of used types (#131)
 * Updated type guessing to use regexes from YAML 1.2 instead of old YAML 1.1.
   Type guessing is used primarily for heterogeneous items
   (implicit variant objects).
 * Presenter no longer outputs trailing spaces
 * More presentation options
 * Simplified default presentation style: Don't output ``%YAML 1.2``,
   ``%TAG !n! ...`` or ``---`` by default.
   Output compact notation for collections.
 * Loading now works at compile time (#70, #91).
   Dumping doesn't work at compile time currently.

Bugfixes:

 * Don't crash on invalid input, instead raise a catchable
   ``YamlParserError`` (#129)
 * Fixed some parser errors in exotic edge cases
 * Several fixes to make the library work with Nim 2.x

## 1.1.0

Features:

 * ``YamlNode`` now contains node styles and preserves them
   when serializing to YAML again
 * Added ``maxLineLength`` to ``PresentationOptions``. (#119)
 * Added ``loadFlattened`` to resolve aliases while loading,
   instead of deserializing them into pointers. (#117)

Bugfixes:

 * Fixed problems with ARC/ORC (#120)
 * Fixes some edge cases around whitespace while parsing
 * Fixed a problem that made ``{.ignore: [].}`` fail when trying
   to ignore collection values. (#127)
 * Always write a newline character at the end of output, as required
   by POSIX for text files.
 * Fixed an error with loading recursive nodes into YamlNodes.
 * Fixed an error where ``0`` could not be loaded into an unsigned
   integer lvalue. (#123)
 * Fixed an error where `float32` values could not properly
   be deserialized. (#124)
 * Fixed a compiler error concerning stricteffects. (#125)

## 1.0.0

Features:

 * ``YamlNode`` can now be used with the serialization API (``load`` / ``dump``)
   and can be used to hold substructures that should not be deserialized to
   native types (#48).

Bugfixes:

 * Raise a proper exception when a stream contains no documents but one is
   expected (#108)
 * Comments after a block scalar do not lead to a crash anymore (#106)
 * Fixed an error with parsing document end markers (#115)
 * Fixed an error when serializing block scalars (#105)

## 0.16.0

Features:

 * dumping ``sparse`` objects now omits empty ``Option`` fields (#100).

Bugfixes:

 * Fixed several parser errors that emerged from updates on the test suite.
 * Fixed ``raises`` annotations which could lead to compilation errors (#99).

## 0.15.0

Features:

 * Compiles with --gc:arc and --gc:orc

Bugfixes:

 * Parser rewrite: Fixes some test suite errors (including #83)
 * Fixed problems where a syntax error lead to an invalid state (#39, #90)
 * Serialize boolean values as ``true`` / ``false`` instead of ``y`` / ``y``
   to conform to YAML 1.2 spec.

## 0.14.0

Features:

 * **Breaking change**:
   transient, defaultVal, ignore and implicit are now annotations.
 * Added ``sparse`` annotation to treat all ``Option`` fields as optional.

Bugfixes:

 * can now use default values with ref objects (#66)

## 0.13.1

Bugfixes:

 * Changed `nim tests` to `nim test` to make nim ci happy.

## 0.13.0

Bugfixes:

 * Fixed submodule link to yaml-test-suite.

Features:

 * Added support for `Option` type.

## 0.12.0

Bugfixes:

 * Made it work with Nim 0.20.2

### 0.11.0

Bugfixes:

 * Made it work with Nim 0.19.0

NimYAML 0.11.0 is unlikely to work with older Nim versions.

## 0.10.4

Bugfixes:

 * Made it work with Nim 0.18.0

### 0.10.3

Bugfixes:

 * Fixed a nimble error when installing the package.

Features:

 * Added `ignoreUnknownKeys` macro to ignore all mapping keys that do not map
   to a field of an object / tuple (#43).

### 0.10.2

Bugfixes:

 * Fixed a nimble warning (#42)
 * Make sure special strings (e.g. "null") are properly quoted when dumping JSON
   (#44)

### 0.10.1

Bugfixes:

 * Made it *actually* work with Nim 0.17.0.

### 0.10.0

Features:

 * Compatibility with Nim 0.17.0 (#40).
   **Important:** This fix breaks compatibility with previous
   Nim versions!

### 0.9.1

Features:

 * Added `YamlParser.display()` which is mainly used by tests
 * NimYAML now builds for JS target (but does not work properly yet)

Bugfixes:

 * Correctly present empty collections in block-only style (#33)
 * Correctly handle `{1}` (#34)
 * Recognize empty plain scalar as possible `!!null` value
 * Require colons before subsequent keys in a flow mapping (#35)
 * Allow stream end after block scalar indicators
 * Fixed regression bugs introduced with timestamp parsing (#37)

### 0.9.0

Features:

 * Better DOM API:
   - yMapping is now a Table
   - field names have changed to imitate those of Nim's json API
   - Better getter and setter procs
 * Added ability to resolve non-specific tags in presenter.transform

Bugfixes:

 * Fixed parsing floating point literals (#30)
 * Fixed a bug with variant records (#31)
 * Empty documents now always contain an empty scalar
 * Block scalars with indentation indicator now have correct whitespace on first
   line.

### 0.8.0

Features:

 * NimYAML now has a global tag URI prefix for Nim types,
   `tag:nimyaml.org,2016:`. This prefix is denoted by the custom tag handle
   `!n!`.
 * Support arbitrary tag handles.
 * Added ability to mark object and tuple fields as transient.
 * Added ability to set a default value for object fields.
 * Added ability to ignore key-value pairs in the input when loading object
   values.
 * Support `!!timestamp` by parsing it to `Time` from module `times`.

Bugfixes:

 * Fixed a bug concerning duplicate TagIds for different tags in the
   `serializationTagLibrary`
 * Convert commas in tag URIs to semicolons when using a tag URI as generic
   parameter to another one, because commas after the tag handle are interpreted
   as flow separators.

### 0.7.0

Features:

 * Better handling of internal error messages
 * Refactoring of low-level API:
   * No more usage of first-class iterators (not supported for JS target)
   * Added ability to directly use strings as input without stdlib's streams
     (which are not available for JS)
 * Added ability to parse octal and hexadecimal numbers
 * Restructuring of API: now available as submodules of yaml. For backwards
   compatibility, it is still possible to `import yaml`, which will import all
   submodules
 * Check for missing, duplicate and unknown fields when deserializing tuples and
   objects

Bugfixes:

 * Fixed double quotes inside plain scalar (#25)
 * Return correct line content for errors if possible (#23)
 * Some smaller lexer/parser fixes

### 0.6.3

Bugfixes:

 * Can load floats from integer literals (without decimal point) (#22)

### 0.6.2

Bugfixes:

 * Fixed problem when serializing a type that overloads the `==` operator (#19)
 * Fixed type hints for floats (`0` digit was not processed properly) (#21)

### 0.6.1

Bugfixes:

 * Fixed deserialization of floats (#17)
 * Handle IndexError from queues properly

### 0.6.0

Features:

 * Properly support variant object types
 * First version that works with a released Nim version (0.14.0)

Bugfixes:

 * Fixed a crash in presenter when outputting JSON or canonical YAML
 * Raise an exception when trying to output multiple documents in JSON style

### 0.5.1

Bugfixes:

 * Fixed a problem that was introduced by a change in Nim devel

### 0.5.0

Features:

 * Support variant object types (experimental)
 * Added ability to use variant object types to process
   heterogeneous data
 * Support `set` type
 * Support `array` type
 * Support `int`, `uint` and `float` types
   (previously, the precision must be specified)
 * Check for duplicate tag URIs at compile time
 * Renamed `setTagUriForType` to `setTagUri`

Bugfixes:

 * None, but fastparse.nim has seen heavy refactoring

### 0.4.0

Features:

 * Added option to output YAML 1.1
 * Added benchmark for processing YAML input
 * Serialization for OrderedMap
 * Use !nim:field for object field names (#12)

Bugfixes:

 * Code refactoring (#9, #10, #11, #13)
 * Some small improvements parsing and presenting

### 0.3.0

Features:

 * Renamed some symbols to improve consistency (#6):
   - `yamlStartSequence` -> `yamlStartSeq`
   - `yamlEndSequence` -> `yamlEndSeq`
   - `yamlStartDocument` -> `yamlStartDoc`
   - `yamlEndDocument` -> `yamlEndDoc`
   - `yTagMap` -> `yTagMapping`
 * Introduced `PresentationOptions`:
   - Let user specify newline style
   - Merged old presentation options `indentationStep` and `presentationStyle`
     into it
 * Use YAML test suite from `yaml-dev-kit` to test parser.

Bugfixes:

 * Fixed various parser bugs discovered with YAML test suite:
   - Block scalar as root node no longer leads to a parser error
   - Fixed a bug that caused incorrect handling of comments after plain scalars
   - Fixed bugs with newline handling of block scalars
   - Fixed a bug related to block sequence indentation
   - Skip content in tag and anchor names and single-quoted scalars when
     scanning for possible implicit map key
   - Properly handle more indented lines in folded block scalars
   - Fixed a problem with handling ':' after whitespace
   - Fixed indentation handling after block scalar

### 0.2.0

Features:

 * Added DOM API
 * Output block scalars in presenter if scalar is long and block scalar output
   is feasible. Else, use multiple lines for long scalars in double quotes.

Bugfixes:

 * Improved parser (#1, #3, #5)
 * Made parser correctly handle block sequences that have the same indentation
   as their parent node (#2)
 * Fixed problems with outputting double quoted strings (#4)

### 0.1.0

 * Initial release
