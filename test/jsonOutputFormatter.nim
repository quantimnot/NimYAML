import std/[unittest, monotimes, times, tables, json, os]

const
  resultDirPath {.strdefine.} = "testresults"
  resultFilename {.strdefine.} = "test-results.json"

type
  TestResult* {.pure.} = enum
    Passed, Failed, Skipped
  TestCase* = object
    result*: TestResult
    duration*: Duration
  TestSuite* = object
    result*: TestResult
    total*: int
    passed*: int
    failed*: int
    skipped*: int
    duration*: Duration
    tests*: OrderedTable[string, TestCase]
  Tests* = OrderedTable[string, TestSuite]
  JsonOutputFormatter* = ref object of OutputFormatter
    currentSuite: string
    currentTest: string
    suiteStartTime: MonoTime
    testStartTime: MonoTime
    suites: Tests

method suiteStarted(formatter: JsonOutputFormatter, suiteName: string) =
  formatter.currentSuite = suiteName
  formatter.suites[suiteName] = TestSuite()
  formatter.suiteStartTime = getMonoTime()

method testStarted(formatter: JsonOutputFormatter, testName: string) =
  formatter.currentTest = testName
  formatter.suites[formatter.currentSuite].tests[testName] = TestCase()
  formatter.testStartTime = getMonoTime()

# method failureOccurred(formatter: JsonOutputFormatter, checkpoints: seq[string],
#     stackTrace: string) =
#   ## ``stackTrace`` is provided only if the failure occurred due to an exception.
#   ## ``checkpoints`` is never ``nil``.
#   discard

method testEnded(formatter: JsonOutputFormatter, testResult: unittest.TestResult) =
  inc formatter.suites[testResult.suiteName].total
  let result = block:
    case testResult.status
    of OK:
      inc formatter.suites[testResult.suiteName].passed
      TestResult.Passed
    of FAILED:
      inc formatter.suites[testResult.suiteName].failed
      TestResult.Failed
    of SKIPPED:
      inc formatter.suites[testResult.suiteName].skipped
      TestResult.Skipped
  let duration = getMonoTime() - formatter.testStartTime
  formatter.suites[testResult.suiteName].tests[testResult.testName].result = result
  formatter.suites[testResult.suiteName].tests[testResult.testName].duration = duration

method suiteEnded(formatter: JsonOutputFormatter) =
  formatter.suites[formatter.currentSuite].duration =
    getMonoTime() - formatter.suiteStartTime
  formatter.suites[formatter.currentSuite].result = block:
    if formatter.suites[formatter.currentSuite].failed > 0:
      TestResult.Failed
    elif formatter.suites[formatter.currentSuite].total == 0:
      TestResult.Skipped
    elif formatter.suites[formatter.currentSuite].skipped > 0 and
         formatter.suites[formatter.currentSuite].passed == 0:
      TestResult.Skipped
    else:
      TestResult.Passed

  createDir(resultDirPath)
  writeFile(resultDirPath / resultFilename, $(%*formatter.suites))
