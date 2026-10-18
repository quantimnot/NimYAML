#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =======================
## Module yaml/hyperschema
## =======================
##
## Discovers and resolves the links that a `JSON Hyper-Schema
## <https://json-schema.org/draft/2019-09/json-schema-hypermedia>`_
## (draft 2019-09, also used with 2020-12) describes for an instance.
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, jsonschema, hyperschema]
##
##   let schema = compile(loadAs[YamlNode]("""
##   $schema: https://json-schema.org/draft/2020-12/hyper-schema
##   base: https://example.com/api/
##   links:
##     - {rel: self, href: "things/{id}", templateRequired: [id]}
##   """))
##   for link in schema.links(loadAs[YamlNode]("{id: 12345}"),
##       "https://example.com/api/things/12345"):
##     echo link.rel, " ", link.targetUri
##     # self https://example.com/api/things/12345
##
## ``links`` applies the hyper-schema to the instance with
## ``yaml/jsonschema`` and collects the Link Description Objects (LDOs) of
## all subschemas that apply to some part of the instance and validate it,
## each attached to the location it applies to. For every LDO (and every
## relation type of it), it resolves the URI Templates of ``href``,
## ``anchor`` and the applicable ``base`` values (with
## ``yaml/uritemplate``), taking variable values from the instance as
## ``templatePointers`` direct, and computes the fields of the output
## format of the specification (Section 7): ``contextUri``,
## ``contextPointer``, ``rel``, ``targetUri``, ``attachmentPointer`` and,
## for links that accept input, ``hrefInputTemplates`` and
## ``hrefPrepopulatedInput``. ``toYaml`` renders a list of links in that
## format.
##
## Links whose ``templateRequired`` variables have no value are not usable
## and therefore left out. Links that accept client input (through
## ``hrefSchema``) have no ``targetUri`` yet; ``resolveTarget`` validates the
## input against ``hrefSchema`` and computes it.
##
## Notes on the specification:
##
## * The instance has no fragment identifier syntax unless
##   ``pointerFragments`` is enabled (``application/yaml`` and
##   ``application/schema-instance+json`` have one; ``application/json``
##   does not). Without it, a context that is not the whole instance is only
##   identified by ``contextPointer``.
## * Variables of a ``base`` template that ``templatePointers`` does not
##   cover are looked up where the schema containing ``base`` applies, not
##   where the link is attached. Section 6.4 of the specification says
##   otherwise, but then its own example in Section 9.4 (``base:
##   trees/{treeId}/`` with links attached to array items) could not
##   resolve.
## * An instance that is not valid against the hyper-schema as a whole has
##   no links, since annotations of failing schemas are discarded.

import std/[strutils, tables]
import dom, data, fragment, jsonschema, uritemplate,
    private/[jsonmodel, uri]

type
  HyperSchemaError* = object of ValueError
    ## Raised when a link description object is malformed, or when client
    ## input cannot be used for a link.

  BaseTemplate = object
    ## A ``base`` value and the data to resolve it with.
    source: UriTemplate
    data: TemplateVars

  Link* = object
    ## A link of an instance, as resolved from a Link Description Object.
    contextUri*: string
    contextPointer*: string
    rel*: string
    targetUri*: string
      ## the resolved target; empty for links that accept input
    hrefInputTemplates*: seq[string]
      ## for links that accept input: ``href`` and the ``base`` values it
      ## is resolved against, as far as they could be resolved without input
    hrefPrepopulatedInput*: YamlNode
      ## for links that accept input: the initial input from the instance,
      ## a mapping; ``nil`` otherwise
    attachmentPointer*: string
    ldo*: YamlNode ## the Link Description Object
    acceptsInput*: bool
    # what resolveTarget needs
    hyperSchema: JsonSchema
    instanceUri: string
    href: UriTemplate
    data: TemplateVars
    inputVariables: seq[string]
    bases: seq[BaseTemplate] ## from the root inwards

  Context = object
    root: YamlNode
    schema: JsonSchema
    instanceUri: string
    pointerFragments: bool
    links: seq[Link]

