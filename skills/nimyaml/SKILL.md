---
name: nimyaml
description: Use when loading, dumping, or serializing YAML or JSON with NimYAML in Nim. Covers annotations, YamlNode DOM for partial deserialization, custom types, Dumper presets, anchors, variant objects, and the event stream API. Use when choosing between load/loadAs/loadMultiDoc, embedding YamlNode fields in typed objects, writing constructObject/representObject, or configuring presentation options.
---

# NimYAML

## Overview

NimYAML is a pure Nim YAML 1.2 implementation with zero dependencies. It provides layered APIs from high-level `load`/`dump` down to raw event streams. Since JSON is a subset of YAML, NimYAML reads and writes JSON natively.

Requires Nim 2.0.0+. ORC recommended (required for DOM API; ARC alone cannot handle cycles).

## When to Use

- Loading YAML or JSON into Nim types
- Dumping Nim types to YAML or JSON
- Partially deserializing documents using `YamlNode` fields
- Custom serialization for domain types
- Controlling output style (block, flow, JSON)
- Working with anchors, aliases, and cyclic data

## High-Level API

```nim
import yaml

# Load
var config: MyConfig
load(yamlString, config)           # into existing var
let config = loadAs[MyConfig](str) # returns value
var docs: seq[MyConfig]
loadMultiDoc(str, docs)            # multiple `---`-separated documents

# Dump
let output = Dumper().dump(value)          # default style
let output = blockOnlyDumper().dump(value) # block style
let output = jsonDumper().dump(value)      # JSON output

# Dump to stream
var dumper = Dumper()
dumper.dump(value, outputStream)
```

## Annotations

All annotations are pragmas on object types or fields.

### Field Annotations

| Annotation | Effect |
|---|---|
| `{.defaultVal: value.}` | Use `value` when field is absent in input |
| `{.transient.}` | Field is never serialized; providing it in input is an error |
| `{.scalar: ScalarStyle.}` | Force scalar style (`ssAny`, `ssPlain`, `ssSingleQuoted`, `ssDoubleQuoted`, `ssLiteral`, `ssFolded`) |
| `{.collection: CollectionStyle.}` | Force collection style (`csAny`, `csBlock`, `csFlow`, `csPair`) |

### Type Annotations

| Annotation | Effect |
|---|---|
| `{.sparse.}` | All `Option[T]` fields default to `none(T)` when absent; `none` values omitted on dump |
| `{.ignore: ["key1", "key2"].}` | Ignore listed keys during loading. `{.ignore: [].}` ignores all unknown keys |
| `{.implicit.}` | Variant object where each case branch has exactly one field (or zero in one branch). Serialized as value directly instead of sequence-of-pairs |

### Examples

```nim
type
  Config = object
    host*: string
    port* {.defaultVal: 8080.}: int

  Metadata {.sparse.} = object
    title*: Option[string]
    description*: Option[string]

  Flexible {.ignore: [].} = object
    name*: string  # all other keys silently dropped

  ContainerKind = enum
    ckStr, ckInt
  Container {.implicit.} = object
    case kind: ContainerKind
    of ckStr: strVal: string
    of ckInt: intVal: int

  Styled = object
    code* {.scalar: ssLiteral.}: string
    tags* {.collection: csFlow.}: seq[string]
```

### Style Annotations on Types

Style pragmas can also annotate types. A field pragma overrides the type pragma:

```nim
type
  FlowObj {.collection: csFlow.} = object
    a* {.scalar: ssSingleQuoted.}: string
    b*: string

  Parent = object
    inline: FlowObj                         # uses csFlow from type
    expanded {.collection: csBlock.}: FlowObj # overridden to csBlock
```

## Optional Fields and the Optional Concept

NimYAML accepts any type satisfying the `Optional` concept:

```nim
type Optional* = concept o, type T
  isSome(o) is bool
  isNone(o) is bool
  isNone(default(T)) == true
  get(o)
```

Both `std/options.Option[T]` and custom optional types (e.g. `?T` from minlib) work simultaneously in the same object. Use `{.sparse.}` on the type to make all optional fields default to none.

## YamlNode: DOM and Partial Deserialization

`YamlNode` represents the YAML node graph. It works like `JsonNode` from stdlib.

### YamlNode Structure

```nim
type
  YamlNodeKind* = enum
    yScalar, yMapping, ySequence
  YamlNode* = ref YamlNodeObj
  YamlNodeObj* = object
    tag*: Tag
    case kind*: YamlNodeKind
    of yScalar:
      content*: string
      scalarStyle*: ScalarStyle
    of ySequence:
      elems*: seq[YamlNode]
      seqStyle*: CollectionStyle
    of yMapping:
      fields*: TableRef[YamlNode, YamlNode]
      mapStyle*: CollectionStyle
```

### Constructing YamlNode

