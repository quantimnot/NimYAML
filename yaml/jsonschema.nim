#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ======================
## Module yaml/jsonschema
## ======================
##
## Validates ``YamlNode`` graphs against `JSON Schema
## <https://json-schema.org/>`_, written in YAML or JSON.
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, jsonschema]
##
##   let schema = compile(loadAs[YamlNode]("""
##   type: object
##   required: [name]
##   properties:
##     name: {type: string, minLength: 1}
##     age: {type: integer, minimum: 0}
##   """))
##   let person = loadAs[YamlNode]("{name: Ada, age: -1}")
##   echo schema.isValid(person)            # false
##   for error in schema.validate(person).errors:
##     echo error.instanceLocation, ": ", error.error
##     # /age: -1 is less than the minimum of 0
##
## Supported are the dialects of draft 2020-12 (the default), 2019-09,
## draft-07, draft-06 and draft-04, with all their vocabularies: a schema
## chooses its dialect with ``$schema``, per schema resource, and schemas of
## different dialects can reference each other. Custom meta-schemas that
## declare ``$vocabulary`` are honoured, so that keywords of vocabularies
## they leave out are ignored. The implementation passes the `JSON Schema
## Test Suite <https://github.com/json-schema-org/JSON-Schema-Test-Suite>`_,
## including its optional tests, output tests and annotation tests.
##
## Schemas and references
## ----------------------
##
## ``compile`` turns a schema into a ``JsonSchema``, resolving every
## ``$ref`` up front, so that unresolvable references and malformed keywords
## raise ``JsonSchemaError`` there rather than during validation. References
## are resolved against a ``SchemaRegistry``, which knows the meta-schemas of
## all supported dialects (including JSON Hyper-Schema), schemas added to it
## with ``addSchema``, and whatever its ``SchemaLoader`` can retrieve. There
## is no default loader: NimYAML never accesses the network or the file
## system on its own.
##
## A registry can be lenient with some resources (``lenient`` of
## `newSchemaRegistry`): a keyword of theirs whose value is invalid, or whose
## reference cannot be resolved, is ignored instead of failing the
## compilation. This is for schemas assembled from contributions nobody
## checks, such as VS Code's settings schemas, which carry the mistakes of
## every installed extension (``"items": "string"``, draft-03's
## ``"required": true``) and which VS Code's own validator skips over.
##
## Each ``compile`` call has its own scope for the schema it compiles, so
## that compiling two schemas that both lack ``$id`` (or share one) does not
## make them collide in the registry.
##
## Validation and output
## ---------------------
##
## ``isValid`` answers yes or no as fast as it can. ``validate`` evaluates
## the whole schema and keeps the results in a ``ValidationResult``:
## ``errors`` and ``annotations`` give the flat lists of the *basic* output
## format, ``toYaml`` renders any of the four output formats of JSON Schema
## 2020-12 (flag, basic, detailed and verbose) as a ``YamlNode``, and
## ``outputTree`` exposes the full tree for further processing (it is what
## JSON Hyper-Schema builds on).
##
## Format and content
## ------------------
##
## ``format`` is an annotation unless ``formatAssertion`` is enabled in the
## ``ValidationOptions`` or the dialect includes the 2020-12
## format-assertion vocabulary. All formats of the specification are known:
## dates and times (RFC 3339), e-mail addresses (RFC 5321/6531), host names
## (RFC 1123, and IDNA2008 with UTS 46 processing for ``idn-hostname``),
## IP addresses, URIs and IRIs, UUIDs, URI Templates, JSON Pointers and
## ECMA-262 regular expressions. Unknown formats always pass.
##
## Similarly, ``contentEncoding`` (``base64``) and ``contentMediaType``
## (``application/json``) are only checked with ``contentAssertion``.
##
## Regular expressions
## -------------------
##
## ``pattern`` and ``patternProperties`` are ECMA-262 regular expressions in
## Unicode mode, matched by NimYAML's own engine. It supports everything but
## Unicode properties other than General Categories (``\p{Script=..}`` is
## rejected) and gives up with ``JsonSchemaError`` on patterns that would
## backtrack excessively.
##
## YAML is not JSON
## ----------------
##
## Instances (and schemas) are read as JSON the way ``yaml/jsonpath`` reads
## them: scalar types follow tags, with plain scalars resolved by the YAML
## 1.2 core schema; only string keys are object members, so a member with
## the key ``1`` or ``[a]`` is invisible to every keyword, including
## ``additionalProperties``; aliases are followed. Numbers are compared
## exactly as the decimals they are written as, so ``0.0075`` is a multiple
## of ``0.0001`` and integers of any size work. YAML's ``.inf`` and ``.nan``
## are numbers that are not integers.

import std/[base64, json, sets, strutils, tables, unicode]
import dom, data, loading, fragment,
    private/[jsonmodel, decimal, uri, ecmaregex, formats]

when defined(nimPreviewSlimSystem):
  import std/[assertions, formatfloat]

type
  JsonSchemaError* = object of ValueError
    ## Raised for invalid schemas, unresolvable references and patterns too
    ## complex to evaluate.

  Draft* = enum
    ## The supported JSON Schema dialects.
    draft4 = "draft-04"
    draft6 = "draft-06"
    draft7 = "draft-07"
    draft2019 = "2019-09"
    draft2020 = "2020-12"

  SchemaLoader* = proc(uri: string): YamlNode {.closure,
      raises: [CatchableError].}
    ## Retrieves the schema document identified by ``uri`` (an absolute URI
    ## without fragment), or returns ``nil`` if it does not know it.

  LenientPredicate* = proc(uri: string): bool {.closure, raises: [].}
    ## Whether the schema resource ``uri`` (without fragment) is compiled
    ## leniently.

  ValidationOptions* = object
    formatAssertion*: bool
      ## Validate ``format`` instead of only annotating it.
    contentAssertion*: bool
      ## Validate ``contentEncoding`` and ``contentMediaType``.

  OutputFormat* = enum
    ## The output formats of JSON Schema 2020-12, Section 12.4.
    ofFlag, ofBasic, ofDetailed, ofVerbose

  OutputUnitKind* = enum
    oukSchema   ## the evaluation of a (sub)schema
    oukKeyword  ## the evaluation of one keyword of a schema

  OutputUnit* = ref object
    ## A node of the output tree: an evaluated schema, whose children are
    ## its keywords, or an evaluated keyword, whose children are the
    ## subschemas it applied.
    kind*: OutputUnitKind
    valid*: bool
    keyword*: string  ## the keyword, for ``oukKeyword``
    keywordLocation*: string
      ## JSON Pointer along the evaluation path, through references
    absoluteKeywordLocation*: string
      ## URI of the schema or keyword, references resolved
    schemaLocation*: string
      ## URI of the schema the keyword belongs to (for ``oukKeyword``)
    documentPointer*: string
      ## JSON Pointer of that schema within the document it is part of
    instanceLocation*: string ## JSON Pointer into the instance
    error*: string ## for failed assertions; empty otherwise
    annotation*: YamlNode ## the annotation a keyword produced, or ``nil``
    children*: seq[OutputUnit]

  ValidationResult* = object
    valid*: bool
    tree: OutputUnit

  Annotation* = object
    ## An annotation from a successfully evaluated keyword.
    instanceLocation*: string ## where in the instance it applies
    keyword*: string
    schemaLocation*: string   ## absolute URI of the schema of the keyword
    documentPointer*: string
      ## JSON Pointer of the schema of the keyword within its document
    keywordLocation*: string  ## evaluation path of the keyword
    value*: YamlNode

  Vocabulary = enum
    vocCore, vocApplicator, vocUnevaluated, vocValidation, vocMetaData,
    vocFormatAnnotation, vocFormatAssertion, vocContent, vocHyperSchema

  Dialect = object
    draft: Draft
    vocabularies: set[Vocabulary]

  Resource = ref object
    uri: string
    node: YamlNode
    dialect: Dialect
    anchors: Table[string, YamlNode]
    dynamicAnchors: HashSet[string]
    recursiveAnchor: bool
    docPointer: string ## of ``node`` within its document

  NodeInfo = object
    resource: Resource
    pointer: string    ## within ``resource``
    docPointer: string ## within the document the node was loaded from

  Store = ref object
    ## Resources, discovered nodes and compiled schemas. A registry has one;
    ## each compiled schema has one on top of its registry's.
    parent: Store
    resources: Table[string, Resource]
    nodes: Table[pointer, NodeInfo]
    compiled: Table[pointer, Schema]
    documents: seq[YamlNode] ## keeps discovered nodes alive

  SchemaRegistry* = ref object
    ## Knows schema resources by URI; see the module documentation.
    store: Store
    loader: SchemaLoader
    defaultDraft: Draft
    lenient: LenientPredicate

  JsonType = enum
    jtNull = "null", jtBoolean = "boolean", jtObject = "object",
    jtArray = "array", jtNumber = "number", jtString = "string",
    jtInteger = "integer"

  KeywordKind = enum
    # in evaluation order: unevaluated* must come last, and keywords that
    # depend on others (then, else, additional*, min/maxContains) are
    # evaluated by the keyword they depend on
    kRef, kDynamicRef, kRecursiveRef,
    kType, kEnum, kConst, kMultipleOf, kMaximum, kExclusiveMaximum,
    kMinimum, kExclusiveMinimum, kMaxLength, kMinLength, kPattern,
    kMaxItems, kMinItems, kUniqueItems, kMaxProperties, kMinProperties,
    kRequired, kDependentRequired, kFormat, kContentEncoding,
    kContentMediaType, kContentSchema,
    kAllOf, kAnyOf, kOneOf, kNot, kIf, kDependentSchemas, kDependencies,
    kPrefixItems, kItems, kAdditionalItems, kContains,
    kProperties, kPatternProperties, kAdditionalProperties, kPropertyNames,
    kAnnotation, kUnknown,
    kUnevaluatedItems, kUnevaluatedProperties

  Num = object
    case finite: bool
    of true: dec: Decimal
    of false: f: float64

  Schema = ref object
    node: YamlNode
    location: string ## absolute URI, ``resource#pointer``
    pointer: string  ## the JSON Pointer within ``resource``
    docPointer: string ## the JSON Pointer within the document
    resource: Resource
    dialect: Dialect
    isBool, boolValue: bool
    keywords: seq[Keyword]
    hasUnevaluated: bool

  PatternSchema = tuple[regex: EcmaRegex, source: string, schema: Schema]

  Keyword = ref object
    kind: KeywordKind
    name: string
    value: YamlNode
    schema: Schema       ## single subschema; target of references
    schemas: seq[Schema] ## subschema arrays
    named: seq[tuple[name: string, schema: Schema]]
    patterns: seq[PatternSchema]
    names: seq[string]
    dependents: seq[tuple[name: string, required: seq[string]]]
    num: Num
    count: int
    flag: bool           ## uniqueItems; draft-04 exclusive bounds
    types: set[JsonType]
    regex: EcmaRegex
    dynamicName: string  ## $dynamicRef: anchor to look up dynamically
    recursive: bool      ## $recursiveRef: target has $recursiveAnchor
    thenSchema, elseSchema: Schema
    minContains, maxContains: int ## -1 if absent
    sibling: Keyword     ## additionalItems/Properties: their sources

  JsonSchema* = object
    ## A compiled schema.
    registry: SchemaRegistry
    store: Store
    root: Schema

