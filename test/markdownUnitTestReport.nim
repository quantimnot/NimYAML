import std/[unittest, strformat, compilesettings]

type
  MarkdownOutputFormatter* = ref object of OutputFormatter

const
  os {.strdefine.} = hostOS
  nim {.strdefine.} = NimVersion
  mm {.strdefine.} = block:
    when declared(SingleValueSetting.mm):
      querySetting(SingleValueSetting.mm)
    else:
      querySetting(SingleValueSetting.gc)

# method suiteStarted*(formatter: MarkdownOutputFormatter, suiteName: string) =
#   discard
# method testStarted*(formatter: MarkdownOutputFormatter, testName: string) =
#   discard
# method failureOccurred*(formatter: MarkdownOutputFormatter, checkpoints: seq[string],
#     stackTrace: string) =
#   ## ``stackTrace`` is provided only if the failure occurred due to an exception.
#   ## ``checkpoints`` is never ``nil``.
#   discard
method testEnded(formatter: MarkdownOutputFormatter, testResult: TestResult) =
  let result = block:
    case testResult.status
    of OK: ":heavy_check_mark: OK"
    of FAILED: ":heavy_check_mark: FAILED"
    of SKIPPED: ":heavy_minus_sign: SKIPPED"
  echo &"| {result} | {os} | {nim} | {mm} | {testResult.suiteName} | {testResult.testName} |"
# method suiteEnded*(formatter: MarkdownOutputFormatter) =
#   discard
