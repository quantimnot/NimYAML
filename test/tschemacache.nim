#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Tests the cache of downloaded schemas (yaml/schemacache): where each
# location is, how a URI maps to a file in it, storing and reading, and the
# loader that reads the caches.

import std/[os, unittest]
when defined(nimPreviewSlimSystem):
  import std/syncio
import "../yaml/dom", "../yaml/schemacache"

suite "schema cache":
  let base = getTempDir() / ("nimyaml-tschemacache-" & $getCurrentProcessId())
  setup:
    createDir(base)
  teardown:
    removeDir(base)

  test "a remote URI maps to a path below the cache, others to none":
    let dir = base / "c"
    check cachePath(dir, "https://www.schemastore.org/package.json") ==
        dir / "https" / "www.schemastore.org" / "package.json"
    check cachePath(dir, "http://x.example:8080/a/b.json?v=1") ==
        dir / "http" / "x.example%3A8080" / "a" / "b.json%3Fv%3D1"
    check cachePath(dir, "https://x.example/schemas/") ==
        dir / "https" / "x.example" / "schemas" / "index"
    check cachePath(dir, "https://x.example") ==
        dir / "https" / "x.example" / "index"
    # nothing escapes the cache
    check cachePath(dir, "https://x.example/../../etc/passwd") ==
        dir / "https" / "x.example" / "%2E%2E" / "%2E%2E" / "etc" / "passwd"
    check cachePath(dir, "HTTPS://X.example/a") ==
        dir / "https" / "x.example" / "a"
    check cachePath(dir, "vscode://schemas/settings/user") == ""
    check cachePath(dir, "file:///etc/s.json") == ""
    check cachePath("", "https://x.example/a") == ""

  test "store, read, and the first cache that has it wins":
    let (a, b) = (base / "a", base / "b")
    check storeSchema(b, "https://x.example/s.json", "{type: string}")
    check readCachedSchema(@[a, b], "https://x.example/s.json") ==
        (true, "{type: string}")
    check storeSchema(a, "https://x.example/s.json", "{type: integer}")
    check readCachedSchema(@[a, b], "https://x.example/s.json") ==
        (true, "{type: integer}")
    check readCachedSchema(@[a, b], "https://x.example/other.json").found == false
    check not storeSchema(a, "vscode://schemas/s", "{}")
    # a cache that cannot be written is not an error
    writeFile(base / "file", "")
    check not storeSchema(base / "file", "https://x.example/s.json", "{}")

  test "locations: the configured one is written, all are read":
    # restored, since the other tests of the process set it too
    let (had, previous) = (existsEnv("XDG_CACHE_HOME"), getEnv("XDG_CACHE_HOME"))
    putEnv("XDG_CACHE_HOME", base / "xdg")
    defer:
      if had: putEnv("XDG_CACHE_HOME", previous) else: delEnv("XDG_CACHE_HOME")
    let project = base / "project"
    let user = schemaCacheDir(sclUser)
    check user == base / "xdg" / "nimyaml" / "schemas"
    check schemaCacheDir(sclProject, project) == project / ".yaml-schemas"
    # a project location needs the config's directory
    check schemaCacheDir(sclProject) == user
    check schemaCacheDir(sclOff, project) == ""
    let system = schemaCacheDir(sclSystem)
    check system.len > 0 and system != user
    check readDirs(sclUser, project) ==
        @[project / ".yaml-schemas", user, system]
    check readDirs(sclSystem) == @[user, system]
    check readDirs(sclOff, project).len == 0

  test "the loader reads the caches, in YAML or JSON":
    let dir = base / "l"
    check storeSchema(dir, "https://x.example/s.json", """{"type": "array"}""")
    let load = cachedSchemaLoader(@[dir])
    check load("https://x.example/s.json")["type"].content == "array"
    check load("https://x.example/missing.json").isNil
    check load("file:///nowhere.json").isNil