proc hyperError(msg: string): ref HyperSchemaError =
  newException(HyperSchemaError, msg)

proc stringMember(ldo: YamlNode, name: string, value: var string): bool =
  let node = ldo.member(name)
  if node.isNil: return false
  if node.jsonKind != jkString:
    raise hyperError("LDO keyword " & name & " must be a string")
  value = node.content
  result = true

proc escapeToken(token: string): string =
  token.multiReplace(("~", "~0"), ("/", "~1"))

proc number(s: string): int =
  try: result = parseInt(s)
  except ValueError: raise hyperError("number out of range: " & s)

proc relativeToAbsolute(attachment, relative: string): string =
  ## Applies the Relative JSON Pointer ``relative`` (without ``#``) to the
  ## location ``attachment``, yielding a JSON Pointer.
  var tokens = if attachment.len == 0: newSeq[string]()
               else: attachment[1 .. ^1].split('/')
  var i = 0
  while i < relative.len and relative[i] in Digits: inc(i)
  if i == 0: raise hyperError("invalid Relative JSON Pointer " & relative)
  let up = number(relative[0 ..< i])
  if up > tokens.len:
    raise hyperError("Relative JSON Pointer " & relative &
        " goes above the root from " & attachment)
  tokens.setLen(tokens.len - up)
  if i < relative.len and relative[i] in {'+', '-'}:
    let negative = relative[i] == '-'
    inc(i)
    let start = i
    while i < relative.len and relative[i] in Digits: inc(i)
    if tokens.len == 0 or i == start:
      raise hyperError("invalid index manipulation in " & relative)
    var index: int
    try: index = parseInt(tokens[^1])
    except ValueError:
      raise hyperError("index manipulation on a non-index in " & relative)
    let offset = number(relative[start ..< i])
    tokens[^1] = $(if negative: index - offset else: index + offset)
  let rest = relative[i .. ^1]
  if rest.len > 0 and rest[0] != '/':
    raise hyperError("invalid Relative JSON Pointer " & relative)
  result = ""
  for t in tokens: result.add("/" & t)
  result.add(rest)

proc isRelative(pointer: string): bool =
  pointer.len > 0 and pointer[0] in Digits

proc valueAt(c: Context, pointer: string, value: var TemplateValue): bool =
  try:
    value = templateValue(resolvePointer(c.root, pointer))
    result = true
  except YamlFragmentError: result = false

proc populate(c: Context, t: UriTemplate, ldo: YamlNode,
    attachment, defaultLocation: string): TemplateVars =
  ## Section 7.2.1: values from ``templatePointers``, else from the member
  ## named like the variable at ``defaultLocation``.
  result = initTable[string, TemplateValue]()
  let pointers = ldo.member("templatePointers")
  for name in t.variables:
    let decoded = percentDecode(name)
    var pointer: string
    let given = not pointers.isNil and pointers.kind == yMapping and
        not pointers.member(decoded).isNil
    if given:
      pointer = pointers.member(decoded).content
      if pointer.isRelative:
        if pointer.endsWith("#"):
          try:
            let r = resolveRelativePointer(c.root, attachment, pointer)
            case r.kind
            of rprKey: result[name] = tv(r.key)
            of rprIndex: result[name] = tv($r.index)
            of rprNode: discard
          except YamlFragmentError: discard
          continue
        pointer = relativeToAbsolute(attachment, pointer)
    else: pointer = defaultLocation & "/" & escapeToken(decoded)
    var value: TemplateValue
    if c.valueAt(pointer, value): result[name] = value

proc parseTemplate(source: string): UriTemplate =
  try: result = parseUriTemplate(source)
  except UriTemplateError as e: raise hyperError(e.msg)

