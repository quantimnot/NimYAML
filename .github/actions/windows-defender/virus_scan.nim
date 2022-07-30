import std/[strutils, strformat, osproc, os, options]

func bisect(bytes: Slice[int], test: proc(bytes: Slice[int]): bool): Slice[int] =
  var a = 0..(bytes.len div 2)
  var b = (a.b + 1)..bytes.b
  while true:
    if test a:
      result = a
      if (a.b - a.a) == 0: break
      b.b = a.b
      a.b = a.a + ((a.b - a.a) div 2)
      b.a = (a.b + 1)
    elif test b:
      a = b
      result = a
      a.b = a.a + ((a.b - a.a) div 2)
      b.a = (a.b + 1)
    else:
      a.b = b.b
      result = a
      break

func bisect(corpus, pattern: string): Slice[int] =
  bisect(0..corpus.high, (proc(bytes: Slice[int]): bool = pattern in corpus[bytes]))


when defined windows:
  proc findWindowsDefender*: Option[string] =
    for dir in walkDirs(r"C:\ProgramData\Microsoft\Windows Defender\Platform\*"):
      if fileExists(dir / "MpCmdRun.exe") and dir > result.get(""):
        result = some dir

  proc runWindowsDefender*(mpCmdRunPath, filePath: string): Option[tuple[path, kind: string, bytes: Slice[int]]] =
    if execCmd(&"{mpCmdRunPath} -Scan -ScanType 3 -DisableRemediation -File {paramStr(1)}") == 1:
      result = some (filePath, "TODO", 0..0)

# let virusTotalToken = getEnv"VIRUS_TOTAL_TOKEN"

proc virusTotal*(data, token: string): Option[Slice[int]] =
  discard


when isMainModule:
  when not defined test:
    proc main =
      when defined windows:
        # Update signatures
        let mpCmdRunPath = findWindowsDefender().get
        doAssert execCmd(&"{mpCmdRunPath} -SignatureUpdate -MMPC") == 0
        echo runWindowsDefender(mpCmdRunPath, paramStr(1))
    main()

  else:
    import std/unittest

    test "bisect":
      const corpus = "abcdefghijklm0nopqrstuvwxyz"
      template check(pattern) =
        unittest.check corpus[bisect(corpus, pattern)] == pattern
      check "xyz"
      check "z"
      check "y"
      check "a"
      check "ab"
      check "0"