const
  metaSchemas = [
    ("http://json-schema.org/draft-04/schema", staticRead("private/metaschemas/draft-04.json")),
    ("http://json-schema.org/draft-06/schema", staticRead("private/metaschemas/draft-06.json")),
    ("http://json-schema.org/draft-07/schema", staticRead("private/metaschemas/draft-07.json")),
    ("http://json-schema.org/draft-07/hyper-schema", staticRead("private/metaschemas/draft-07-hyper-schema.json")),
    ("http://json-schema.org/draft-07/links", staticRead("private/metaschemas/draft-07-links.json")),
    ("https://json-schema.org/draft/2019-09/schema", staticRead("private/metaschemas/2019-09-schema.json")),
    ("https://json-schema.org/draft/2019-09/hyper-schema", staticRead("private/metaschemas/2019-09-hyper-schema.json")),
    ("https://json-schema.org/draft/2019-09/links", staticRead("private/metaschemas/2019-09-links.json")),
    ("https://json-schema.org/draft/2019-09/meta/core", staticRead("private/metaschemas/2019-09-meta-core.json")),
    ("https://json-schema.org/draft/2019-09/meta/applicator", staticRead("private/metaschemas/2019-09-meta-applicator.json")),
    ("https://json-schema.org/draft/2019-09/meta/validation", staticRead("private/metaschemas/2019-09-meta-validation.json")),
    ("https://json-schema.org/draft/2019-09/meta/meta-data", staticRead("private/metaschemas/2019-09-meta-meta-data.json")),
    ("https://json-schema.org/draft/2019-09/meta/format", staticRead("private/metaschemas/2019-09-meta-format.json")),
    ("https://json-schema.org/draft/2019-09/meta/content", staticRead("private/metaschemas/2019-09-meta-content.json")),
    ("https://json-schema.org/draft/2019-09/meta/hyper-schema", staticRead("private/metaschemas/2019-09-meta-hyper-schema.json")),
    ("https://json-schema.org/draft/2020-12/schema", staticRead("private/metaschemas/2020-12-schema.json")),
    ("https://json-schema.org/draft/2020-12/hyper-schema", staticRead("private/metaschemas/2020-12-hyper-schema.json")),
    ("https://json-schema.org/draft/2020-12/links", staticRead("private/metaschemas/2020-12-links.json")),
    ("https://json-schema.org/draft/2020-12/meta/core", staticRead("private/metaschemas/2020-12-meta-core.json")),
    ("https://json-schema.org/draft/2020-12/meta/applicator", staticRead("private/metaschemas/2020-12-meta-applicator.json")),
    ("https://json-schema.org/draft/2020-12/meta/unevaluated", staticRead("private/metaschemas/2020-12-meta-unevaluated.json")),
    ("https://json-schema.org/draft/2020-12/meta/validation", staticRead("private/metaschemas/2020-12-meta-validation.json")),
    ("https://json-schema.org/draft/2020-12/meta/meta-data", staticRead("private/metaschemas/2020-12-meta-meta-data.json")),
    ("https://json-schema.org/draft/2020-12/meta/format-annotation", staticRead("private/metaschemas/2020-12-meta-format-annotation.json")),
    ("https://json-schema.org/draft/2020-12/meta/format-assertion", staticRead("private/metaschemas/2020-12-meta-format-assertion.json")),
    ("https://json-schema.org/draft/2020-12/meta/content", staticRead("private/metaschemas/2020-12-meta-content.json")),
    ("https://json-schema.org/draft/2020-12/meta/hyper-schema", staticRead("private/metaschemas/2020-12-meta-hyper-schema.json"))]

  dialectUris = [
    ("http://json-schema.org/draft-04/schema", draft4, false),
    ("http://json-schema.org/draft-06/schema", draft6, false),
    ("http://json-schema.org/draft-07/schema", draft7, false),
    ("http://json-schema.org/draft-07/hyper-schema", draft7, true),
    ("https://json-schema.org/draft/2019-09/schema", draft2019, false),
    ("https://json-schema.org/draft/2019-09/hyper-schema", draft2019, true),
    ("https://json-schema.org/draft/2020-12/schema", draft2020, false),
    ("https://json-schema.org/draft/2020-12/hyper-schema", draft2020, true)]

  vocabularyUris = [
    ("https://json-schema.org/draft/2019-09/vocab/core", {vocCore}),
    ("https://json-schema.org/draft/2019-09/vocab/applicator",
        {vocApplicator, vocUnevaluated}),
    ("https://json-schema.org/draft/2019-09/vocab/validation", {vocValidation}),
    ("https://json-schema.org/draft/2019-09/vocab/meta-data", {vocMetaData}),
    ("https://json-schema.org/draft/2019-09/vocab/format", {vocFormatAnnotation}),
    ("https://json-schema.org/draft/2019-09/vocab/content", {vocContent}),
    ("https://json-schema.org/draft/2019-09/vocab/hyper-schema", {vocHyperSchema}),
    ("https://json-schema.org/draft/2020-12/vocab/core", {vocCore}),
    ("https://json-schema.org/draft/2020-12/vocab/applicator", {vocApplicator}),
    ("https://json-schema.org/draft/2020-12/vocab/unevaluated", {vocUnevaluated}),
    ("https://json-schema.org/draft/2020-12/vocab/validation", {vocValidation}),
    ("https://json-schema.org/draft/2020-12/vocab/meta-data", {vocMetaData}),
    ("https://json-schema.org/draft/2020-12/vocab/format-annotation",
        {vocFormatAnnotation}),
    ("https://json-schema.org/draft/2020-12/vocab/format-assertion",
        {vocFormatAssertion}),
    ("https://json-schema.org/draft/2020-12/vocab/content", {vocContent})]

  standardVocabularies = {vocCore, vocApplicator, vocUnevaluated,
      vocValidation, vocMetaData, vocFormatAnnotation, vocContent}

  maxDepth = 1000

proc schemaError(msg: string): ref JsonSchemaError =
  newException(JsonSchemaError, msg)

proc defaultDialect(draft: Draft, hyper = false): Dialect =
  result = Dialect(draft: draft, vocabularies: standardVocabularies)
  if hyper: result.vocabularies.incl(vocHyperSchema)

proc escapeToken(token: string): string =
  token.multiReplace(("~", "~0"), ("/", "~1"))

proc `/`(pointer, token: string): string = pointer & "/" & escapeToken(token)
proc `/`(pointer: string, index: int): string = pointer & "/" & $index

proc encodeFragment(pointer: string): string =
  ## Percent-encodes a JSON Pointer for use as URI fragment (RFC 6901,
  ## Section 6).
  const allowed = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '!', '$',
      '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?'}
  for c in pointer:
    if c in allowed: result.add(c)
    else: result.add('%' & toHex(ord(c), 2))

proc normalizeUri(uri: string): string =
  ## Drops an empty fragment: ``http://x/s#`` and ``http://x/s`` are the
  ## same resource.
  if uri.endsWith("#"): uri[0 ..< ^1] else: uri

proc stringValue(node: YamlNode, value: var string): bool =
  if node.isNil or node.kind != yScalar or node.jsonKind != jkString:
    return false
  value = node.content
  result = true

proc newString(s: string): YamlNode = newYamlNode(s, yTagString)
proc newKey(s: string): YamlNode = newYamlNode(s) ## plain, for output keys
proc newBool(b: bool): YamlNode =
  newYamlNode(if b: "true" else: "false", yTagBoolean)

# ----------------------------------------------------------------------------
# Numbers and equality
# ----------------------------------------------------------------------------

proc numberOf(node: YamlNode): Num =
  ## The value of a node whose JSON type is number.
  var d: Decimal
  if parseDecimal(node.content, d): return Num(finite: true, dec: d)
  let n = node.jsonScalar.number
  if n.isInteger: return Num(finite: true, dec: toDecimal(n.integer))
  let f = n.float
  if f == f and f != Inf and f != NegInf and parseDecimal($f, d):
    return Num(finite: true, dec: d)
  result = Num(finite: false, f: f)

proc toFloat(n: Num): float64 =
  if n.finite: n.dec.toFloat else: n.f

proc `<`(a, b: Num): bool =
  if a.finite and b.finite: a.dec < b.dec else: a.toFloat < b.toFloat

proc `<=`(a, b: Num): bool =
  if a.finite and b.finite: a.dec <= b.dec else: a.toFloat <= b.toFloat

proc `==`(a, b: Num): bool =
  if a.finite and b.finite: a.dec == b.dec else: a.toFloat == b.toFloat

proc `$`(n: Num): string =
  if n.finite: $n.dec
  elif n.f != n.f: "NaN"
  elif n.f > 0: "Infinity"
  else: "-Infinity"

proc isInteger(n: Num): bool = n.finite and n.dec.isInteger

proc isMultipleOf(a, b: Num): bool =
  if not a.finite or not b.finite: return false
  var multiple: bool
  if isMultipleOf(a.dec, b.dec, multiple): return multiple
  let q = a.dec.toFloat / b.dec.toFloat
  result = q == float64(int64(q))

