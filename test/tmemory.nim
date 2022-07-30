import commonTestUtils

const runMemtest = defined(linux)

when runMemtest:
  import std/[compilesettings, strutils, os, osproc]

  const compileOptions = block:
    var options: string
    for option in split(querySetting(SingleValueSetting.commandLine)):
      if option.len > 0 and option[0] == '-':
        options.add " " & option
    options

  proc memTest(testName, srcPath, execPath: string) =
    check execCmd(getCurrentCompilerExe() & " c -d:release -d:useMalloc --debugger:native --stacktrace:on -d:nimUnittestOutputLevel:PRINT_NONE " & compileOptions & " " & srcPath) == 0
    check execCmd("valgrind --leak-check=full --show-leak-kinds=all --suppressions=test/memtest.supp --log-file=memtest_" & testName & ".log " & execPath) == 0
    echo readFile("memtest_" & testName & ".log")

suite "Memory":
  test "Valgrind: memtest":
    when runMemtest:
      memTest "tests", "test/tests.nim", "test/tests"
    else:
      skip()
