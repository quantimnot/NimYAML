--define:nimPreviewSlimSystem
--experimental:typeBoundOps
--processing:off
switch "import", "minlib/test/test/assertions"
# --experimental:"strictDefs"
# --experimental:"strictFuncs"
# --experimental:"views"

# switch("warning", "UnusedImport:off")
switch("warning", "Uninit:off")
switch("warning", "ProveInit:off")

task build, "Compile the YAML module into a library":
  --app:lib
  --d:release
  setCommand "c", "yaml"

task test, "Run all tests":
  --r
  --verbosity:0
  setCommand "c", "test/tests"

task memoryTests, "Run memory budget tests":
  --r
  --verbosity:0
  setCommand "c", "test/tmemory"

task lexerTests, "Run lexer tests":
  --r
  --verbosity:0
  setCommand "c", "test/tlex"

task parserTests, "Run parser tests":
  --r
  --verbosity:0
  setCommand "c", "test/tparser"

task feedTests, "Run feed parser tests":
  --r
  --verbosity:0
  setCommand "c", "test/tfeed"

task commentTests, "Run comment collection and formatting tests":
  --r
  --verbosity:0
  setCommand "c", "test/tcomments"

task checkpointTests, "Run checkpoint and resume tests":
  --r
  --verbosity:0
  setCommand "c", "test/tcheckpoint"

task documentTests, "Run document start and error recovery tests":
  --r
  --verbosity:0
  setCommand "c", "test/tdocuments"

task lintTests, "Run diagnostics and lint tests":
  --r
  --verbosity:0
  setCommand "c", "test/tlint"

task yamllintTests, "Run yamllint CLI tests":
  --r
  --verbosity:0
  setCommand "c", "test/tyamllint"

task yamllint, "Compile the yamllint tool":
  --d:release
  setCommand "c", "tools/yamllint"

task yamlcliTests, "Run yaml command line tool tests":
  --r
  --verbosity:0
  setCommand "c", "test/tyamlcli"

task yaml, "Compile the yaml command line tool":
  --d:release
  --out:yaml
  setCommand "c", "tools/yamlcli"

task lspTests, "Run language server tests":
  --r
  --verbosity:0
  setCommand "c", "test/tlsp"

task yamllsp, "Compile the yamllsp language server":
  --d:release
  setCommand "c", "tools/yamllsp"

task jsonTests, "Run JSON tests":
  --r
  --verbosity:0
  setCommand "c", "test/tjson"

task domTests, "Run DOM tests":
  --r
  --verbosity:0
  setCommand "c", "test/tdom"

task fragmentTests, "Run fragment identifier and multi-document tests":
  --r
  --verbosity:0
  setCommand "c", "test/tfragment"

task jsonPatchTests, "Run JSON Patch tests":
  --r
  --verbosity:0
  setCommand "c", "test/tjsonpatch"

task mergePatchTests, "Run JSON Merge Patch tests":
  --r
  --verbosity:0
  setCommand "c", "test/tmergepatch"

task diffTests, "Run semantic diff tests":
  --r
  --verbosity:0
  setCommand "c", "test/tdiff"

task mergeTests, "Run YAML merge key tests":
  --r
  --verbosity:0
  setCommand "c", "test/tmerge"

task jcsTests, "Run JSON Canonicalization Scheme tests":
  --r
  --verbosity:0
  setCommand "c", "test/tjcs"

task jsonpathTests, "Run JSONPath and I-Regexp tests":
  --r
  --verbosity:0
  setCommand "c", "test/tjsonpath"

task editTests, "Run tests of assignments to the source text":
  --r
  --verbosity:0
  setCommand "c", "test/tedit"

task nodeIndexTests, "Run tests of node spans and the index of node locations":
  --r
  --verbosity:0
  setCommand "c", "test/tnodeindex"

task jsonSchemaTests, "Run the JSON Schema Test Suite and JSON Schema tests":
  --r
  --verbosity:0
  setCommand "c", "test/tjsonschema"

task schemaInternalsTests, "Run regex, URI, decimal, IDNA and format tests":
  --r
  --verbosity:0
  setCommand "c", "test/tschemainternals"

task hyperSchemaTests, "Run JSON Hyper-Schema tests":
  --r
  --verbosity:0
  setCommand "c", "test/thyperschema"

task uriTemplateTests, "Run URI Template tests":
  --r
  --verbosity:0
  setCommand "c", "test/turitemplate"

task directiveTests, "Run %GLOBAL and %SCHEMA directive tests":
  --r
  --verbosity:0
  setCommand "c", "test/tdirectives"

task documentSchemaTests, "Run schema selection and validation tests":
  --r
  --verbosity:0
  setCommand "c", "test/tdocumentschema"

task portableTests, "Run directive expansion tests":
  --r
  --verbosity:0
  setCommand "c", "test/tportable"

task yamlexpand, "Compile the yamlexpand tool":
  --d:release
  setCommand "c", "tools/yamlexpand"

task nativeTests, "Run native value tests":
  --r
  --verbosity:0
  setCommand "c", "test/tnative"

task quickstartTests, "Run quickstart tests":
  --r
  --verbosity:0
  setCommand "c", "test/tquickstart"

task hintsTests, "Run hints tests":
  --r
  --verbosity:0
  setCommand "c", "test/thints"

task presenterTests, "Run presenter tests":
  --r
  --verbosity:0
  setCommand "c", "test/tpresenter"

task annotationTests, "Run annotation tests":
  --r
  --verbosity:0
  setCommand "c", "test/tannotations"

task bench, "Benchmarking":
  --r
  --w:off
  --hints:off
  --d:release
  setCommand "c", "bench/bench"

task clean, "Remove all generated files":
  exec "rm -rf libyaml.* test/tests test/tjsonpath test/tjsonpatch test/tmergepatch test/tmerge test/tjcs test/tedit test/tnodeindex test/tjsonschema test/thyperschema test/tschemainternals test/turitemplate test/tdirectives test/tdocumentschema test/tportable test/parsing test/lexing bench/json docout"
  setCommand "nop"

task testSuiteEvents, "Compile the testSuiteEvents tool":
  --d:release
  setCommand "c", "tools/testSuiteEvents"