proc instanceEquals(a, b: YamlNode,
    assumed: var HashSet[(pointer, pointer)]): bool =
  ## JSON equality with exact numbers.
  if cast[pointer](a) == cast[pointer](b): return true
  let (ka, kb) = (a.jsonKind, b.jsonKind)
  if ka != kb: return false
  case ka
  of jkNull: true
  of jkBool: a.jsonScalar.boolean == b.jsonScalar.boolean
  of jkNumber: numberOf(a) == numberOf(b)
  of jkString: a.content == b.content
  of jkArray:
    if a.elems.len != b.elems.len: return false
    if assumed.containsOrIncl((cast[pointer](a), cast[pointer](b))): return true
    for i in 0 ..< a.elems.len:
      if not instanceEquals(a.elems[i], b.elems[i], assumed): return false
    true
  of jkObject:
    if assumed.containsOrIncl((cast[pointer](a), cast[pointer](b))): return true
    var count = 0
    for name, value in a.members:
      inc(count)
      let other = b.member(name)
      if other.isNil or not instanceEquals(value, other, assumed): return false
    for _ in b.members: dec(count)
    count == 0

proc instanceEquals(a, b: YamlNode): bool =
  var assumed = initHashSet[(pointer, pointer)]()
  result = instanceEquals(a, b, assumed)

proc jsonTypeOf(node: YamlNode): JsonType =
  case node.jsonKind
  of jkNull: jtNull
  of jkBool: jtBoolean
  of jkNumber: jtNumber
  of jkString: jtString
  of jkArray: jtArray
  of jkObject: jtObject

proc describe(node: YamlNode): string =
  ## A short rendering of an instance value for error messages.
  case node.jsonKind
  of jkString:
    result = escape(if node.content.runeLen > 40:
        node.content.runeSubStr(0, 40) & "..." else: node.content)
  of jkNumber: result = $numberOf(node)
  of jkNull: result = "null"
  of jkBool: result = $node.jsonScalar.boolean
  of jkArray: result = "array"
  of jkObject: result = "object"

# ----------------------------------------------------------------------------
# Registry and resource discovery
# ----------------------------------------------------------------------------

proc newStore(parent: Store = nil): Store =
  Store(parent: parent, resources: initTable[string, Resource](),
      nodes: initTable[pointer, NodeInfo](),
      compiled: initTable[pointer, Schema]())

proc locationOf(resource: Resource, pointer: string): string =
  resource.uri & "#" & encodeFragment(pointer)

proc keywordLocation(s: Schema, keyword: string): string =
  ## The absolute location of ``keyword`` in ``s``.
  s.resource.locationOf(s.pointer / keyword)

proc newSchemaRegistry*(loader: SchemaLoader = nil,
    defaultDraft = draft2020, lenient: LenientPredicate = nil):
    SchemaRegistry =
  ## Creates a registry. ``loader`` is asked for schema resources the
  ## registry does not know; ``defaultDraft`` is the dialect of schemas that
  ## do not declare one with ``$schema``; the resources ``lenient`` accepts
  ## have their invalid keywords ignored (see the module documentation).
  SchemaRegistry(store: newStore(), loader: loader, defaultDraft: defaultDraft,
      lenient: lenient)

proc findLocal(store: Store, uri: string): Resource =
  var s = store
  while not s.isNil:
    result = s.resources.getOrDefault(uri)
    if not result.isNil: return
    s = s.parent
  result = nil

proc infoOf(store: Store, node: YamlNode, info: var NodeInfo): bool =
  var s = store
  while not s.isNil:
    if s.nodes.hasKey(cast[pointer](node)):
      info = s.nodes.getOrDefault(cast[pointer](node))
      return true
    s = s.parent
  result = false

type Discovery = object
  registry: SchemaRegistry
  store: Store ## where new resources go
  scope: Store ## where lookups start

proc findResource(d: Discovery, uri: string): Resource
    {.raises: [JsonSchemaError].}

proc dialectOf(d: Discovery, schemaUri: string): Dialect
    {.raises: [JsonSchemaError].} =
  ## The dialect a ``$schema`` value selects.
  let uri = normalizeUri(schemaUri)
  for (known, draft, hyper) in dialectUris:
    if uri == known or uri == known.replace("http://", "https://") or
        uri == known.replace("https://", "http://"):
      return defaultDialect(draft, hyper)
  # a custom meta-schema: its own dialect, restricted by its $vocabulary
  let meta = d.findResource(uri)
  result = meta.dialect
  if meta.dialect.draft >= draft2019 and meta.node.kind == yMapping:
    let vocab = meta.node.member("$vocabulary")
    if not vocab.isNil and vocab.kind == yMapping:
      result.vocabularies = {}
      for name, required in vocab.members:
        var found = false
        for (known, vocabularies) in vocabularyUris:
          if known == name:
            result.vocabularies.incl(vocabularies)
            found = true
        if not found and required.jsonKind == jkBool and
            required.jsonScalar.boolean:
          raise schemaError("meta-schema " & uri &
              " requires unsupported vocabulary " & name)

proc subschemaKeywords(dialect: Dialect): tuple[single, list, map: seq[string]] =
  ## The keywords whose values contain subschemas, for resource discovery.
  result.single = @["not", "additionalProperties"]
  result.list = @["allOf", "anyOf", "oneOf"]
  result.map = @["properties", "patternProperties", "definitions",
      "dependencies"]
  if dialect.draft <= draft2019: result.single.add("additionalItems")
  if dialect.draft >= draft6: result.single.add(["contains", "propertyNames"])
  if dialect.draft >= draft7: result.single.add(["if", "then", "else"])
  if dialect.draft >= draft2019:
    result.single.add(["unevaluatedItems", "unevaluatedProperties",
        "contentSchema"])
    result.map.add(["$defs", "dependentSchemas"])
  if dialect.draft >= draft2020:
    result.list.add("prefixItems")

proc discover(d: Discovery, node: YamlNode, resource: Resource,
    pointer, docPointer: string, dialect: Dialect, isRoot: bool)
    {.raises: [JsonSchemaError].} =
  if d.store.nodes.hasKey(cast[pointer](node)): return
  var
    resource = resource
    pointer = pointer
    dialect = dialect
  if node.kind != yMapping:
    d.store.nodes[cast[pointer](node)] = NodeInfo(resource: resource,
        pointer: pointer, docPointer: docPointer)
    return
  let
    idKey = if dialect.draft == draft4: "id" else: "$id"
    idNode = node.member(idKey)
    refNode = node.member("$ref")
  var id: string
  let hasId = idNode.stringValue(id) and
      not (dialect.draft <= draft7 and not refNode.isNil)
  # $schema applies to resource roots
  var schemaUri: string
  if (isRoot or hasId) and node.member("$schema").stringValue(schemaUri):
    dialect = d.dialectOf(schemaUri)
    if isRoot: resource.dialect = dialect
  if hasId:
    let resolved = resolve(resource.uri, id)
    if dialect.draft <= draft7 and id.startsWith("#"):
      # a plain-name fragment: a location-independent identifier
      resource.anchors[fragment(resolved)] = node
    elif not isRoot or resolved.withoutFragment != resource.uri:
      let uri = resolved.withoutFragment
      resource = Resource(uri: uri, node: node, dialect: dialect,
          anchors: initTable[string, YamlNode](),
          dynamicAnchors: initHashSet[string](), docPointer: docPointer)
      if not d.store.resources.hasKey(uri): d.store.resources[uri] = resource
      pointer = ""
      let frag = fragment(resolved)
      if frag.len > 0 and dialect.draft <= draft7:
        resource.anchors[frag] = node
    else:
      resource.dialect = dialect
  if dialect.draft >= draft2019:
    var name: string
    if node.member("$anchor").stringValue(name): resource.anchors[name] = node
    if dialect.draft >= draft2020 and
        node.member("$dynamicAnchor").stringValue(name):
      resource.anchors[name] = node
      resource.dynamicAnchors.incl(name)
    let recursive = node.member("$recursiveAnchor")
    if dialect.draft == draft2019 and not recursive.isNil and
        recursive.jsonKind == jkBool and recursive.jsonScalar.boolean and
        resource.node == node:
      resource.recursiveAnchor = true
  d.store.nodes[cast[pointer](node)] = NodeInfo(resource: resource,
      pointer: pointer, docPointer: docPointer)

  template sub(child: YamlNode, suffix: string) =
    if child.kind == yMapping or child.jsonKind == jkBool:
      d.discover(child, resource, pointer & suffix, docPointer & suffix,
          dialect, false)

  let keywords = subschemaKeywords(dialect)
  for name in keywords.single:
    let child = node.member(name)
    if not child.isNil: sub(child, "" / name)
  for name in keywords.list:
    let child = node.member(name)
    if not child.isNil and child.kind == ySequence:
      for i, item in child.elems: sub(item, "" / name / i)
  for name in keywords.map:
    let child = node.member(name)
    if not child.isNil and child.kind == yMapping:
      for key, value in child.members: sub(value, "" / name / key)
  let items = node.member("items")
  if not items.isNil:
    if items.kind == ySequence and dialect.draft <= draft2019:
      for i, item in items.elems: sub(item, "" / "items" / i)
    else: sub(items, "" / "items")
  # JSON Hyper-Schema's Link Description Objects contain schemas, which
  # yaml/hyperschema compiles with ``subschema``. They are discovered in
  # every dialect, so that links work in schemas without a hyper-schema
  # ``$schema``, too.
  let links = node.member("links")
  if not links.isNil and links.kind == ySequence:
    for i, link in links.elems:
      if link.kind == yMapping:
        for name in ["hrefSchema", "targetSchema", "headerSchema",
            "submissionSchema"]:
          let child = link.member(name)
          if not child.isNil: sub(child, "" / "links" / i / name)

proc addDocument(d: Discovery, node: YamlNode, uri: string,
    defaultDraft: Draft): Resource {.raises: [JsonSchemaError].} =
  ## Discovers the resources of a schema document retrieved from ``uri``.
  result = Resource(uri: normalizeUri(uri), node: node,
      dialect: defaultDialect(defaultDraft),
      anchors: initTable[string, YamlNode](),
      dynamicAnchors: initHashSet[string]())
  d.store.documents.add(node)
  if not d.store.resources.hasKey(result.uri):
    d.store.resources[result.uri] = result
  d.discover(node, result, "", "", result.dialect, true)
  # the root may have identified itself with $id; that resource is the one
  # the document's own references resolve against
  var info: NodeInfo
  if d.store.infoOf(node, info): result = info.resource