```nim
let scalar = newYamlNode("hello")
let seq    = newYamlNode([newYamlNode("a"), newYamlNode("b")])
let map    = newYamlNode([(newYamlNode("key"), newYamlNode("val"))])
```

### Accessing YamlNode

```nim
node["key"]          # string key lookup in mapping
node[0]              # index into sequence
node.hasKey("key")   # check mapping key existence
node.len             # element count
for item in node: .. # iterate sequence
for k, v in node.pairs: .. # iterate mapping
```

### Embedding YamlNode in Typed Objects

Use `YamlNode` as a field type to capture a subtree without defining its structure. The typed fields are deserialized normally; the `YamlNode` field captures whatever YAML subtree appears at that position:

```nim
type Config = object
  name: string
  metadata: YamlNode  # arbitrary YAML subtree

let cfg = loadAs[Config]("""
name: myapp
metadata:
  version: 1
  tags: [web, api]
  nested:
    deep: true
""")

assert cfg.name == "myapp"
assert cfg.metadata.kind == yMapping
assert cfg.metadata["version"].content == "1"
assert cfg.metadata["tags"][0].content == "web"
```

This pattern is useful when:
- Part of the document has a known schema and part is freeform
- You want to pass subtrees through without defining types for them
- You need to preserve the original YAML structure including tags and styles

### Loading and Dumping YamlNode Directly

```nim
# Load entire document as DOM
let root = loadAs[YamlNode](yamlString)

# Dump YamlNode back to YAML
let output = Dumper().dump(root)
```

### loadFlattened: Resolving Aliases

`loadFlattened` resolves all aliases to copies, letting you load into types without `ref`:

```nim
# Input uses anchors as variables:
# defaults: &defaults
#   adapter: postgres
# production:
#   <<: *defaults
#   database: myapp_prod

var config: MyConfig
loadFlattened(input, config)
```

## JSON Support

YAML is a superset of JSON. NimYAML handles JSON natively.

### Reading JSON

```nim
# JSON is valid YAML — just use load/loadAs
let data = loadAs[MyType]("""{"name": "test", "count": 42}""")
```

### Writing JSON

```nim
let output = jsonDumper().dump(value)
# Produces: {"name": "test", "count": 42}
```

### Converting to stdlib JsonNode

```nim
import yaml/tojson

let nodes: seq[JsonNode] = loadToJson(yamlString)
# or from a stream:
let nodes = loadToJson(stream)
```

Type mapping: YAML scalars are auto-detected as `JInt`, `JFloat`, `JBool`, `JNull`, or `JString` using the YAML core schema.

## Dumper Configuration

### Presets

| Constructor | Style |
|---|---|
| `Dumper()` | Default: block style, flow for scalar-only collections |
| `blockOnlyDumper()` | Block style exclusively |
| `jsonDumper()` | JSON-compatible output |
| `minimalDumper()` | Single-line flow output |
| `explanatoryDumper()` | Explicit tags on all nodes, `!n!` shorthand |

Note: `CollectionStyle` (from `yaml/style`) controls per-field/type style pragmas. `ContainerStyle` (from `yaml/presenter`) controls global presentation. They are separate enums.

### PresentationOptions

```nim
type PresentationOptions = object
  containers: ContainerStyle       # cBlock, cFlow, cMixed (default: cMixed)
  indentationStep: int             # default: 2
  newlines: NewLineStyle           # nlLF, nlCRLF, nlOSDefault, nlNone
  outputVersion: OutputYamlVersion # ov1_2, ov1_1, ovNone (default: ovNone)
  maxLineLength: Option[int]       # default: some(80), none for unlimited
  directivesEnd: DirectivesEndStyle # deAlways, deIfNecessary, deNever
  suppressAttrs: bool              # suppress tags/anchors (default: false)
  quoting: ScalarQuotingStyle      # sqUnset, sqDouble, sqJson
  condenseFlow: bool               # single-line flow containers (default: true)
  explicitKeys: bool               # use '?' for keys (default: false)
```

### SerializationOptions

```nim
type SerializationOptions = object
  tagStyle: TagStyle       # tsNone, tsRootOnly, tsAll (default: tsNone)
  anchorStyle: AnchorStyle # asNone, asTidy, asAlways (default: asTidy)
  handles: seq[tuple[handle, uriPrefix: string]]
```

### Custom Dumper Example

```nim
var dumper = Dumper()
dumper.presentation.containers = cBlock
dumper.presentation.indentationStep = 4
dumper.serialization.tagStyle = tsRootOnly
dumper.serialization.handles = initNimYamlTagHandle()
let output = dumper.dump(value)
```

## Custom Type Serialization

### Custom Tags

```nim
setTag(MyType, Tag("!mytag"))
```

### Custom Construction (YAML to Nim)

```nim
proc constructObject*(
  ctx: var ConstructionContext,
  result: var MyType,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ctx.input.constructScalarItem(item, MyType):
    result = parseMyType(item.scalarContent)
```

