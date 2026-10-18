#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests yaml/hyperschema with the examples of the JSON Hyper-Schema
# specification (draft 2019-09, Section 9), written in YAML. There is no
# official test suite for JSON Hyper-Schema.

import std/[algorithm, unittest]
import "../yaml", "../yaml/dom", "../yaml/jsonschema", "../yaml/hyperschema"

proc y(s: string): YamlNode = loadAs[YamlNode](s)

type Summary = tuple[contextUri, contextPointer, rel, target, attachment: string]

proc summary(links: seq[Link]): seq[Summary] =
  for l in links:
    result.add((l.contextUri, l.contextPointer, l.rel,
        (if l.acceptsInput: "<input>" else: l.targetUri), l.attachmentPointer))
  result.sort()

proc sorted(s: seq[Summary]): seq[Summary] =
  result = s
  result.sort()

let registry = newSchemaRegistry()

registry.addSchema(y("""
$id: https://schema.example.com/entry
$schema: https://json-schema.org/draft/2019-09/hyper-schema
base: https://example.com/api/
links:
  - {rel: self, href: ../api}
  - {rel: about, href: docs}
  - rel: tag:rel.example.com,2017:thing
    href: things/{id}
    hrefSchema:
      required: [id]
      properties:
        id: {$ref: thing#/$defs/id}
    targetSchema: {$ref: thing#}
  - rel: tag:rel.example.com,2017:thing-collection
    href: /things{?offset,limit}
    hrefSchema: {$ref: thing-collection#/$defs/pagination}
    submissionSchema: {$ref: thing#}
    targetSchema: {$ref: thing-collection#}
"""))

registry.addSchema(y("""
$id: https://schema.example.com/thing
$schema: https://json-schema.org/draft/2019-09/hyper-schema
base: https://example.com/api/
type: object
required: [data]
properties:
  id: {$ref: '#/$defs/id'}
  data: true
links:
  - rel: self
    href: things/{id}
    templateRequired: [id]
    targetSchema: {$ref: '#'}
  - rel: collection
    href: /things
    targetSchema: {$ref: thing-collection#}
    submissionSchema: {$ref: '#'}
$defs:
  id: {type: integer, minimum: 1, readOnly: true}
"""))

registry.addSchema(y("""
$id: https://schema.example.com/thing-collection
$schema: https://json-schema.org/draft/2019-09/hyper-schema
base: https://example.com/api/
type: object
required: [elements]
properties:
  elements:
    type: array
    items:
      allOf: [{$ref: thing#}]
      links:
        - anchorPointer: ""
          rel: item
          href: things/{id}
          templateRequired: [id]
          targetSchema: {$ref: thing#}
  meta:
    type: object
    properties:
      prev: {$ref: '#/$defs/pagination'}
      current: {$ref: '#/$defs/pagination'}
      next: {$ref: '#/$defs/pagination'}
links:
  - rel: self
    href: things{?offset,limit}
    templateRequired: [offset, limit]
    templatePointers: {offset: /meta/current/offset, limit: /meta/current/limit}
    targetSchema: {$ref: '#'}
  - rel: prev
    href: things{?offset,limit}
    templateRequired: [offset, limit]
    templatePointers: {offset: /meta/prev/offset, limit: /meta/prev/limit}
    targetSchema: {$ref: '#'}
  - rel: next
    href: things{?offset,limit}
    templateRequired: [offset, limit]
    templatePointers: {offset: /meta/next/offset, limit: /meta/next/limit}
    targetSchema: {$ref: '#'}
$defs:
  pagination:
    type: object
    properties:
      offset: {type: integer, minimum: 0, default: 0}
      limit: {type: integer, minimum: 1, maximum: 100, default: 10}
"""))