proc findResource(d: Discovery, uri: string): Resource =
  result = d.scope.findLocal(uri)
  if not result.isNil: return
  let rootDiscovery = Discovery(registry: d.registry,
      store: d.registry.store, scope: d.scope)
  for (known, source) in metaSchemas:
    if known == uri:
      var node: YamlNode
      try: node = loadAs[YamlNode](source)
      except CatchableError as e:
        raise schemaError("cannot load meta-schema " & uri & ": " & e.msg)
      discard rootDiscovery.addDocument(node, uri, draft2020)
      return d.scope.findLocal(uri)
  if not d.registry.loader.isNil:
    var node: YamlNode
    try: node = d.registry.loader(uri)
    except CatchableError as e:
      raise schemaError("cannot retrieve " & uri & ": " & e.msg)
    if not node.isNil:
      discard rootDiscovery.addDocument(node, uri, d.registry.defaultDraft)
      result = d.scope.findLocal(uri)
      if not result.isNil: return
  raise schemaError("unknown schema resource " & escape(uri))

proc addSchema*(registry: SchemaRegistry, schema: YamlNode, uri = "")
    {.raises: [JsonSchemaError].} =
  ## Adds a schema document to the registry, so that references to it (by
  ## ``uri``, its retrieval URI, or by the ``$id`` of any resource in it)
  ## can be resolved.
  let d = Discovery(registry: registry, store: registry.store,
      scope: registry.store)
  discard d.addDocument(schema, uri, registry.defaultDraft)

# ----------------------------------------------------------------------------
# Compiling
# ----------------------------------------------------------------------------

type Compiler = object
  discovery: Discovery

proc compileSchema(c: Compiler, node: YamlNode): Schema
    {.raises: [JsonSchemaError].}

proc keywordKind(name: string, dialect: Dialect): KeywordKind =
  ## The kind of keyword ``name`` in ``dialect``, or ``kUnknown``.
  let
    draft = dialect.draft
    v = dialect.vocabularies
  template given(vocab: Vocabulary, minDraft: Draft, kind: KeywordKind,
      maxDraft = draft2020): KeywordKind =
    if vocab in v and draft >= minDraft and draft <= maxDraft: kind
    else: kUnknown
  case name
  of "$ref": kRef
  of "$dynamicRef": (if draft >= draft2020: kDynamicRef else: kUnknown)
  of "$recursiveRef": (if draft == draft2019: kRecursiveRef else: kUnknown)
  of "type": given(vocValidation, draft4, kType)
  of "enum": given(vocValidation, draft4, kEnum)
  of "const": given(vocValidation, draft6, kConst)
  of "multipleOf": given(vocValidation, draft4, kMultipleOf)
  of "maximum": given(vocValidation, draft4, kMaximum)
  of "exclusiveMaximum": given(vocValidation, draft4, kExclusiveMaximum)
  of "minimum": given(vocValidation, draft4, kMinimum)
  of "exclusiveMinimum": given(vocValidation, draft4, kExclusiveMinimum)
  of "maxLength": given(vocValidation, draft4, kMaxLength)
  of "minLength": given(vocValidation, draft4, kMinLength)
  of "pattern": given(vocValidation, draft4, kPattern)
  of "maxItems": given(vocValidation, draft4, kMaxItems)
  of "minItems": given(vocValidation, draft4, kMinItems)
  of "uniqueItems": given(vocValidation, draft4, kUniqueItems)
  of "maxProperties": given(vocValidation, draft4, kMaxProperties)
  of "minProperties": given(vocValidation, draft4, kMinProperties)
  of "required": given(vocValidation, draft4, kRequired)
  of "dependentRequired": given(vocValidation, draft2019, kDependentRequired)
  of "format":
    if vocFormatAnnotation in v or vocFormatAssertion in v or
        draft <= draft7: kFormat
    else: kUnknown
  of "contentEncoding": given(vocContent, draft7, kContentEncoding)
  of "contentMediaType": given(vocContent, draft7, kContentMediaType)
  of "contentSchema": given(vocContent, draft2019, kContentSchema)
  of "allOf": given(vocApplicator, draft4, kAllOf)
  of "anyOf": given(vocApplicator, draft4, kAnyOf)
  of "oneOf": given(vocApplicator, draft4, kOneOf)
  of "not": given(vocApplicator, draft4, kNot)
  of "if": given(vocApplicator, draft7, kIf)
  of "dependentSchemas": given(vocApplicator, draft2019, kDependentSchemas)
  of "dependencies": given(vocApplicator, draft4, kDependencies)
  of "prefixItems": given(vocApplicator, draft2020, kPrefixItems)
  of "items": given(vocApplicator, draft4, kItems)
  of "additionalItems":
    given(vocApplicator, draft4, kAdditionalItems, draft2019)
  of "contains": given(vocApplicator, draft6, kContains)
  of "properties": given(vocApplicator, draft4, kProperties)
  of "patternProperties": given(vocApplicator, draft4, kPatternProperties)
  of "additionalProperties":
    given(vocApplicator, draft4, kAdditionalProperties)
  of "propertyNames": given(vocApplicator, draft6, kPropertyNames)
  of "unevaluatedItems": given(vocUnevaluated, draft2019, kUnevaluatedItems)
  of "unevaluatedProperties":
    given(vocUnevaluated, draft2019, kUnevaluatedProperties)
  of "title", "description", "default":
    given(vocMetaData, draft4, kAnnotation)
  of "examples": given(vocMetaData, draft6, kAnnotation)
  of "readOnly", "writeOnly": given(vocMetaData, draft7, kAnnotation)
  of "deprecated": given(vocMetaData, draft2019, kAnnotation)
  of "base", "links": given(vocHyperSchema, draft4, kAnnotation)
  of "then", "else", "minContains", "maxContains", "$schema", "$id", "id",
     "$anchor", "$dynamicAnchor", "$recursiveAnchor", "$vocabulary",
     "$comment", "$defs", "definitions":
    kUnknown # evaluated with another keyword, or no effect on evaluation
  else: kUnknown

proc isCoreName(name: string, dialect: Dialect): bool =
  ## Keywords that are neither evaluated nor annotations.
  name in ["then", "else", "minContains", "maxContains", "$schema", "$id",
      "$anchor", "$dynamicAnchor", "$recursiveAnchor", "$vocabulary",
      "$comment", "$defs", "definitions"] or
      (dialect.draft == draft4 and name == "id")

proc fail(s: Schema, keyword, msg: string) {.noreturn.} =
  raise schemaError("invalid schema at " & s.location & "/" &
      escapeToken(keyword) & ": " & msg)

proc nonNegative(s: Schema, name: string, node: YamlNode): int =
  if node.jsonKind != jkNumber: s.fail(name, "expected a non-negative integer")
  let n = numberOf(node)
  if not n.isInteger or n.dec.negative:
    s.fail(name, "expected a non-negative integer")
  if n.dec.exponent + n.dec.coefficient.len > 18: return high(int)
  try: result = parseInt($n.dec)
  except ValueError: result = high(int)

proc numberValue(s: Schema, name: string, node: YamlNode): Num =
  if node.jsonKind != jkNumber: s.fail(name, "expected a number")
  result = numberOf(node)

proc stringList(s: Schema, name: string, node: YamlNode): seq[string] =
  if node.kind != ySequence: s.fail(name, "expected an array of strings")
  for item in node.elems:
    var value: string
    if not item.stringValue(value): s.fail(name, "expected an array of strings")
    result.add(value)

proc compileRegex(s: Schema, name, pattern: string): EcmaRegex =
  try: result = compileEcmaRegex(pattern)
  except EcmaRegexError as e: s.fail(name, e.msg)

proc subschemaAt(c: Compiler, s: Schema, node: YamlNode, pointer: string):
    Schema =
  if node.kind != yMapping and node.jsonKind != jkBool:
    # ``pointer`` is already a JSON Pointer, not a keyword to escape
    raise schemaError("invalid schema at " & s.location &
        encodeFragment(pointer) & ": expected a schema")
  var info: NodeInfo
  if not c.discovery.scope.infoOf(node, info):
    c.discovery.discover(node, s.resource, s.pointer & pointer,
        s.docPointer & pointer,
        s.dialect, false)
  result = c.compileSchema(node)

proc resolveReference(c: Compiler, s: Schema, keyword, reference: string):
    tuple[schema: Schema, resource: Resource, fragment: string] =
  let
    target = resolve(s.resource.uri, reference)
    base = target.withoutFragment
    frag = percentDecode(fragment(target))
  let resource = c.discovery.findResource(base)
  var node: YamlNode
  if frag.len == 0: node = resource.node
  elif frag[0] == '/':
    try: node = resolvePointer(resource.node, frag)
    except YamlFragmentError as e:
      s.fail(keyword, "cannot resolve " & escape(reference) & ": " & e.msg)
    var info: NodeInfo
    if not c.discovery.scope.infoOf(node, info):
      c.discovery.discover(node, resource, frag, resource.docPointer & frag,
          resource.dialect, false)
  else:
    node = resource.anchors.getOrDefault(frag)
    if node.isNil:
      s.fail(keyword, "cannot resolve " & escape(reference) &
          ": no anchor named " & escape(frag))
  if node.kind != yMapping and node.jsonKind != jkBool:
    s.fail(keyword, escape(reference) & " does not reference a schema")
  result = (c.compileSchema(node), resource, frag)

