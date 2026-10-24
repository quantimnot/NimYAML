#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ======================
## Module yaml/mergepatch
## ======================
##
## Applies `JSON Merge Patches <https://www.rfc-editor.org/rfc/rfc7396>`_
## (RFC 7396) to YAML representation graphs. A merge patch looks like the
## document it changes: its members replace those of the document, members
## that are objects in both are merged recursively, and a ``null`` member
## removes one:
##
## .. code-block:: nim
##
##   import yaml, yaml/[dom, mergepatch]
##
##   let
##     config = loadAs[YamlNode]("{server: {host: a, port: 80}, debug: true}")
##     patch = loadAs[YamlNode]("{server: {port: 8080}, debug: null}")
##   echo dump(config.applyMergePatch(patch))
##   # {server: {host: a, port: 8080}}
##
## Merge patches are simpler to write than `JSON Patches <jsonpatch.html>`_
## but less capable: they cannot set a member to ``null``, and they replace
## sequences as a whole rather than changing their items. ``createMergePatch``
## computes the patch that turns one document into another.
##
## Like ``applyJsonPatch``, ``applyMergePatch`` never changes its input: it
## copies the mappings it changes, and the result shares everything else
## with the target and the patch. Members are found by name the way
## `yaml/jsonpatch <jsonpatch.html>`_ finds them: only string keys name
## members, a changed member keeps its key node, and a removed member loses
## all keys that spell its name. Mapping keys that are not strings are
## invisible to the patch and stay in the result.
##
## A merge patch can never fail; RFC 7396 defines a result for every target
## and patch.

import std/tables
import data, dom, private/jsonmodel

proc copyMapping(node: YamlNode): YamlNode =
  result = YamlNode(kind: yMapping, tag: node.tag,
      fields: newTable[YamlNode, YamlNode](), mapStyle: node.mapStyle,
      startPos: node.startPos, endPos: node.endPos)
  for key, value in node.fields.pairs: result.fields[key] = value

proc emptyMapping(): YamlNode =
  YamlNode(kind: yMapping, tag: yTagQuestionMark,
      fields: newTable[YamlNode, YamlNode]())

proc applyMergePatch*(target, patch: YamlNode): YamlNode {.raises: [].} =
  ## Returns ``target`` changed by the merge patch ``patch``, following the
  ## algorithm of RFC 7396, Section 2. A ``patch`` that is not a mapping
  ## replaces ``target``; a ``target`` that is not a mapping is treated as
  ## an empty one.
  ##
  ## Nested patch members are applied with the same algorithm even where
  ## ``target`` has nothing to merge them into, so ``null`` members of a
  ## newly added mapping are dropped, as RFC 7396 requires.
  if patch.kind != yMapping: return patch
  result =
    if target.kind == yMapping: copyMapping(target)
    else: emptyMapping()
  for (name, value) in patch.orderedMembers:
    if value.jsonKind == jkNull:
      discard result.removeMember(name)
    else:
      let current = result.member(name)
      result.setMember(name, applyMergePatch(
          if isNil(current): emptyMapping() else: current, value))

proc nullNode(): YamlNode =
  YamlNode(kind: yScalar, tag: yTagNull, content: "null")

proc createMergePatch*(source, target: YamlNode): YamlNode {.raises: [].} =
  ## Returns a merge patch that turns ``source`` into ``target``, so that
  ## ``source.applyMergePatch(createMergePatch(source, target))`` equals
  ## ``target`` as JSON. Unchanged members are left out, and mappings in
  ## both are compared recursively.
  ##
  ## Not every change can be expressed: a ``null`` member of a mapping in
  ## ``target`` would be read as a removal. The patch then sets no such
  ## member, so the result lacks it. RFC 7396 recommends JSON Patch where
  ## this matters.
  if source.kind != yMapping or target.kind != yMapping:
    return target
  result = emptyMapping()
  for (name, value) in target.orderedMembers:
    let old = source.member(name)
    if isNil(old):
      if value.jsonKind != jkNull: result.setMember(name, value)
    elif not jsonEquals(old, value):
      if value.jsonKind == jkNull: result.setMember(name, nullNode())
      else: result.setMember(name, createMergePatch(old, value))
  for name, _ in source.members:
    if isNil(target.member(name)): result.setMember(name, nullNode())