suite "JSON Hyper-Schema (specification examples)":
  test "9.1 entry point links":
    let found = registry.compile("https://schema.example.com/entry").links(
        y("{}"), "https://example.com/api")
    check found.summary == sorted(@[
      ("https://example.com/api", "", "self", "https://example.com/api", ""),
      ("https://example.com/api", "", "about", "https://example.com/api/docs", ""),
      ("https://example.com/api", "", "tag:rel.example.com,2017:thing", "<input>", ""),
      ("https://example.com/api", "", "tag:rel.example.com,2017:thing-collection",
       "<input>", "")])

  test "9.2 links that accept input":
    let found = registry.compile("https://schema.example.com/entry").links(
        y("{}"), "https://example.com/api")
    let thing = found[2]
    check thing.rel == "tag:rel.example.com,2017:thing"
    check thing.hrefInputTemplates == @["things/{id}", "https://example.com/api/"]
    check thing.hrefPrepopulatedInput.len == 0
    check thing.resolveTarget(y("{id: 5}")) == "https://example.com/api/things/5"
    expect HyperSchemaError:
      discard thing.resolveTarget(y("{id: 0}"))   # minimum: 1
    expect HyperSchemaError:
      discard thing.resolveTarget(y("{}"))        # required
    let collection = found[3]
    check collection.resolveTarget(y("{offset: 20, limit: 10}")) ==
        "https://example.com/things?offset=20&limit=10"
    check collection.resolveTarget(y("{}")) == "https://example.com/things"

  test "9.2 individually identified resources":
    let thing = registry.compile("https://schema.example.com/thing")
    let found = thing.links(y("{id: 12345, data: {}}"),
        "https://example.com/api/things/12345")
    check found.summary == sorted(@[
      ("https://example.com/api/things/12345", "", "self",
       "https://example.com/api/things/12345", ""),
      ("https://example.com/api/things/12345", "", "collection",
       "https://example.com/things", "")])
    # without an id, the self link is not usable
    check thing.links(y("{data: 1}"), "https://example.com/api/things").len == 1

  test "9.3 submitting a payload and accepting URI input":
    let schema = registry.compile(y("""
$id: https://schema.example.com/interesting-stuff
$schema: https://json-schema.org/draft/2019-09/hyper-schema
required: [stuffWorthEmailingAbout, email, title]
properties:
  title: {type: string}
  stuffWorthEmailingAbout: {type: string}
  email: {type: string, format: email}
  cc: false
links:
  - rel: author
    href: mailto:{email}?subject={title}{&cc}
    templateRequired: [email]
    hrefSchema:
      required: [title]
      properties:
        title: {type: string}
        cc: {type: string, format: email}
        email: false
    submissionMediaType: multipart/alternative; boundary=ab2
    submissionSchema:
      type: array
      items:
        - {type: string, contentMediaType: text/plain; charset=utf8}
        - {type: string, contentMediaType: text/html}
      minItems: 2
"""))
    let found = schema.links(y("""
title: The Awesome Thing
stuffWorthEmailingAbout: Lots of text here...
email: someone@example.com
"""), "https://example.com/api/stuff")
    check found.len == 1
    let link = found[0]
    check link.contextUri == "https://example.com/api/stuff"
    check link.acceptsInput
    # RFC 6570 encodes '@' in simple expansion; the specification's example
    # shows it unencoded, which would need {+email}
    check link.hrefInputTemplates ==
        @["mailto:someone%40example.com?subject={title}{&cc}"]
    check link.hrefPrepopulatedInput["title"].content == "The Awesome Thing"
    check link.hrefPrepopulatedInput.len == 1
    check link.resolveTarget(y("{title: The Awesome Thing}")) ==
        "mailto:someone%40example.com?subject=The%20Awesome%20Thing"
    check link.resolveTarget(y("{title: your work, cc: other@elsewhere.org}")) ==
        "mailto:someone%40example.com?subject=your%20work&cc=other%40elsewhere.org"
    expect HyperSchemaError:
      discard link.resolveTarget(y("{title: x, email: a@b.c}"))
    let output = toYaml(found)
    check output[0]["rel"].content == "author"
    check output[0]["submissionMediaType"].content ==
        "multipart/alternative; boundary=ab2"
    check not output[0].hasKey("targetUri")

  test "9.4 anchor, base and URI Template resolution":
    let schema = registry.compile(y("""
$id: https://schema.example.com/tree-node
$schema: https://json-schema.org/draft/2019-09/hyper-schema
base: trees/{treeId}/
properties:
  id: {type: integer}
  treeId: {type: integer}
  childIds:
    type: array
    items:
      type: integer
      links:
        - anchor: nodes/{thisNodeId}
          rel: up
          href: nodes/{childId}
          templatePointers: {thisNodeId: /id, childId: "0"}
links:
  - {rel: self, href: "nodes/{id}"}
"""))
    let found = schema.links(y("{id: 123, treeId: 1, childIds: [456]}"),
        "https://example.com/api/")
    check found.summary == sorted(@[
      ("https://example.com/api/", "", "self",
       "https://example.com/api/trees/1/nodes/123", ""),
      ("https://example.com/api/trees/1/nodes/123", "/childIds/0", "up",
       "https://example.com/api/trees/1/nodes/456", "/childIds/0")])

  test "9.5 collections":
    let found = registry.compile("https://schema.example.com/thing-collection").links(
        y("{elements: [{id: 12345, data: {}}, {id: 67890, data: {}}]}"),
        "https://example.com/api/things")
    let c = "https://example.com/api/things"
    # without meta/current, the collection's self link is not usable
    check found.summary == sorted(@[
      (c, "/elements/0", "self", c & "/12345", "/elements/0"),
      (c, "/elements/1", "self", c & "/67890", "/elements/1"),
      (c, "", "item", c & "/12345", "/elements/0"),
      (c, "", "item", c & "/67890", "/elements/1"),
      (c, "/elements/0", "collection", "https://example.com/things", "/elements/0"),
      (c, "/elements/1", "collection", "https://example.com/things", "/elements/1")])
    # links attached to array elements come in array order
    let items = found.linksAt("")
    check items.len == 2
    check items[0].targetUri == c & "/12345" and items[1].targetUri == c & "/67890"

  test "9.5.1 pagination":
    let found = registry.compile("https://schema.example.com/thing-collection").links(y("""
elements: [{id: 12345, data: {}}, {id: 67890, data: {}}]
meta:
  current: {offset: 0, limit: 2}
  next: {offset: 3, limit: 2}
"""), "https://example.com/api/things")
    var root: seq[(string, string)]
    for l in found.linksAt(""):
      if l.attachmentPointer == "": root.add((l.rel, l.targetUri))
    root.sort()
    check root == @[
      ("next", "https://example.com/api/things?offset=3&limit=2"),
      ("self", "https://example.com/api/things?offset=0&limit=2")]

