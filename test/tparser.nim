#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, terminal, strutils, streams, macros
import testEventParser, commonTestUtils
import ../yaml, ../yaml/data

proc echoError(msg: string) =
  styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)

proc parserTest(path: string, errorExpected : bool): bool =
  var
    parser: YamlParser
  parser.init()
  var
    actualIn = newFileStream(path / "in.yaml")
    actual = parser.parse(actualIn)
    expectedIn = newFileStream(path / "test.event")
    expected = parseEventStream(expectedIn)
  defer:
    actualIn.close()
    expectedIn.close()
  var i = 1
  try:
    while true:
      let actualEvent = actual.next()
      let expectedEvent = expected.next()
      if expectedEvent != actualEvent:
        result = errorExpected
        if not result:
          echoError("At event #" & $i &
                    ": Actual events do not match expected events")
          echo ".. expected event:"
          echo "  ", expectedEvent
          echo ".. actual event:"
          echo "  ", actualEvent
          echo ".. difference:"
          stdout.write("  ")
          printDifference(expectedEvent, actualEvent)

        return
      i.inc()
      if actualEvent.kind == yamlEndStream:
        break
    result = not errorExpected
    if not result:
      echo "Expected error, but parsed without error."
  except:
    result = errorExpected
    if not result:
      echoError("Caught an exception at event #" & $i &
                " test was not successful")
      let e = getCurrentException()
      if e.parent of YamlParserError:
        let pe = (ref YamlParserError)(e.parent)
        echo "line ", pe.mark.line, ", column ", pe.mark.column, ": ", pe.msg
        echo pe.lineContent
      else: echo e.msg

macro genTests(): untyped =
  const
    testSuiteFolder = "yaml-test-suite"
    absoluteTestSuiteDirPath = currentSourcePath.parentDir / testSuiteFolder

  if dirExists absoluteTestSuiteDirPath / "tags":
    echo "[tparser] Generating tests from " & testSuiteFolder
  else:
    try:
      discard staticExec"git submodule update --init --depth 1"
    except CatchableError:
      error "Failed to get " & testSuiteFolder

  proc getTestIds(path = "", exclusions: openArray[string] = []): seq[string] =
    let cmd = "git -C " & testSuiteFolder / path & " ls-tree --name-only HEAD"
    for testIdPath in splitLines(staticExec(cmd)):
      let testId = extractFilename(testIdPath)
      if testId.len > 0 and testId notin exclusions:
        result.add testId

  let testIds = getTestIds(exclusions = [".git", "name", "tags", "meta"])

  proc genTest(testId, path: string): NimNode =
    let
      title = strip(staticRead(path / "===")) & " [" & testId & ']'
      expectError = fileExists(path / "error")
    quote do:
      test `title`:
        doAssert parserTest(`path`, bool `expectError`)

  result = newStmtList()
  for testId in testIds:
    let testBaseDirPath = absoluteTestSuiteDirPath / testId
    if fileExists(testBaseDirPath / "==="):
      result.add genTest(testId, testBaseDirPath)
    else:
      for subTestId in getTestIds(testId):
        result.add genTest(testId & '_' & subTestId, testBaseDirPath / subTestId)
  result = newCall("suite", newLit("Parser Tests (from yaml-test-suite)"), result)

genTests()
