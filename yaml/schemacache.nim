#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =======================
## Module yaml/schemacache
## =======================
##
## A cache of downloaded JSON Schemas, so that schemas from the network
## (``http:`` and ``https:``) need not be downloaded again, and validate
## without a network: by the ``yaml`` command line tool, which never
## downloads anything, too. NimYAML does not download; whoever does (the
## language server, from what the editor downloads) stores the schemas
## here.
##
## There are three locations, chosen with ``validate.schema-cache`` in the
## ``.yaml`` config (see `toolconfig <toolconfig.html>`_):
##
## ============ ==============================================================
## ``project``  ``.yaml-schemas`` next to the config file, to be committed
##              with the project, so that it validates the same everywhere
## ``user``     the user's cache directory (``getCacheDir("nimyaml")``,
##              which follows ``XDG_CACHE_HOME``), shared by all projects
##              (the default)
## ``system``   ``/var/cache/nimyaml/schemas`` (``/Library/Caches`` on macOS,
##              ``%ProgramData%`` on Windows), for an administrator to fill;
##              usually not writable for users
## ``off``      no cache
## ============ ==============================================================
##
## Schemas are written to the configured location and read from all of them,
## most specific first: the project's, the user's, the system's.
##
## A schema is stored as its text, in a file whose path is its URI's scheme,
## host and path, each segment percent-encoded where a file name could not
## hold it: ``https://www.schemastore.org/package.json`` is
## ``https/www.schemastore.org/package.json``. Only ``http:`` and ``https:``
## schemas are cached: others are no downloads, and VS Code's own
## (``vscode://schemas/...``) depend on the user's extensions and language.

import std/[os, strutils]
when defined(nimPreviewSlimSystem):
  import std/syncio
import dom, loading, jsonschema, schemavalidation

type
  SchemaCacheLocation* = enum
    sclOff = "off", sclProject = "project", sclUser = "user",
    sclSystem = "system"

const projectCacheDirName* = ".yaml-schemas"
  ## the project cache's directory, next to the config file

proc schemaCacheDir*(location: SchemaCacheLocation, configDir = ""): string =
  ## The directory of the cache ``location``; ``configDir`` is the directory
  ## of the config file, without which a project cache is the user's. Empty
  ## for ``off``.
  case location
  of sclOff: ""
  of sclProject:
    if configDir.len > 0: configDir / projectCacheDirName
    else: schemaCacheDir(sclUser)
  of sclUser: getCacheDir("nimyaml") / "schemas"
  of sclSystem:
    when defined(windows): getEnv("ProgramData", "C:\\ProgramData") /
        "nimyaml" / "cache" / "schemas"
    elif defined(macosx): "/Library/Caches/nimyaml/schemas"
    else: "/var/cache/nimyaml/schemas"

proc readDirs*(location: SchemaCacheLocation, configDir = ""): seq[string] =
  ## The caches schemas are read from, most specific first; none for
  ## ``off``.
  if location == sclOff: return
  if configDir.len > 0: result.add(schemaCacheDir(sclProject, configDir))
  result.add(schemaCacheDir(sclUser))
  result.add(schemaCacheDir(sclSystem))

proc encodeSegment(segment: string): string =
  ## ``segment`` as a file name: everything but unreserved characters
  ## percent-encoded, and ``.`` and ``..`` too, so that no path leaves the
  ## cache.
  if segment in [".", ".."]:
    for _ in segment: result.add("%2E")
    return
  for c in segment:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}: result.add(c)
    else: result.add('%' & toHex(ord(c), 2))

proc cachePath*(dir, uri: string): string =
  ## The file in the cache ``dir`` that holds the schema ``uri``; empty if
  ## ``uri`` is not one that is cached (or ``dir`` is empty).
  if dir.len == 0: return ""
  let colon = uri.find(':')
  if colon < 0: return ""
  let scheme = uri[0 ..< colon].toLowerAscii()
  if scheme notin ["http", "https"] or not uri[colon + 1 .. ^1].startsWith("//"):
    return ""
  var rest = uri[colon + 3 .. ^1]
  let hash = rest.find('#')
  if hash >= 0: rest.setLen(hash)
  var query = ""
  let question = rest.find('?')
  if question >= 0:
    query = rest[question .. ^1]
    rest.setLen(question)
  var segments = rest.split('/')
  segments[0] = segments[0].toLowerAscii() # the host
  if segments.len == 1 or segments[^1].len == 0:
    if segments.len > 1: segments.setLen(segments.len - 1)
    segments.add("index")
  segments[^1].add(query)
  result = dir / scheme
  for segment in segments:
    if segment.len > 0: result = result / encodeSegment(segment)

proc readCachedSchema*(dirs: seq[string], uri: string):
    tuple[found: bool, text: string] =
  ## The text of the schema ``uri`` from the first of the caches ``dirs``
  ## that has it.
  for dir in dirs:
    let path = cachePath(dir, uri)
    if path.len == 0 or not fileExists(path): continue
    try: return (true, readFile(path))
    except IOError: discard

proc storeSchema*(dir, uri, text: string): bool =
  ## Stores ``text`` as the schema ``uri`` in the cache ``dir``. Returns
  ## whether it was stored: a cache that cannot be written (the system's,
  ## usually) is not an error.
  let path = cachePath(dir, uri)
  if path.len == 0: return false
  try:
    createDir(path.parentDir())
    # write and rename, so that readers never see half a schema
    let partial = path & ".partial-" & $getCurrentProcessId()
    writeFile(partial, text)
    moveFile(partial, path)
    result = true
  except OSError, IOError:
    result = false

proc cachedSchemaLoader*(dirs: seq[string]): SchemaLoader =
  ## A loader that reads schemas from the caches ``dirs``, in YAML or JSON.
  result = proc(uri: string): YamlNode {.closure, raises: [CatchableError].} =
    let (found, text) = readCachedSchema(dirs, uri)
    if found: result = loadAs[YamlNode](text)

proc localSchemaLoader*(dirs: seq[string]): SchemaLoader =
  ## A loader for what is at hand without a network: ``file:`` schemas
  ## (`fileSchemaLoader`), and remote ones from the caches ``dirs``.
  let
    files = fileSchemaLoader()
    cached = cachedSchemaLoader(dirs)
  result = proc(uri: string): YamlNode {.closure, raises: [CatchableError].} =
    result = files(uri)
    if result.isNil: result = cached(uri)