proc expandOrFail(t: UriTemplate, data: TemplateVars): string =
  try: result = t.expand(data)
  except UriTemplateError as e: raise hyperError(e.msg)

proc resolveBases(instanceUri: string, bases: seq[BaseTemplate],
    input: TemplateVars, inputVariables: seq[string]): string =
  ## The base URI the bases resolve to, innermost last.
  result = instanceUri
  for b in bases:
    var data = b.data
    for name in inputVariables:
      if input.hasKey(name): data[name] = input.getOrDefault(name)
      elif data.hasKey(name): data.del(name)
    result = resolve(result, expandOrFail(b.source, data))

proc hasValue(data: TemplateVars, name: string): bool =
  if not data.hasKey(name): return false
  let v = data.getOrDefault(name)
  result = case v.kind
    of tvString: true
    of tvList: v.list.len > 0
    of tvMap: v.pairs.len > 0

proc falseSchemaAt(u: OutputUnit, location: string): bool =
  ## Whether a ``false`` schema applied to ``location`` in this tree.
  if u.kind == oukSchema and not u.valid and u.children.len == 0 and
      u.instanceLocation == location:
    return true
  for child in u.children:
    if child.falseSchemaAt(location): return true
  result = false

proc failsAt(u: OutputUnit, location: string): bool =
  ## Whether some assertion failed at ``location`` or below.
  if not u.valid and u.kind == oukKeyword and u.error.len > 0 and
      (u.instanceLocation == location or
       u.instanceLocation.startsWith(location & "/")):
    return true
  for child in u.children:
    if not child.valid and child.failsAt(location): return true
  result = false

proc encodeFragment(pointer: string): string =
  const allowed = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '!', '$',
      '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?'}
  for ch in pointer:
    if ch in allowed: result.add(ch)
    else: result.add('%' & toHex(ord(ch), 2))