suite "JSON Hyper-Schema":
  test "pointer fragments in context URIs":
    let found = registry.compile("https://schema.example.com/thing-collection").links(
        y("{elements: [{id: 1, data: 0}]}"), "https://example.com/api/things",
        pointerFragments = true)
    for l in found:
      if l.rel == "self": check l.contextUri == "https://example.com/api/things#/elements/0"

  test "relative pointers and keys":
    let schema = compile(y("""
$schema: https://json-schema.org/draft/2020-12/hyper-schema
properties:
  items:
    additionalProperties:
      links:
        - rel: item
          href: "/items/{key}?parent={parent}&next={next}"
          templatePointers: {key: "0#", parent: "2/name", next: "0/next"}
"""))
    let found = schema.links(y("{name: top, items: {a: {next: b}}}"), "https://x.example/")
    check found.len == 1
    check found[0].targetUri == "https://x.example/items/a?parent=top&next=b"
    check found[0].attachmentPointer == "/items/a"

  test "multiple relation types":
    let schema = compile(y("""
$schema: https://json-schema.org/draft/2020-12/hyper-schema
links: [{rel: [self, canonical], href: "https://example.com/x"}]
"""))
    var rels: seq[string]
    for l in schema.links(y("{}")): rels.add(l.rel)
    check rels == @["self", "canonical"]

  test "invalid instances have no links":
    let schema = compile(y("""
$schema: https://json-schema.org/draft/2020-12/hyper-schema
type: object
links: [{rel: self, href: "https://example.com/x"}]
"""))
    check schema.links(y("[]")).len == 0
    check schema.links(y("{}")).len == 1

  test "malformed links":
    let schema = compile(y("""
$schema: https://json-schema.org/draft/2020-12/hyper-schema
links: [{rel: self}]
"""))
    expect HyperSchemaError:
      discard schema.links(y("{}"))

  test "the meta-schema validates hyper-schemas":
    let meta = newSchemaRegistry().compile("https://json-schema.org/draft/2020-12/hyper-schema")
    check meta.isValid(y("{links: [{rel: self, href: x}]}"))
    check not meta.isValid(y("{links: [{rel: self}]}"))
    check not meta.isValid(y("{base: 1}"))

  test "README example":
    let schema = compile(y("""
$schema: https://json-schema.org/draft/2020-12/hyper-schema
base: https://example.com/api/
links:
  - {rel: self, href: "things/{id}", templateRequired: [id]}
  - rel: search
    href: "things{?q}"
    hrefSchema: {properties: {q: {type: string}}}
"""))
    var output: seq[string]
    for link in schema.links(y("{id: 12345}"), "https://example.com/api/things/12345"):
      if link.acceptsInput:
        output.add(link.rel & " " & link.resolveTarget(y("{q: bolts}")))
      else:
        output.add(link.rel & " " & link.targetUri)
    check output == @["self https://example.com/api/things/12345",
        "search https://example.com/api/things?q=bolts"]