proc compileKeyword(c: Compiler, s: Schema, name: string, value: YamlNode,
    kind: KeywordKind): Keyword =
  let node = s.node
  result = Keyword(kind: kind, name: name, value: value, minContains: -1,
      maxContains: -1)
  let kw = result
  case kind
  of kRef, kDynamicRef, kRecursiveRef:
    var reference: string
    if not value.stringValue(reference): s.fail(name, "expected a string")
    let (target, resource, frag) = c.resolveReference(s, name, reference)
    kw.schema = target
    if kind == kDynamicRef and frag.len > 0 and frag[0] != '/' and
        frag in resource.dynamicAnchors:
      kw.dynamicName = frag
    if kind == kRecursiveRef:
      kw.recursive = target.resource.recursiveAnchor and
          target.node == target.resource.node
  of kType:
    var names: seq[string]
    if value.kind == ySequence: names = s.stringList(name, value)
    elif value.jsonKind == jkString: names = @[value.content]
    else: s.fail(name, "expected a string or an array of strings")
    for t in names:
      try: kw.types.incl(parseEnum[JsonType](t))
      except ValueError: s.fail(name, "unknown type " & escape(t))
  of kEnum:
    if value.kind != ySequence: s.fail(name, "expected an array")
  of kConst, kAnnotation, kUnknown: discard
  of kMultipleOf:
    kw.num = s.numberValue(name, value)
    if not (Num(finite: true, dec: Decimal()) < kw.num):
      s.fail(name, "expected a number greater than 0")
  of kMaximum, kMinimum:
    kw.num = s.numberValue(name, value)
    if s.dialect.draft == draft4:
      let exclusive = node.member(if kind == kMaximum: "exclusiveMaximum"
                                  else: "exclusiveMinimum")
      kw.flag = not exclusive.isNil and exclusive.jsonKind == jkBool and
          exclusive.jsonScalar.boolean
  of kExclusiveMaximum, kExclusiveMinimum:
    if s.dialect.draft == draft4:
      if value.jsonKind != jkBool: s.fail(name, "expected a boolean")
    else: kw.num = s.numberValue(name, value)
  of kMaxLength, kMinLength, kMaxItems, kMinItems, kMaxProperties,
     kMinProperties:
    kw.count = s.nonNegative(name, value)
  of kPattern:
    var pattern: string
    if not value.stringValue(pattern): s.fail(name, "expected a string")
    kw.regex = s.compileRegex(name, pattern)
  of kUniqueItems:
    if value.jsonKind != jkBool: s.fail(name, "expected a boolean")
    kw.flag = value.jsonScalar.boolean
  of kRequired:
    kw.names = s.stringList(name, value)
  of kDependentRequired:
    if value.kind != yMapping: s.fail(name, "expected an object")
    for property, required in value.members:
      kw.dependents.add((property, s.stringList(name, required)))
  of kFormat, kContentEncoding, kContentMediaType:
    var str: string
    if not value.stringValue(str): s.fail(name, "expected a string")
  of kContentSchema, kNot, kAdditionalItems, kAdditionalProperties,
     kPropertyNames, kUnevaluatedItems, kUnevaluatedProperties:
    kw.schema = c.subschemaAt(s, value, "/" & escapeToken(name))
  of kContains:
    kw.schema = c.subschemaAt(s, value, "/contains")
    if s.dialect.draft >= draft2019:
      let
        minNode = node.member("minContains")
        maxNode = node.member("maxContains")
      if vocValidation in s.dialect.vocabularies:
        if not minNode.isNil: kw.minContains = s.nonNegative("minContains", minNode)
        if not maxNode.isNil: kw.maxContains = s.nonNegative("maxContains", maxNode)
  of kIf:
    kw.schema = c.subschemaAt(s, value, "/if")
    let
      thenNode = node.member("then")
      elseNode = node.member("else")
    if not thenNode.isNil: kw.thenSchema = c.subschemaAt(s, thenNode, "/then")
    if not elseNode.isNil: kw.elseSchema = c.subschemaAt(s, elseNode, "/else")
  of kAllOf, kAnyOf, kOneOf, kPrefixItems:
    if value.kind != ySequence or value.elems.len == 0:
      s.fail(name, "expected a non-empty array of schemas")
    for i, item in value.elems:
      kw.schemas.add(c.subschemaAt(s, item, "/" & name & "/" & $i))
  of kItems:
    if value.kind == ySequence and s.dialect.draft <= draft2019:
      for i, item in value.elems:
        kw.schemas.add(c.subschemaAt(s, item, "/items/" & $i))
      kw.flag = true # array form
    else: kw.schema = c.subschemaAt(s, value, "/items")
  of kProperties, kDependentSchemas:
    if value.kind != yMapping: s.fail(name, "expected an object")
    for (property, subschema) in value.orderedMembers:
      kw.named.add((property, c.subschemaAt(s, subschema,
          "/" & name / property)))
  of kDependencies:
    if value.kind != yMapping: s.fail(name, "expected an object")
    for (property, dependency) in value.orderedMembers:
      if dependency.kind == ySequence:
        kw.dependents.add((property, s.stringList(name, dependency)))
      else:
        kw.named.add((property, c.subschemaAt(s, dependency,
            "/" & name / property)))
  of kPatternProperties:
    if value.kind != yMapping: s.fail(name, "expected an object")
    for (pattern, subschema) in value.orderedMembers:
      kw.patterns.add((s.compileRegex(name, pattern), pattern,
          c.subschemaAt(s, subschema, "/" & name / pattern)))

proc compileSchema(c: Compiler, node: YamlNode): Schema =
  let key = cast[pointer](node)
  var store = c.discovery.scope
  while not store.isNil:
    if store.compiled.hasKey(key): return store.compiled.getOrDefault(key)
    store = store.parent
  var info: NodeInfo
  if not c.discovery.scope.infoOf(node, info):
    raise schemaError("internal error: schema node was not discovered")
  result = Schema(node: node, resource: info.resource, pointer: info.pointer,
      docPointer: info.docPointer,
      location: info.resource.locationOf(info.pointer),
      dialect: info.resource.dialect)
  # the node's own dialect may differ from its resource's if it was reached
  # by a pointer into a resource of another dialect; resources decide
  # store the schema where its node is known, before compiling keywords, so
  # that cyclic references find it
  var owner = c.discovery.scope
  while not owner.isNil and not owner.nodes.hasKey(key): owner = owner.parent
  if owner.isNil: owner = c.discovery.scope
  owner.compiled[key] = result
  if node.kind != yMapping:
    result.isBool = true
    result.boolValue = node.jsonScalar.boolean
    return
  let refOnly = result.dialect.draft <= draft7 and
      not node.member("$ref").isNil
  let lenient = c.discovery.registry.lenient
  let tolerant = not lenient.isNil and lenient(result.resource.uri)
  for (name, value) in node.orderedMembers:
    if refOnly and name != "$ref": continue
    let kind = keywordKind(name, result.dialect)
    if kind == kUnknown and isCoreName(name, result.dialect): continue
    var keyword: Keyword
    try: keyword = c.compileKeyword(result, name, value, kind)
    except JsonSchemaError:
      if tolerant: continue
      raise
    # draft-04: a modifier of maximum and minimum
    if kind in {kExclusiveMaximum, kExclusiveMinimum} and
        result.dialect.draft == draft4: continue
    result.keywords.add(keyword)
    if kind in {kUnevaluatedItems, kUnevaluatedProperties}:
      result.hasUnevaluated = true
  # evaluation order
  for i in 1 ..< result.keywords.len:
    var j = i
    while j > 0 and result.keywords[j - 1].kind > result.keywords[j].kind:
      swap(result.keywords[j - 1], result.keywords[j])
      dec(j)
  # additionalItems and additionalProperties depend on their siblings
  for kw in result.keywords:
    if kw.kind == kAdditionalItems:
      for other in result.keywords:
        if other.kind == kItems: kw.sibling = other
    elif kw.kind == kAdditionalProperties:
      var combined = Keyword(kind: kProperties)
      for other in result.keywords:
        if other.kind == kProperties: combined.named = other.named
        elif other.kind == kPatternProperties: combined.patterns = other.patterns
      kw.sibling = combined

proc compile*(registry: SchemaRegistry, schema: YamlNode, uri = "",
    draft = registry.defaultDraft): JsonSchema {.raises: [JsonSchemaError].} =
  ## Compiles ``schema``, retrieved from ``uri`` (which may be empty), into a
  ## ``JsonSchema``. ``draft`` is the dialect if ``schema`` does not declare
  ## one. Resolves all static references and raises ``JsonSchemaError`` if
  ## one cannot be resolved or a keyword has an invalid value.
  let store = newStore(registry.store)
  let d = Discovery(registry: registry, store: store, scope: store)
  let resource = d.addDocument(schema, uri, draft)
  discard resource
  let c = Compiler(discovery: d)
  result = JsonSchema(registry: registry, store: store,
      root: c.compileSchema(schema))

proc compile*(schema: YamlNode, uri = "", draft = draft2020): JsonSchema
    {.raises: [JsonSchemaError].} =
  ## Compiles ``schema`` with a new registry that knows only the
  ## meta-schemas.
  newSchemaRegistry(defaultDraft = draft).compile(schema, uri, draft)

proc compile*(registry: SchemaRegistry, uri: string): JsonSchema
    {.raises: [JsonSchemaError].} =
  ## Compiles the schema the registry knows as ``uri``, which may have a
  ## fragment (``http://example.com/s#/$defs/a``).
  let store = newStore(registry.store)
  let d = Discovery(registry: registry, store: store, scope: store)
  let c = Compiler(discovery: d)
  let base = Schema(resource: Resource(uri: ""), location: "#",
      dialect: defaultDialect(registry.defaultDraft))
  result = JsonSchema(registry: registry, store: store,
      root: c.resolveReference(base, "$ref", uri).schema)

proc subschema*(schema: JsonSchema, node: YamlNode): JsonSchema
    {.raises: [JsonSchemaError].} =
  ## Compiles ``node``, a subschema somewhere in the documents ``schema``
  ## was compiled from (such as a value obtained from an annotation), with
  ## the base URI and dialect it has there. Raises ``JsonSchemaError`` if
  ## ``node`` is not known as a subschema of those documents.
  let d = Discovery(registry: schema.registry, store: schema.store,
      scope: schema.store)
  var info: NodeInfo
  if not schema.store.infoOf(node, info):
    raise schemaError("not a subschema of " & schema.root.location)
  result = JsonSchema(registry: schema.registry, store: schema.store,
      root: Compiler(discovery: d).compileSchema(node))

proc location*(schema: JsonSchema): string =
  ## The absolute location (URI) of the compiled schema.
  schema.root.location

# ----------------------------------------------------------------------------
# Evaluation
# ----------------------------------------------------------------------------

type
  Evaluator = object
    discovery: Discovery
    options: ValidationOptions
    collect: bool
    dynamicScope: seq[Resource]
    active: Table[(pointer, pointer), int]
      ## (schema, instance) pairs being evaluated, with the instance depth
      ## at which they were entered
    instanceDepth: int

  Evaluated = object
    ## What a schema evaluated of its instance, for unevaluated*. Only
    ## tracked when needed.
    properties: HashSet[string]
    itemsUpTo: int
    items: HashSet[int]
    allItems: bool

  EvalResult = object
    valid: bool
    evaluated: Evaluated
    unit: OutputUnit