proc addLinks(c: var Context, ldo: YamlNode, attachment: string,
    bases: seq[tuple[source, attachment: string]]) =
  if ldo.kind != yMapping: raise hyperError("a link must be an object")
  var hrefSource: string
  if not ldo.stringMember("href", hrefSource):
    raise hyperError("a link must have href")
  let relNode = ldo.member("rel")
  var rels: seq[string]
  if not relNode.isNil and relNode.jsonKind == jkString: rels = @[relNode.content]
  elif not relNode.isNil and relNode.kind == ySequence:
    for r in relNode.elems:
      if r.jsonKind != jkString: raise hyperError("rel must contain strings")
      rels.add(r.content)
  if rels.len == 0: raise hyperError("a link must have rel")

  var required: seq[string]
  let requiredNode = ldo.member("templateRequired")
  if not requiredNode.isNil and requiredNode.kind == ySequence:
    for r in requiredNode.elems: required.add(r.content)

  let href = parseTemplate(hrefSource)
  var baseTemplates: seq[BaseTemplate]
  for b in bases:
    let t = parseTemplate(b.source)
    baseTemplates.add(BaseTemplate(source: t,
        data: c.populate(t, ldo, attachment, b.attachment)))
  let data = c.populate(href, ldo, attachment, attachment)

  # Section 7.2.2: which variables accept input, which are pre-populated
  var
    inputVariables: seq[string]
    prepopulated: seq[(YamlNode, YamlNode)]
  let hrefSchemaNode = ldo.member("hrefSchema")
  let acceptsAny = not hrefSchemaNode.isNil and
      not (hrefSchemaNode.jsonKind == jkBool and
           not hrefSchemaNode.jsonScalar.boolean)
  if acceptsAny:
    var hrefSchema: JsonSchema
    try: hrefSchema = c.schema.subschema(hrefSchemaNode)
    except JsonSchemaError as e: raise hyperError(e.msg)
    var names = href.variables
    for b in baseTemplates:
      for name in b.source.variables:
        if name notin names: names.add(name)
    for name in names:
      let decoded = percentDecode(name)
      var value: YamlNode = nil
      let pointer = attachment & "/" & escapeToken(decoded)
      try: value = resolvePointer(c.root, pointer)
      except YamlFragmentError: discard
      let probe = newYamlNode([(newYamlNode(decoded),
          if value.isNil: newYamlNode("null", yTagNull) else: value)])
      var tree: OutputUnit
      try: tree = hrefSchema.validate(probe).outputTree
      except JsonSchemaError as e: raise hyperError(e.msg)
      let location = "/" & escapeToken(decoded)
      if tree.falseSchemaAt(location): continue
      inputVariables.add(name)
      if not value.isNil and data.hasKey(name) and not tree.failsAt(location):
        prepopulated.add((newYamlNode(decoded), value))

  # required variables that cannot come from input must be there already
  for name in required:
    if name notin inputVariables and not data.hasValue(name): return

  var link = Link(ldo: ldo, attachmentPointer: attachment,
      hyperSchema: c.schema, instanceUri: c.instanceUri, href: href,
      data: data, inputVariables: inputVariables, bases: baseTemplates,
      acceptsInput: inputVariables.len > 0)

  # context (Section 6.1)
  var anchorSource: string
  if ldo.stringMember("anchor", anchorSource):
    let anchor = parseTemplate(anchorSource)
    let anchorData = c.populate(anchor, ldo, attachment, attachment)
    let base = resolveBases(c.instanceUri, baseTemplates,
        initTable[string, TemplateValue](), @[])
    link.contextUri = resolve(base, expandOrFail(anchor, anchorData))
  else: link.contextUri = c.instanceUri
  var anchorPointer: string
  if ldo.stringMember("anchorPointer", anchorPointer):
    link.contextPointer = if anchorPointer.isRelative:
        relativeToAbsolute(attachment, anchorPointer)
      else: anchorPointer
  else: link.contextPointer = attachment
  if c.pointerFragments and anchorSource.len == 0 and
      link.contextPointer.len > 0:
    link.contextUri = link.contextUri.withoutFragment & "#" &
        encodeFragment(link.contextPointer)

  # target (Section 6.3 and 7.2)
  if link.acceptsInput:
    var partialData = data
    let deferred = inputVariables
    var t: string
    try: t = href.expandPartially(partialData, deferred)
    except UriTemplateError as e: raise hyperError(e.msg)
    link.hrefInputTemplates.add(t)
    var absolute = t.isAbsolute
    for i in countdown(baseTemplates.high, 0):
      if absolute: break
      var b: string
      try: b = baseTemplates[i].source.expandPartially(baseTemplates[i].data,
          deferred)
      except UriTemplateError as e: raise hyperError(e.msg)
      link.hrefInputTemplates.add(b)
      absolute = b.isAbsolute
    link.hrefPrepopulatedInput = newYamlNode(prepopulated)
  else:
    let base = resolveBases(c.instanceUri, baseTemplates,
        initTable[string, TemplateValue](), @[])
    link.targetUri = resolve(base, expandOrFail(href, data))

  for rel in rels:
    link.rel = rel
    c.links.add(link)

proc walk(c: var Context, u: OutputUnit,
    bases: seq[tuple[source, attachment: string]]) =
  if not u.valid: return
  var bases = bases
  if u.kind == oukSchema:
    for k in u.children:
      if k.valid and k.keyword == "base" and not k.annotation.isNil and
          k.annotation.jsonKind == jkString:
        bases.add((k.annotation.content, u.instanceLocation))
    for k in u.children:
      if k.valid and k.keyword == "links" and not k.annotation.isNil and
          k.annotation.kind == ySequence:
        for ldo in k.annotation.elems:
          c.addLinks(ldo, u.instanceLocation, bases)
  for child in u.children: c.walk(child, bases)

