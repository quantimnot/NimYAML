#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =======================
## Module yaml/schemainfer
## =======================
##
## Writes a `JSON Schema <jsonschema.html>`_ (draft 2020-12) that describes
## a set of example documents: what types each location holds, which
## members its objects have and which of them every object has, and what
## the items of its arrays look like. It is a starting point for a schema
## written by hand, not a replacement for one: a sample shows what *is*,
## and a schema says what *may be*.
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, schemainfer]
##
##   var inference = initSchemaInference()
##   inference.add(loadAs[YamlNode]("{name: Ada, born: 1815-12-10, tags: [math]}"))
##   inference.add(loadAs[YamlNode]("{name: Alan, tags: []}"))
##   echo schemaText(inference.toSchema())
##   # $schema: "https://json-schema.org/draft/2020-12/schema"
##   # type: object
##   # properties:
##   #   name:
##   #     type: string
##   #   born:
##   #     type: string
##   #     format: date
##   #   tags:
##   #     type: array
##   #     items:
##   #       type: string
##   # required:
##   #   - name
##   #   - tags
##
## Documents are added one at a time to a ``SchemaInference``, which keeps
## a summary of what it has seen rather than the documents, so that a
## stream of any length can be described in the memory its largest
## document needs. ``inferSchema`` does it all at once.
##
## The schema validates every document it was made from, against
## `yaml/jsonschema <jsonschema.html>`_, with format assertion on or off.
##
## Reading documents as JSON
## -------------------------
##
## Documents are read the way ``yaml/jsonschema`` reads instances, so that
## the schema describes what the validator will see: plain scalars are
## resolved by the YAML 1.2 core schema (``80`` is an integer, ``true`` a
## boolean, ``~`` null, ``2001-12-14`` a string), quoted scalars are
## strings, scalars with other tags are strings, and only mapping keys that
## are strings are members. A member with the key ``1`` or ``[a, b]`` is
## invisible to the validator, and to this module too. Aliases are
## followed; a cycle is described once, and where it closes, only by type.
##
## How the evidence is merged
## --------------------------
##
## Every location in the documents, from the root down through member
## names and array items, gathers the values found there, across all
## documents, and its schema says what they have in common:
##
## * ``type`` lists every type seen, as one name or as a list in the order
##   ``object``, ``array``, ``string``, ``integer``, ``number``, ``boolean``,
##   ``null``. A number written as an integer (``1``) is an ``integer`` and
##   one written with a fraction or exponent (``1.0``, ``.inf``) a
##   ``number``; where both are seen, ``number`` alone, which includes the
##   integers. ``integers: false`` makes every number a ``number``.
## * ``properties`` has a schema for each member name seen in the objects
##   of the location, in the order the names were first seen, made from the
##   values of that member in all of them.
## * ``required`` lists the member names that every object of the location
##   has (``required: false`` leaves it out). A location that holds an
##   object in one document and a string in another requires the members of
##   all its objects, which ``required`` only asks of objects.
## * ``items`` is a single schema made from the items of all arrays of the
##   location. Arrays are taken as lists of alike things, not as tuples:
##   ``prefixItems`` would make ``[x, 2]`` require a string and then an
##   integer, which is rarely the point of a list, and every array of a
##   different length would contradict it. A location whose arrays are all
##   empty has no ``items``.
## * ``format`` is a format that every string of the location satisfies, by
##   the same checks ``yaml/jsonschema`` asserts formats with: ``date-time``,
##   ``date``, ``time``, ``email``, ``uuid`` or ``uri``, the first that
##   applies. A ``uri`` must also contain ``://``, since ``key:value`` and
##   ``urn:x`` are URIs too, but rarely meant as such. ``formats: false``
##   infers none.
## * ``enum`` is off unless ``enumLimit`` is above 0. Then a location whose
##   values are only strings (and nulls) gets an ``enum`` of the distinct
##   strings (and ``null``) if there are at most ``enumLimit`` of them and
##   they repeat: there are at least twice as many values as distinct
##   ones. The repetition is what tells a closed set (``status: active``)
##   from names that merely did not happen to differ yet; even so, an
##   ``enum`` is the guess most likely to reject the next document, which
##   is why it is off by default.
## * ``additionalProperties: false`` closes every object schema, with
##   ``additionalProperties: false`` in the options. Open is the default,
##   since a sample rarely has every optional member.
##
## Bounds (``minimum``, ``maxLength``, ``minItems``, ...) and patterns are
## never inferred: the sample's extremes are an accident of the sample.