proc merge(a: var Evaluated, b: Evaluated) =
  for p in b.properties: a.properties.incl(p)
  a.itemsUpTo = max(a.itemsUpTo, b.itemsUpTo)
  for i in b.items: a.items.incl(i)
  a.allItems = a.allItems or b.allItems

proc isItemEvaluated(e: Evaluated, i: int): bool =
  e.allItems or i < e.itemsUpTo or i in e.items

proc evalSchema(e: var Evaluator, s: Schema, instance: YamlNode,
    instancePath, keywordPath: string, track: bool): EvalResult
    {.raises: [JsonSchemaError].}

proc namesNode(names: seq[string]): YamlNode =
  var elems: seq[YamlNode]
  for n in names: elems.add(newString(n))
  newYamlNode(elems)

proc checkContent(e: Evaluator, s: Schema, instance: YamlNode,
    encoding, mediaType: string, error: var string): bool =
  var content = instance.content
  if encoding.len > 0:
    if encoding.toLowerAscii != "base64": return true
    # strict base64: alphabet and padding only
    var stripped = content
    if stripped.len mod 4 != 0:
      error = "content is not valid base64"
      return false
    for i, ch in stripped:
      if ch notin Letters + Digits + {'+', '/', '='} or
          (ch == '=' and i < stripped.len - 2):
        error = "content is not valid base64"
        return false
    try: content = base64.decode(stripped)
    except ValueError:
      error = "content is not valid base64"
      return false
  if mediaType.len > 0 and mediaType.toLowerAscii.startsWith("application/json"):
    try: discard parseJson(content)
    except CatchableError:
      error = "content is not valid JSON"
      return false
  result = true

proc evalReference(e: var Evaluator, s: Schema, kw: Keyword, instance: YamlNode,
    instancePath, keywordPath, kwPath: string, track: bool, unit: OutputUnit,
    evaluation: var EvalResult, valid: var bool, error: var string,
    annotation: var YamlNode) {.raises: [JsonSchemaError].} =
  ## Evaluates the reference keywords.
  let collect = e.collect
  template child(sub: Schema, inst: YamlNode, instPath, path: string,
      trackChild: bool, descend = true): EvalResult =
    if descend: inc(e.instanceDepth)
    let r = e.evalSchema(sub, inst, instPath, path, trackChild)
    if descend: dec(e.instanceDepth)
    if collect: unit.children.add(r.unit)
    r
  template childPath(token: string): string =
    (if collect: instancePath / token else: "")
  template childPath(index: int): string =
    (if collect: instancePath / index else: "")
  template inPlace(sub: Schema, path: string): EvalResult =
    child(sub, instance, instancePath, path, track, false)

  let jtype = instance.jsonTypeOf
  case kw.kind
  of kRef, kDynamicRef, kRecursiveRef:
    var target = kw.schema
    if kw.dynamicName.len > 0:
      for resource in e.dynamicScope:
        if kw.dynamicName in resource.dynamicAnchors:
          target = Compiler(discovery: e.discovery).compileSchema(
              resource.anchors.getOrDefault(kw.dynamicName))
          break
    elif kw.recursive:
      for resource in e.dynamicScope:
        if resource.recursiveAnchor:
          target = Compiler(discovery: e.discovery).compileSchema(resource.node)
          break
    let r = inPlace(target, kwPath)
    valid = r.valid
    if valid and track: evaluation.evaluated.merge(r.evaluated)
    if not valid: error = "does not match the referenced schema"
  else: discard

proc evalAssertion(e: var Evaluator, s: Schema, kw: Keyword, instance: YamlNode,
    instancePath, keywordPath, kwPath: string, track: bool, unit: OutputUnit,
    evaluation: var EvalResult, valid: var bool, error: var string,
    annotation: var YamlNode) {.raises: [JsonSchemaError].} =
  ## Evaluates keywords that do not apply subschemas.
  let collect = e.collect
  template child(sub: Schema, inst: YamlNode, instPath, path: string,
      trackChild: bool, descend = true): EvalResult =
    if descend: inc(e.instanceDepth)
    let r = e.evalSchema(sub, inst, instPath, path, trackChild)
    if descend: dec(e.instanceDepth)
    if collect: unit.children.add(r.unit)
    r
  template childPath(token: string): string =
    (if collect: instancePath / token else: "")
  template childPath(index: int): string =
    (if collect: instancePath / index else: "")
  template inPlace(sub: Schema, path: string): EvalResult =
    child(sub, instance, instancePath, path, track, false)

  let jtype = instance.jsonTypeOf
  case kw.kind
  of kType:
    valid = jtype in kw.types or (jtype == jtNumber and jtInteger in kw.types and
        numberOf(instance).isInteger and
        # draft-04: integers are written without fraction or exponent
        (s.dialect.draft != draft4 or
         not instance.content.contains({'.', 'e', 'E'})))
    if not valid:
      var expected: seq[string]
      for t in kw.types: expected.add($t)
      error = "expected " & expected.join(" or ") & ", got " & $jtype
  of kEnum:
    valid = false
    for item in kw.value.elems:
      if instanceEquals(instance, item):
        valid = true
        break
    if not valid: error = instance.describe & " is not one of the allowed values"
  of kConst:
    valid = instanceEquals(instance, kw.value)
    if not valid: error = instance.describe & " is not the constant value"
  of kMultipleOf:
    if jtype == jtNumber:
      valid = numberOf(instance).isMultipleOf(kw.num)
      if not valid: error = instance.describe & " is not a multiple of " & $kw.num
  of kMaximum, kMinimum, kExclusiveMaximum, kExclusiveMinimum:
    if jtype == jtNumber:
      let n = numberOf(instance)
      let exclusive = kw.kind in {kExclusiveMaximum, kExclusiveMinimum} or kw.flag
      if kw.kind in {kMaximum, kExclusiveMaximum}:
        valid = if exclusive: n < kw.num else: n <= kw.num
        if not valid:
          error = instance.describe & " is greater than " &
              (if exclusive: "or equal to " else: "") & "the maximum of " & $kw.num
      else:
        valid = if exclusive: kw.num < n else: kw.num <= n
        if not valid:
          error = instance.describe & " is less than " &
              (if exclusive: "or equal to " else: "") & "the minimum of " & $kw.num
  of kMaxLength, kMinLength:
    if jtype == jtString:
      let length = instance.content.runeLen
      valid = if kw.kind == kMaxLength: length <= kw.count else: length >= kw.count
      if not valid:
        error = "string has " & $length & " characters, " &
            (if kw.kind == kMaxLength: "at most " else: "at least ") & $kw.count &
            " allowed"
  of kPattern:
    if jtype == jtString:
      try: valid = kw.regex.contains(instance.content)
      except EcmaRegexError as err: raise schemaError(err.msg)
      if not valid:
        error = instance.describe & " does not match " & escape(kw.value.content)
  of kMaxItems, kMinItems:
    if jtype == jtArray:
      let length = instance.elems.len
      valid = if kw.kind == kMaxItems: length <= kw.count else: length >= kw.count
      if not valid:
        error = "array has " & $length & " items, " &
            (if kw.kind == kMaxItems: "at most " else: "at least ") & $kw.count &
            " allowed"
  of kUniqueItems:
    if jtype == jtArray and kw.flag:
      block check:
        for i in 0 ..< instance.elems.len:
          for j in i + 1 ..< instance.elems.len:
            if instanceEquals(instance.elems[i], instance.elems[j]):
              valid = false
              error = "items " & $i & " and " & $j & " are equal"
              break check
  of kMaxProperties, kMinProperties:
    if jtype == jtObject:
      var count = 0
      for _ in instance.members: inc(count)
      valid = if kw.kind == kMaxProperties: count <= kw.count
              else: count >= kw.count
      if not valid:
        error = "object has " & $count & " properties, " &
            (if kw.kind == kMaxProperties: "at most " else: "at least ") &
            $kw.count & " allowed"
  of kRequired:
    if jtype == jtObject:
      var missing: seq[string]
      for name in kw.names:
        if instance.member(name).isNil: missing.add(escape(name))
      valid = missing.len == 0
      if not valid: error = "missing required properties " & missing.join(", ")
  of kDependentRequired:
    if jtype == jtObject:
      for (name, required) in kw.dependents:
        if instance.member(name).isNil: continue
        for r in required:
          if instance.member(r).isNil:
            valid = false
            error = "property " & escape(name) & " requires property " & escape(r)
            break
  of kFormat:
    annotation = kw.value
    if jtype == jtString and (e.options.formatAssertion or
        vocFormatAssertion in s.dialect.vocabularies):
      var known: bool
      valid = checkFormat(kw.value.content, instance.content, known,
          s.dialect.draft >= draft7)
      if not valid:
        error = instance.describe & " is not a valid " & kw.value.content
  of kContentEncoding, kContentMediaType:
    if jtype == jtString: annotation = kw.value
    if jtype == jtString and e.options.contentAssertion:
      # both are checked together, by the first of them
      let
        encodingNode = s.node.member("contentEncoding")
        mediaNode = s.node.member("contentMediaType")
      var encoding, mediaType: string
      discard encodingNode.stringValue(encoding)
      discard mediaNode.stringValue(mediaType)
      if kw.kind == kContentEncoding or encodingNode.isNil:
        valid = e.checkContent(s, instance, encoding, mediaType, error)
  of kContentSchema:
    if jtype == jtString and not s.node.member("contentMediaType").isNil:
      annotation = kw.value
  of kAnnotation, kUnknown:
    annotation = kw.value
  else: discard