proc links*(schema: JsonSchema, instance: YamlNode, instanceUri = "",
    pointerFragments = false, options = ValidationOptions()): seq[Link]
    {.raises: [HyperSchemaError, JsonSchemaError].} =
  ## Discovers all usable links of ``instance``, which was retrieved from
  ## ``instanceUri`` (the initial base URI and the default context URI).
  ## With ``pointerFragments``, context URIs identify a context that is not
  ## the whole instance with a JSON Pointer fragment.
  var c = Context(root: instance, schema: schema, instanceUri: instanceUri,
      pointerFragments: pointerFragments)
  let r = schema.validate(instance, options)
  if not r.valid: return @[]
  c.walk(r.outputTree, @[])
  result = c.links

proc linksAt*(links: seq[Link], contextPointer: string): seq[Link] =
  ## The links whose context is at ``contextPointer``.
  for link in links:
    if link.contextPointer == contextPointer: result.add(link)

proc resolveTarget*(link: Link, input: YamlNode): string
    {.raises: [HyperSchemaError, JsonSchemaError].} =
  ## Computes the target URI of a link that accepts input (Section 7.2.2):
  ## ``input``, a mapping from variable names to values, overrides the
  ## data from the instance and must be valid against ``hrefSchema``.
  ## Raises ``HyperSchemaError`` if it is not, if it supplies variables that
  ## do not accept input, or if a variable of ``templateRequired`` has no
  ## value.
  if input.kind != yMapping: raise hyperError("input must be a mapping")
  let hrefSchemaNode = link.ldo.member("hrefSchema")
  if not hrefSchemaNode.isNil:
    if not link.hyperSchema.subschema(hrefSchemaNode).isValid(input):
      raise hyperError("input is not valid against hrefSchema")
  var
    inputData = initTable[string, TemplateValue]()
    data = link.data
  for name, value in input.members:
    var variable = ""
    for v in link.inputVariables:
      if percentDecode(v) == name: variable = v
    if variable.len == 0:
      raise hyperError("variable " & name & " does not accept input")
    inputData[variable] = templateValue(value)
  for name in link.inputVariables:
    if inputData.hasKey(name): data[name] = inputData.getOrDefault(name)
    elif data.hasKey(name): data.del(name)
  let requiredNode = link.ldo.member("templateRequired")
  if not requiredNode.isNil and requiredNode.kind == ySequence:
    for r in requiredNode.elems:
      if not data.hasValue(r.content):
        raise hyperError("required variable " & r.content & " has no value")
  let base = resolveBases(link.instanceUri, link.bases, inputData,
      link.inputVariables)
  result = resolve(base, expandOrFail(link.href, data))

proc toYaml*(links: seq[Link]): YamlNode =
  ## Renders ``links`` in the output format of the specification, Section 7,
  ## with the LDO keywords not involved in resolution included as they are.
  var items: seq[YamlNode]
  for link in links:
    var fields = @[
      (newYamlNode("contextUri"), newYamlNode(link.contextUri, yTagString)),
      (newYamlNode("contextPointer"), newYamlNode(link.contextPointer, yTagString)),
      (newYamlNode("rel"), newYamlNode(link.rel, yTagString))]
    if link.acceptsInput:
      var templates: seq[YamlNode]
      for t in link.hrefInputTemplates: templates.add(newYamlNode(t, yTagString))
      fields.add((newYamlNode("hrefInputTemplates"), newYamlNode(templates)))
      fields.add((newYamlNode("hrefPrepopulatedInput"), link.hrefPrepopulatedInput))
    else:
      fields.add((newYamlNode("targetUri"), newYamlNode(link.targetUri, yTagString)))
    fields.add((newYamlNode("attachmentPointer"),
        newYamlNode(link.attachmentPointer, yTagString)))
    for name, value in link.ldo.members:
      if name notin ["anchor", "anchorPointer", "rel", "href", "hrefSchema",
          "templatePointers", "templateRequired"]:
        fields.add((newYamlNode(name), value))
    items.add(newYamlNode(fields))
  result = newYamlNode(items)