import std/[sets, strutils, tables]
import data, dom, dumping, native, private/[jsonmodel, formats]
from hints import guessType, TypeHint

type
  InferenceOptions* = object
    ## The choices where the evidence does not decide, as described in the
    ## module documentation.
    required*: bool = true
      ## list the members every object has in ``required``
    additionalProperties*: bool = true
      ## false: ``additionalProperties: false`` in every object schema
    enumLimit*: int = 0
      ## the most distinct strings an ``enum`` is made of; 0 for none
    formats*: bool = true
      ## infer ``format`` for strings
    integers*: bool = true
      ## tell ``integer`` from ``number``

  InstanceType = enum
    # in the order of the ``type`` keyword's list
    itObject = "object", itArray = "array", itString = "string",
    itInteger = "integer", itNumber = "number", itBoolean = "boolean",
    itNull = "null"

  StringFormat = enum
    # in order of preference, where a string satisfies several
    sfDateTime = "date-time", sfDate = "date", sfTime = "time",
    sfEmail = "email", sfUuid = "uuid", sfUri = "uri"

  Member = object
    shape: Shape
    objects: int ## how many objects of the location have it

  Shape = ref object
    ## What the values of one location have in common.
    types: set[InstanceType]
    strings: int                  ## string values seen
    formats: set[StringFormat]    ## the formats all of them satisfy
    values: OrderedSet[string]    ## distinct strings, while few enough
    manyValues: bool              ## more than ``enumLimit`` distinct strings
    objects: int                  ## object values seen
    members: OrderedTable[string, Member]
    items: Shape                  ## all array items; nil while there are none

  SchemaInference* = object
    ## The summary of the documents added so far.
    options: InferenceOptions
    root: Shape
    documents: int
    onPath: HashSet[pointer] ## collections being described, against cycles

const draft2020Uri = "https://json-schema.org/draft/2020-12/schema"

proc initSchemaInference*(options = InferenceOptions()): SchemaInference =
  ## An inference that has seen no documents yet.
  SchemaInference(options: options)

proc documents*(inference: SchemaInference): int =
  ## The number of documents added.
  inference.documents

# Gathering
#
# Each value is folded into the shape of its location as it is read. A
# string remembers which formats it satisfies by intersecting them with
# those of the strings before it, so a location keeps a set, not its
# strings; only for an enum are the strings themselves kept, and only up to
# the limit, past which no enum can come of them.

proc formatsOf(s: string): set[StringFormat] =
  for format in StringFormat:
    var known: bool
    if checkFormat($format, s, known):
      if format != sfUri or "://" in s: result.incl(format)

proc newShape(): Shape = Shape()

proc addString(inference: SchemaInference, shape: Shape, s: string) =
  if inference.options.formats:
    let these = formatsOf(s)
    shape.formats = if shape.strings == 0: these else: shape.formats * these
  inc shape.strings
  if inference.options.enumLimit > 0 and not shape.manyValues:
    shape.values.incl(s)
    if shape.values.len > inference.options.enumLimit:
      shape.manyValues = true
      shape.values.clear()

proc addValue(inference: var SchemaInference, shape: Shape, node: YamlNode) =
  case node.kind
  of yScalar:
    let value = node.jsonScalar
    case value.kind
    of jkNull: shape.types.incl(itNull)
    of jkBool: shape.types.incl(itBoolean)
    of jkNumber:
      shape.types.incl(
          if value.number.isInteger and inference.options.integers: itInteger
          else: itNumber)
    of jkString:
      shape.types.incl(itString)
      inference.addString(shape, value.str)
    of jkArray, jkObject: discard # not of a scalar
  of ySequence:
    shape.types.incl(itArray)
    let id = cast[pointer](node)
    if inference.onPath.containsOrIncl(id): return
    for item in node.elems:
      if shape.items.isNil: shape.items = newShape()
      inference.addValue(shape.items, item)
    inference.onPath.excl(id)
  of yMapping:
    shape.types.incl(itObject)
    inc shape.objects
    let id = cast[pointer](node)
    if inference.onPath.containsOrIncl(id):
      # where a cycle closes, the object counts as one without members,
      # so that none of them is required of it
      return
    # a name that several keys spell (a, "a", !!str a) counts once
    var named: HashSet[string]
    for (name, value) in node.orderedMembers:
      let member = addr shape.members.mgetOrPut(name, Member(shape: newShape()))
      if not named.containsOrIncl(name): inc member.objects
      # the table may move while the value is added; its shape does not
      let memberShape = member.shape
      inference.addValue(memberShape, value)
    inference.onPath.excl(id)