proc evalInPlace(e: var Evaluator, s: Schema, kw: Keyword, instance: YamlNode,
    instancePath, keywordPath, kwPath: string, track: bool, unit: OutputUnit,
    evaluation: var EvalResult, valid: var bool, error: var string,
    annotation: var YamlNode) {.raises: [JsonSchemaError].} =
  ## Evaluates applicators that apply subschemas to the instance itself.
  let collect = e.collect
  template child(sub: Schema, inst: YamlNode, instPath, path: string,
      trackChild: bool, descend = true): EvalResult =
    if descend: inc(e.instanceDepth)
    let r = e.evalSchema(sub, inst, instPath, path, trackChild)
    if descend: dec(e.instanceDepth)
    if collect: unit.children.add(r.unit)
    r
  template childPath(token: string): string =
    (if collect: instancePath / token else: "")
  template childPath(index: int): string =
    (if collect: instancePath / index else: "")
  template inPlace(sub: Schema, path: string): EvalResult =
    child(sub, instance, instancePath, path, track, false)

  let jtype = instance.jsonTypeOf
  case kw.kind
  of kAllOf:
    for i, sub in kw.schemas:
      let r = inPlace(sub, kwPath / i)
      if not r.valid:
        valid = false
        if not collect: break
      elif track: evaluation.evaluated.merge(r.evaluated)
    if not valid: error = "does not match all subschemas"
  of kAnyOf:
    valid = false
    for i, sub in kw.schemas:
      let r = inPlace(sub, kwPath / i)
      if r.valid:
        valid = true
        if track: evaluation.evaluated.merge(r.evaluated)
        elif not collect: break
    if not valid: error = "does not match any subschema"
  of kOneOf:
    var matched: seq[int]
    var evaluated: Evaluated
    for i, sub in kw.schemas:
      let r = inPlace(sub, kwPath / i)
      if r.valid:
        matched.add(i)
        if track: evaluated.merge(r.evaluated)
        if matched.len > 1 and not collect: break
    valid = matched.len == 1
    if valid and track: evaluation.evaluated.merge(evaluated)
    if matched.len == 0: error = "does not match any subschema"
    elif matched.len > 1:
      error = "matches subschemas " & $matched[0] & " and " & $matched[1] &
          ", but must match exactly one"
  of kNot:
    let r = inPlace(kw.schema, kwPath)
    valid = not r.valid
    if not valid: error = "must not match the subschema"
  of kIf:
    # the if schema is not an assertion: its unit only appears if it passed
    let r = e.evalSchema(kw.schema, instance, instancePath, kwPath, track)
    if r.valid:
      if collect: unit.children.add(r.unit)
      if track: evaluation.evaluated.merge(r.evaluated)
    let (branch, name) = if r.valid: (kw.thenSchema, "then")
                         else: (kw.elseSchema, "else")
    if not branch.isNil:
      let branchPath = if collect: keywordPath / name else: ""
      let b = e.evalSchema(branch, instance, instancePath, branchPath, track)
      if collect:
        let branchUnit = OutputUnit(kind: oukKeyword, keyword: name,
            keywordLocation: branchPath,
            absoluteKeywordLocation: s.keywordLocation(name),
            schemaLocation: s.location, documentPointer: s.docPointer,
            instanceLocation: instancePath,
            valid: b.valid, children: @[b.unit])
        if not b.valid: branchUnit.error = "does not match the " & name & " schema"
        unit.children.add(branchUnit)
      if b.valid:
        if track: evaluation.evaluated.merge(b.evaluated)
      else:
        valid = false
        error = "does not match the " & name & " schema"
  of kDependentSchemas, kDependencies:
    if jtype == jtObject:
      for (name, sub) in kw.named:
        if instance.member(name).isNil: continue
        let r = inPlace(sub, kwPath / name)
        if r.valid:
          if track: evaluation.evaluated.merge(r.evaluated)
        else:
          valid = false
          error = "does not match the schema required by property " & escape(name)
          if not collect: break
      for (name, required) in kw.dependents:
        if instance.member(name).isNil: continue
        for r in required:
          if instance.member(r).isNil:
            valid = false
            error = "property " & escape(name) & " requires property " & escape(r)
  else: discard

proc evalArray(e: var Evaluator, s: Schema, kw: Keyword, instance: YamlNode,
    instancePath, keywordPath, kwPath: string, track: bool, unit: OutputUnit,
    evaluation: var EvalResult, valid: var bool, error: var string,
    annotation: var YamlNode) {.raises: [JsonSchemaError].} =
  ## Evaluates applicators for array items.
  let collect = e.collect
  template child(sub: Schema, inst: YamlNode, instPath, path: string,
      trackChild: bool, descend = true): EvalResult =
    if descend: inc(e.instanceDepth)
    let r = e.evalSchema(sub, inst, instPath, path, trackChild)
    if descend: dec(e.instanceDepth)
    if collect: unit.children.add(r.unit)
    r
  template childPath(token: string): string =
    (if collect: instancePath / token else: "")
  template childPath(index: int): string =
    (if collect: instancePath / index else: "")
  template inPlace(sub: Schema, path: string): EvalResult =
    child(sub, instance, instancePath, path, track, false)

  let jtype = instance.jsonTypeOf
  case kw.kind
  of kPrefixItems, kItems:
    if jtype == jtArray:
      let elems = instance.elems
      if kw.kind == kPrefixItems or kw.flag:
        let count = min(kw.schemas.len, elems.len)
        for i in 0 ..< count:
          let r = child(kw.schemas[i], elems[i], childPath(i), kwPath / i, false)
          if not r.valid:
            valid = false
            if not collect: break
        if count > 0:
          # the largest index the keyword applied to, or true for all
          annotation = if count == elems.len: newBool(true)
                       else: newYamlNode($(count - 1), yTagInteger)
        if valid: evaluation.evaluated.itemsUpTo = max(evaluation.evaluated.itemsUpTo, count)
      else:
        # 2020-12 items after prefixItems, or the single-schema form
        var start = 0
        if s.dialect.draft >= draft2020:
          for other in s.keywords:
            if other.kind == kPrefixItems: start = other.schemas.len
        for i in start ..< elems.len:
          let r = child(kw.schema, elems[i], childPath(i), kwPath / i, false)
          if not r.valid:
            valid = false
            if not collect: break
        if start < elems.len: annotation = newBool(true)
        if valid: evaluation.evaluated.allItems = true
      if not valid: error = "not all items match"
  of kAdditionalItems:
    if jtype == jtArray and not kw.sibling.isNil and kw.sibling.flag:
      let elems = instance.elems
      for i in kw.sibling.schemas.len ..< elems.len:
        let r = child(kw.schema, elems[i], childPath(i), kwPath / i, false)
        if not r.valid:
          valid = false
          if not collect: break
      if kw.sibling.schemas.len < elems.len: annotation = newBool(true)
      if valid: evaluation.evaluated.allItems = true
      if not valid: error = "additional items do not match"
  of kContains:
    if jtype == jtArray:
      var matched: seq[YamlNode]
      var indices: seq[int]
      for i, item in instance.elems:
        let r = child(kw.schema, item, childPath(i), kwPath, false)
        if r.valid:
          indices.add(i)
          matched.add(newYamlNode($i, yTagInteger))
      let
        minimum = if kw.minContains >= 0: kw.minContains else: 1
        count = indices.len
      valid = count >= minimum and (kw.maxContains < 0 or count <= kw.maxContains)
      if not valid:
        error = if count < minimum: "contains " & $count &
            " matching items, at least " & $minimum & " required"
          else: "contains " & $count & " matching items, at most " &
            $kw.maxContains & " allowed"
      else:
        annotation = if count == instance.elems.len and count > 0: newBool(true)
                     else: newYamlNode(matched)
        if s.dialect.draft >= draft2020:
          for i in indices: evaluation.evaluated.items.incl(i)
  of kUnevaluatedItems:
    if jtype == jtArray:
      var evaluatedAny = false
      for i, item in instance.elems:
        if evaluation.evaluated.isItemEvaluated(i): continue
        evaluatedAny = true
        let r = child(kw.schema, item, childPath(i), kwPath, false)
        if not r.valid:
          valid = false
          if not collect: break
      if evaluatedAny: annotation = newBool(true)
      if valid: evaluation.evaluated.allItems = true
      else: error = "unevaluated items do not match"
  else: discard

proc evalObject(e: var Evaluator, s: Schema, kw: Keyword, instance: YamlNode,
    instancePath, keywordPath, kwPath: string, track: bool, unit: OutputUnit,
    evaluation: var EvalResult, valid: var bool, error: var string,
    annotation: var YamlNode) {.raises: [JsonSchemaError].} =
  ## Evaluates applicators for object members.
  let collect = e.collect
  template child(sub: Schema, inst: YamlNode, instPath, path: string,
      trackChild: bool, descend = true): EvalResult =
    if descend: inc(e.instanceDepth)
    let r = e.evalSchema(sub, inst, instPath, path, trackChild)
    if descend: dec(e.instanceDepth)
    if collect: unit.children.add(r.unit)
    r
  template childPath(token: string): string =
    (if collect: instancePath / token else: "")
  template childPath(index: int): string =
    (if collect: instancePath / index else: "")
  template inPlace(sub: Schema, path: string): EvalResult =
    child(sub, instance, instancePath, path, track, false)

  let jtype = instance.jsonTypeOf
  case kw.kind
  of kProperties:
    if jtype == jtObject:
      var names: seq[string]
      for (name, sub) in kw.named:
        let value = instance.member(name)
        if value.isNil: continue
        names.add(name)
        let r = child(sub, value, childPath(name), kwPath / name, false)
        if not r.valid:
          valid = false
          if not collect: break
      annotation = namesNode(names)
      if valid:
        for n in names: evaluation.evaluated.properties.incl(n)
      else: error = "not all properties match"
  of kPatternProperties:
    if jtype == jtObject:
      var names: seq[string]
      for (name, value) in instance.orderedMembers:
        for (regex, source, sub) in kw.patterns:
          var matches: bool
          try: matches = regex.contains(name)
          except EcmaRegexError as err: raise schemaError(err.msg)
          if not matches: continue
          if name notin names: names.add(name)
          let r = child(sub, value, childPath(name), kwPath / source, false)
          if not r.valid:
            valid = false
            if not collect: break
      annotation = namesNode(names)
      if valid:
        for n in names: evaluation.evaluated.properties.incl(n)
      else: error = "not all properties match"
  of kAdditionalProperties:
    if jtype == jtObject:
      var names: seq[string]
      for (name, value) in instance.orderedMembers:
        var covered = false
        for (n, _) in kw.sibling.named:
          if n == name: covered = true
        if not covered:
          for (regex, _, _) in kw.sibling.patterns:
            try:
              if regex.contains(name): covered = true
            except EcmaRegexError as err: raise schemaError(err.msg)
        if covered: continue
        names.add(name)
        let r = child(kw.schema, value, childPath(name), kwPath, false)
        if not r.valid:
          valid = false
          if not collect: break
      annotation = namesNode(names)
      if valid:
        for n in names: evaluation.evaluated.properties.incl(n)
      else: error = "additional properties do not match"
  of kPropertyNames:
    if jtype == jtObject:
      for (name, _) in instance.orderedMembers:
        let r = child(kw.schema, newString(name), instancePath, kwPath, false)
        if not r.valid:
          valid = false
          error = "property name " & escape(name) & " does not match"
          if not collect: break
  of kUnevaluatedProperties:
    if jtype == jtObject:
      var names: seq[string]
      for (name, value) in instance.orderedMembers:
        if name in evaluation.evaluated.properties: continue
        names.add(name)
        let r = child(kw.schema, value, childPath(name), kwPath, false)
        if not r.valid:
          valid = false
          if not collect: break
      annotation = namesNode(names)
      if valid:
        for n in names: evaluation.evaluated.properties.incl(n)
      else: error = "unevaluated properties do not match"

  else: discard