### Custom Representation (Nim to YAML)

```nim
proc representObject*(
  ctx: var SerializationContext,
  value: MyType,
  tag: Tag,
) {.raises: [].} =
  ctx.put(scalarEvent($value, tag, yAnchorNone))
```

### Distinct Types Example

```nim
type UserId = distinct int
setTag(UserId, Tag("!userid"))

proc constructObject*(ctx: var ConstructionContext, result: var UserId,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ctx.input.constructScalarItem(item, UserId):
    result = UserId(parseInt(item.scalarContent))

proc representObject*(ctx: var SerializationContext, value: UserId, tag: Tag,
) {.raises: [].} =
  ctx.put(scalarEvent($int(value), tag, yAnchorNone))
```

## Supported Types

| Nim Type | YAML Representation |
|---|---|
| `string`, `char` | Scalar |
| `int8`..`int64`, `uint8`..`uint64` | Scalar (decimal, `0x` hex, `0o` octal) |
| `float32`, `float64` | Scalar (includes `.inf`, `-.inf`, `.nan`) |
| `bool` | Scalar (`true`/`false`, `yes`/`no`, `on`/`off`) |
| `enum` | Scalar (enum value name) |
| `Time` (std/times) | Scalar (YAML timestamp) |
| `Option[T]` | Value or `!!null ~` |
| `seq[T]` | Sequence |
| `array[I, T]` | Sequence (length checked) |
| `set[T]` | Sequence |
| `Table[K, V]` | Mapping |
| `OrderedTable[K, V]` | Sequence of single-pair mappings |
| `tuple` | Mapping (field names as keys) |
| `object` | Mapping (field names as keys) |
| Variant `object` | Sequence of single-pair mappings (or value with `{.implicit.}`) |
| `ref T` | Same as T, with anchor/alias support for shared references |
| `YamlNode` | Any YAML subtree (DOM node) |

## Anchors and Aliases

Ref objects are tracked automatically. `asTidy` (default) writes anchors only for multiply-referenced objects:

```nim
type Node = object
  value: string
  next: ref Node

# Cyclic structures are supported:
var a = new(Node); a.value = "a"
var b = new(Node); b.value = "b"
a.next = b; b.next = a

let output = blockOnlyDumper().dump(a)
# --- &a
# value: a
# next:
#   value: b
#   next: *a
```

## Event Stream API

For large documents or custom processing:

```nim
import yaml / [parser, presenter, stream, data]

var parser = initYamlParser()
var events: YamlStream = parser.parse(input)

for event in events:
  case event.kind
  of yamlStartMap: echo "map start"
  of yamlEndMap: echo "map end"
  of yamlStartSeq: echo "seq start"
  of yamlEndSeq: echo "seq end"
  of yamlScalar: echo "scalar: ", event.scalarContent
  of yamlAlias: echo "alias"
  of yamlStartDoc, yamlEndDoc: discard
  of yamlStartStream, yamlEndStream: discard
```

Manual event construction:

```nim
var bys = newBufferYamlStream()
bys.put(startStreamEvent())
bys.put(startDocEvent())
bys.put(scalarEvent("hello"))
bys.put(endDocEvent())
bys.put(endStreamEvent())
let output = present(bys, PresentationOptions())
```

## Error Handling

| Exception | When |
|---|---|
| `YamlParserError` | Invalid YAML syntax |
| `YamlConstructionError` | Cannot construct Nim value from YAML (wrong type, missing field, duplicate field, transient field in input) |
| `YamlSerializationError` | Cannot serialize Nim value (e.g. cyclic data with `asNone`) |
| `YamlPresenterJsonError` | Cannot produce JSON (non-scalar keys, NaN/Inf values) |
| `YamlPresenterOutputError` | Stream write failure |

All loading errors include `mark` (line/column) and `lineContent` for diagnostics.

## Build Commands

```
nim test              # all tests
nim build             # build library
nim testSerialization # serialization tests
nim testDumping       # dumping tests
nim testJson          # JSON tests
nim testAll           # comprehensive suite
nim docs              # generate documentation
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| Using ARC without ORC for `YamlNode` | Compile with `--gc:orc` or `--mm:orc` |
| Providing a `{.transient.}` field value in YAML input | Remove the key from input; transient fields cannot be set from YAML |
| Missing field error on optional fields | Add `{.sparse.}` to type or `{.defaultVal: none(T).}` to field |
| Unknown field error on extra keys | Add `{.ignore: ["key"].}` or `{.ignore: [].}` to type |
| Expecting `OrderedTable` from a YAML mapping | `OrderedTable` serializes as sequence of single-pair mappings, not a flat mapping |
| `YamlPresenterJsonError` on dump | JSON cannot represent non-scalar keys, NaN, or Inf. Use YAML output or sanitize values |
| Variant object missing discriminant in input | Variant objects serialize as sequence of field pairs; discriminant must come before branch fields |
