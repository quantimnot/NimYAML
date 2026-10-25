#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ====================
## Module yaml/portable
## ====================
##
## Rewrites YAML that uses NimYAML's ``%GLOBAL`` directive into YAML that
## every YAML 1.2 processor reads the same way.
##
## Other processors ignore ``%GLOBAL`` and ``%SCHEMA``, as the specification
## tells them to (§6.8). For ``%GLOBAL SCHEMA`` that only loses information,
## but for ``%GLOBAL TAG`` it changes the meaning: a later document's
## ``!e!thing`` refers to a handle that, to them, was never declared, so
## they reject the document. `expandDirectives` therefore writes the global
## directives into every document that inherits them, as the plain
## ``%YAML``, ``%TAG`` and ``%SCHEMA`` directives they stand for, and
## removes the ``%GLOBAL`` lines:
##
## .. code-block:: yaml
##   %GLOBAL TAG !e! tag:example.com,2000:        %TAG !e! tag:example.com,2000:
##   --- !e!a 1                            →      --- !e!a 1
##   ...                                          ...
##   --- !e!b 2                                   %TAG !e! tag:example.com,2000:
##                                                --- !e!b 2
##
## A directive a document overrides (its own ``%TAG`` for the same handle,
## its own ``%YAML`` or ``%SCHEMA``) is not written. Since directives may
## only start a document after a ``...`` and must end with ``---`` (§9.2),
## those markers are added where a document gains directives without having
## them. With ``schemas = soModeline``, ``%SCHEMA`` directives become
## ``# yaml-language-server: $schema=...`` modelines, which editors
## understand, so that no NimYAML directive is left at all; except those
## that name several schemas, since a modeline names one.
##
## The rewrite works on the text, line by line, rather than by re-presenting
## the parsed events, because re-presenting would lose comments, styles and
## layout that the author chose; here only directive lines change. Schema
## references are kept as written: relative ones stay relative to the
## document's location, which the output presumably shares.

import std/strutils
import data, parser, stream

type
  SchemaOutput* = enum
    soDirective ## keep ``%SCHEMA`` (and expand ``%GLOBAL SCHEMA`` into it)
    soModeline  ## write the effective schema as a modeline comment instead,
                ## if there is only one

  ExpandOptions* = object
    schemas*: SchemaOutput = soDirective

  DocumentInfo = object
    start: YamlDocumentStart
    marker: int         ## line of the `---` marker, 0 for a bare document
    ended: bool         ## whether the document ends with `...`
    directives: DocumentDirectives

const modelinePrefix* = "# yaml-language-server: $schema="

proc documentsOf(source: string, sourceUri: string): seq[DocumentInfo] =
  # References are only copied, never resolved, so a placeholder base keeps
  # relative ones from being reported as unresolvable when the source has
  # no URI.
  let base = if sourceUri.len > 0: sourceUri else: "file:///"
  let events = initYamlParser(sourceUri = base).parse(source)
  try:
    for e in events:
      case e.kind
      of yamlStartDoc:
        result.add(DocumentInfo(start: events.documentStart,
            marker: if e.explicitDirectivesEnd: int(e.startPos.line) else: 0,
            directives: e.directives))
      of yamlEndDoc: result[^1].ended = e.explicitDocumentEnd
      else: discard
  except YamlStreamError as e:
    if e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    raise e
  except ValueError as e:
    # documentStart only fails for streams that do not come from a parser
    raise newException(YamlStreamError, e.msg)

proc directiveLines(directives: seq[Directive], schemas: SchemaOutput):
    seq[string] =
  ## The lines that declare ``directives``: those from one ``%SCHEMA`` line
  ## (with the same start) on one line again.
  var i = 0
  while i < directives.len:
    let d = directives[i]
    case d.kind
    of dkYaml: result.add("%YAML " & d.version)
    of dkTag: result.add("%TAG " & d.handle & " " & d.prefix)
    of dkSchema:
      var references = @[d.reference]
      while i + 1 < directives.len and directives[i + 1].kind == dkSchema and
          directives[i + 1].startPos == d.startPos:
        inc(i)
        references.add(directives[i].reference)
      if schemas == soModeline and references.len == 1:
        result.add(modelinePrefix & d.reference)
      else: result.add("%SCHEMA " & references.join(" "))
    inc(i)

proc isDirective(text, name: string): bool =
  ## Whether the line ``text`` is the directive ``%name``.
  text.startsWith("%" & name) and
      (text.len == name.len + 1 or text[name.len + 1] in {' ', '\t', '#'})

proc expandDirectives*(source: string, options = ExpandOptions(),
    sourceUri = ""): string {.raises: [YamlParserError, YamlStreamError].} =
  ## Returns ``source`` with its global directives expanded into every
  ## document, as described in the module documentation. Raises
  ## `YamlParserError` if ``source`` is not valid YAML.
  let docs = documentsOf(source, sourceUri)
  let newline = if "\r\n" in source: "\r\n" else: "\n"
  # the directives each document gains, and whether it needs markers
  var inserted = newSeq[seq[string]](docs.len)
  for i, doc in docs:
    if doc.directives.isNil: continue
    var globals: seq[Directive]
    for d in doc.directives.declarations:
      if d.origin == doGlobal and not d.overridden: globals.add(d)
    inserted[i] = globals.directiveLines(options.schemas)
  var line = 0
  var pos = 0
  var current = -1 # index of the document whose directive block we are in
  while pos < source.len:
    inc(line)
    var stop = source.find('\n', pos)
    let next = if stop < 0: source.len else: stop + 1
    if stop < 0: stop = source.len
    var text = source[pos ..< stop]
    if text.endsWith('\r'): text.setLen(text.len - 1)
    # the start of a document: write what it gains
    for i, doc in docs:
      if doc.start.line == line:
        current = i
        if inserted[i].len > 0:
          # a document that already has directives already follows a
          # `...`; one that only had `---` may not
          let hasOwnDirectives = doc.marker > doc.start.line
          if i > 0 and not docs[i - 1].ended and not hasOwnDirectives:
            result.add("..." & newline)
          for directive in inserted[i]: result.add(directive & newline)
          if doc.marker == 0: result.add("---" & newline)
    let inBlock = current >= 0 and docs[current].marker > 0 and
        line < docs[current].marker
    if inBlock and text.isDirective("GLOBAL"):
      discard # expanded above
    elif inBlock and options.schemas == soModeline and
        text.isDirective("SCHEMA"):
      var params = text["%SCHEMA".len .. ^1].strip().splitWhitespace()
      for j, p in params:
        if p.startsWith('#'):
          params.setLen(j)
          break
      if params.len == 1: result.add(modelinePrefix & params[0] & newline)
      elif params.len > 1: result.add(source[pos ..< next])
    else:
      result.add(source[pos ..< next])
    pos = next