proc evalKeyword(e: var Evaluator, s: Schema, kw: Keyword, instance: YamlNode,
    instancePath, keywordPath: string, track: bool, evaluation: var EvalResult):
    OutputUnit {.raises: [JsonSchemaError].} =
  ## Evaluates ``kw``, updating ``evaluation`` (validity and evaluated parts of
  ## the instance). Returns the keyword's output unit if collecting.
  let collect = e.collect
  var
    unit: OutputUnit
    valid = true
    error = ""
    annotation: YamlNode = nil
  let kwPath = if collect: keywordPath / kw.name else: ""
  if collect:
    unit = OutputUnit(kind: oukKeyword, keyword: kw.name,
        keywordLocation: kwPath,
        absoluteKeywordLocation: s.keywordLocation(kw.name),
        schemaLocation: s.location, documentPointer: s.docPointer,
        instanceLocation: instancePath)

  template dispatch(group: untyped) =
    e.group(s, kw, instance, instancePath, keywordPath, kwPath, track,
        unit, evaluation, valid, error, annotation)
  case kw.kind
  of kRef, kDynamicRef, kRecursiveRef: dispatch(evalReference)
  of kType, kEnum, kConst, kMultipleOf, kMaximum, kMinimum,
     kExclusiveMaximum, kExclusiveMinimum, kMaxLength, kMinLength, kPattern,
     kMaxItems, kMinItems, kUniqueItems, kMaxProperties, kMinProperties,
     kRequired, kDependentRequired, kFormat, kContentEncoding,
     kContentMediaType, kContentSchema, kAnnotation, kUnknown:
    dispatch(evalAssertion)
  of kAllOf, kAnyOf, kOneOf, kNot, kIf, kDependentSchemas, kDependencies:
    dispatch(evalInPlace)
  of kPrefixItems, kItems, kAdditionalItems, kContains, kUnevaluatedItems:
    dispatch(evalArray)
  of kProperties, kPatternProperties, kAdditionalProperties, kPropertyNames,
     kUnevaluatedProperties:
    dispatch(evalObject)
  if not valid: evaluation.valid = false
  if collect:
    unit.valid = valid
    if not valid:
      unit.error = error
    elif not annotation.isNil:
      unit.annotation = annotation
  result = unit

proc evalSchema(e: var Evaluator, s: Schema, instance: YamlNode,
    instancePath, keywordPath: string, track: bool): EvalResult =
  result.valid = true
  if e.collect:
    result.unit = OutputUnit(kind: oukSchema, keywordLocation: keywordPath,
        absoluteKeywordLocation: s.location, instanceLocation: instancePath)
  if s.isBool:
    result.valid = s.boolValue
    if e.collect:
      result.unit.valid = s.boolValue
      if not s.boolValue: result.unit.error = "no value is allowed here"
    return
  # A schema that applies itself to the same instance again without
  # descending into it would never finish. Reaching the same pair after
  # descending means the instance is cyclic (aliases); it is assumed to be
  # valid there, as equality does for cyclic graphs.
  let key = (cast[pointer](s), cast[pointer](instance))
  let entered = e.active.getOrDefault(key, -1)
  if entered == e.instanceDepth:
    raise schemaError("infinite recursion: " & s.location &
        " applies to the same instance again")
  if entered >= 0:
    if e.collect: result.unit.valid = true
    return
  if e.instanceDepth > maxDepth:
    raise schemaError("instance is nested too deeply at " & instancePath)
  e.active[key] = e.instanceDepth
  let pushed = e.dynamicScope.len == 0 or e.dynamicScope[^1] != s.resource
  if pushed: e.dynamicScope.add(s.resource)
  let trackHere = track or s.hasUnevaluated
  for kw in s.keywords:
    if not e.collect and not result.valid: break
    let unit = e.evalKeyword(s, kw, instance, instancePath, keywordPath,
        trackHere, result)
    if e.collect: result.unit.children.add(unit)
  if pushed: discard e.dynamicScope.pop()
  e.active.del(key)
  if e.collect:
    result.unit.valid = result.valid
  if not result.valid: result.evaluated = Evaluated()

proc isValid*(schema: JsonSchema, instance: YamlNode,
    options = ValidationOptions()): bool {.raises: [JsonSchemaError].} =
  ## Whether ``instance`` is valid against ``schema``. Stops at the first
  ## failing keyword.
  var e = Evaluator(discovery: Discovery(registry: schema.registry,
      store: schema.registry.store, scope: schema.store), options: options)
  result = e.evalSchema(schema.root, instance, "", "", false).valid

proc validate*(schema: JsonSchema, instance: YamlNode,
    options = ValidationOptions()): ValidationResult
    {.raises: [JsonSchemaError].} =
  ## Evaluates ``schema`` completely against ``instance``, collecting errors
  ## and annotations.
  var e = Evaluator(discovery: Discovery(registry: schema.registry,
      store: schema.registry.store, scope: schema.store), options: options,
      collect: true)
  let r = e.evalSchema(schema.root, instance, "", "", false)
  result = ValidationResult(valid: r.valid, tree: r.unit)

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

proc outputTree*(r: ValidationResult): OutputUnit =
  ## The root of the output tree: the unit of the root schema.
  r.tree

proc collectErrors(u: OutputUnit, output: var seq[OutputUnit]) =
  if u.valid: return
  if u.kind == oukKeyword or u.error.len > 0: output.add(u)
  for c in u.children: collectErrors(c, output)

proc errors*(r: ValidationResult): seq[OutputUnit] =
  ## The failed keywords (and false schemas) of an invalid result, outermost
  ## first, as in the *basic* output format. Empty for a valid result.
  if not r.tree.isNil: collectErrors(r.tree, result)

proc collectAnnotations(u: OutputUnit, output: var seq[OutputUnit]) =
  if not u.valid: return
  if u.kind == oukKeyword and not u.annotation.isNil: output.add(u)
  for c in u.children: collectAnnotations(c, output)

proc annotationUnits*(r: ValidationResult): seq[OutputUnit] =
  ## The keywords that produced annotations, as in the *basic* output format.
  ## Annotations of subschemas that failed are dropped, so this is empty if
  ## the whole result is invalid.
  if not r.tree.isNil and r.valid: collectAnnotations(r.tree, result)

proc annotations*(r: ValidationResult): seq[Annotation] =
  ## The annotations of a valid result.
  for u in r.annotationUnits:
    result.add(Annotation(instanceLocation: u.instanceLocation,
        keyword: u.keyword, schemaLocation: u.schemaLocation,
        documentPointer: u.documentPointer,
        keywordLocation: u.keywordLocation, value: u.annotation))

proc unitNode(u: OutputUnit, nested: seq[YamlNode]): YamlNode =
  var fields = @[
    (newKey("valid"), newBool(u.valid)),
    (newKey("keywordLocation"), newString(u.keywordLocation)),
    (newKey("instanceLocation"), newString(u.instanceLocation))]
  if u.absoluteKeywordLocation.isAbsolute:
    fields.add((newKey("absoluteKeywordLocation"),
        newString(u.absoluteKeywordLocation)))
  if not u.valid and u.error.len > 0:
    fields.add((newKey("error"), newString(u.error)))
  if u.valid and not u.annotation.isNil:
    fields.add((newKey("annotation"), u.annotation))
  if nested.len > 0:
    fields.add((newKey(if u.valid: "annotations" else: "errors"),
        newYamlNode(nested)))
  result = newYamlNode(fields)

proc verbose(u: OutputUnit): YamlNode =
  var nested: seq[YamlNode]
  for c in u.children: nested.add(verbose(c))
  result = unitNode(u, nested)

proc detailed(u: OutputUnit, wantValid: bool): YamlNode =
  ## Keeps failed units (or, for valid results, annotating ones) and
  ## replaces units that have exactly one remaining child by that child.
  var nested: seq[YamlNode]
  for c in u.children:
    if c.valid != wantValid: continue
    let n = detailed(c, wantValid)
    if not n.isNil: nested.add(n)
  let relevant = if wantValid: not u.annotation.isNil else: u.error.len > 0
  if nested.len == 0 and not relevant: return nil
  if nested.len == 1 and not relevant: return nested[0]
  result = unitNode(u, nested)

proc toYaml*(r: ValidationResult, format: OutputFormat): YamlNode =
  ## Renders the result in one of the output formats of JSON Schema 2020-12,
  ## Section 12.4.
  case format
  of ofFlag:
    result = newYamlNode([(newKey("valid"), newBool(r.valid))])
  of ofBasic:
    var units: seq[YamlNode]
    if r.valid:
      for u in r.annotationUnits: units.add(unitNode(u, @[]))
    else:
      for u in r.errors: units.add(unitNode(u, @[]))
    var fields = @[(newKey("valid"), newBool(r.valid))]
    if units.len > 0:
      fields.add((newKey(if r.valid: "annotations" else: "errors"),
          newYamlNode(units)))
    result = newYamlNode(fields)
  of ofDetailed:
    result = detailed(r.tree, r.valid)
    if result.isNil:
      result = unitNode(r.tree, @[])
  of ofVerbose:
    result = verbose(r.tree)

proc metaSchemaUri*(schema: YamlNode, defaultDraft = draft2020): string =
  ## The URI of the meta-schema ``schema`` declares with ``$schema``, or
  ## that of ``defaultDraft``.
  if schema.kind == yMapping and schema.member("$schema").stringValue(result):
    return
  for (uri, draft, hyper) in dialectUris:
    if draft == defaultDraft and not hyper: return uri

proc checkSchema*(registry: SchemaRegistry, schema: YamlNode):
    ValidationResult {.raises: [JsonSchemaError].} =
  ## Validates ``schema`` against its meta-schema.
  registry.compile(metaSchemaUri(schema, registry.defaultDraft)).validate(schema)