proc add*(inference: var SchemaInference, document: YamlNode) =
  ## Adds ``document`` to the evidence.
  if inference.root.isNil: inference.root = newShape()
  inference.addValue(inference.root, document)
  inc inference.documents

# Writing the schema
#
# The schema is a ``YamlNode`` whose mappings are dumped in the order the
# keywords are added: their keys get increasing positions, which is the
# order ``orderedFields`` dumps by (from column 2, since a key at the
# default position 1:1 counts as having none). Strings are plain scalars,
# as a loaded schema has them, except those that would read as something
# else when plain (the type name ``null``, an enum value ``"80"``): these
# are quoted, so that the schema reads back as it was meant whichever way
# it is dumped.

proc text(s: string): YamlNode =
  if guessType(s) in {yTypeUnknown, yTypeTimestamp}: newYamlNode(s)
  else:
    # (newYamlNode takes a style, but does not keep it)
    YamlNode(kind: yScalar, content: s, tag: yTagExclamationMark,
        scalarStyle: ssDoubleQuoted)

proc keyword(name: string): YamlNode = text(name)

proc mapping(fields: seq[(YamlNode, YamlNode)]): YamlNode =
  for i, (key, _) in fields:
    key.startPos = Mark(line: 1, column: i + 2)
    key.endPos = key.startPos
  newYamlNode(fields)

proc typesOf(inference: SchemaInference, shape: Shape): seq[InstanceType] =
  for t in shape.types:
    # integers are numbers too
    if t == itInteger and itNumber in shape.types: continue
    result.add(t)

proc hasEnum(inference: SchemaInference, shape: Shape): bool =
  inference.options.enumLimit > 0 and not shape.manyValues and
      shape.types - {itNull} == {itString} and
      shape.strings >= 2 * shape.values.len

proc schemaOf(inference: SchemaInference, shape: Shape): YamlNode =
  var fields: seq[(YamlNode, YamlNode)]
  let types = inference.typesOf(shape)
  fields.add((keyword("type"),
      if types.len == 1: text($types[0])
      else:
        var names: seq[YamlNode]
        for t in types: names.add(text($t))
        newYamlNode(names)))
  if inference.hasEnum(shape):
    var values: seq[YamlNode]
    for value in shape.values: values.add(text(value))
    if itNull in shape.types: values.add(newYamlNode("null"))
    fields.add((keyword("enum"), newYamlNode(values)))
  elif shape.strings > 0 and shape.formats != {}:
    for format in shape.formats:
      fields.add((keyword("format"), text($format)))
      break
  if itObject in shape.types:
    if shape.members.len > 0:
      var properties: seq[(YamlNode, YamlNode)]
      for name, member in shape.members.pairs:
        properties.add((text(name), inference.schemaOf(member.shape)))
      fields.add((keyword("properties"), mapping(properties)))
    if inference.options.required:
      var names: seq[YamlNode]
      for name, member in shape.members.pairs:
        if member.objects == shape.objects: names.add(text(name))
      if names.len > 0: fields.add((keyword("required"), newYamlNode(names)))
    if not inference.options.additionalProperties:
      fields.add((keyword("additionalProperties"), newYamlNode("false")))
  if not shape.items.isNil:
    fields.add((keyword("items"), inference.schemaOf(shape.items)))
  mapping(fields)

proc toSchema*(inference: SchemaInference): YamlNode =
  ## The schema of the documents added so far, as a mapping that starts
  ## with ``$schema``. Without documents, it has nothing else, and accepts
  ## anything.
  var fields = @[(keyword("$schema"), text(draft2020Uri))]
  if not inference.root.isNil:
    for (key, value) in inference.schemaOf(inference.root).orderedFields:
      fields.add((key, value))
  mapping(fields)

proc inferSchema*(documents: openArray[YamlNode],
    options = InferenceOptions()): YamlNode =
  ## The schema of ``documents``; see ``toSchema``.
  var inference = initSchemaInference(options)
  for document in documents: inference.add(document)
  inference.toSchema()

proc schemaText*(schema: YamlNode): string =
  ## ``schema`` as YAML in block style, the way this module orders it.
  var dumper = blockOnlyDumper()
  dumper.serialization.tagStyle = tsNone
  dumper.dump(schema)
