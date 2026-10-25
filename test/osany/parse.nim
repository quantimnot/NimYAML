#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# The parser on a microcontroller: input from a callback (here: a constant
# standing in for flash memory), a fixed memory budget, and events written
# with C's puts. Built with --os:any by tmemory; also runs on the host.

import ../../yaml/[memory, source, parser, stream, data]

proc puts(s: cstring): cint {.importc, header: "<stdio.h>".}

const flash = "a: [1, 2]\n"

proc readFlash(offset: int64, dest: var openArray[char]): int =
  result = max(0, min(dest.len, flash.len - int(offset)))
  for i in 0 ..< result: dest[i] = flash[int(offset) + i]

proc main() =
  let budget = newMemoryBudget(16 * 1024)
  let src = openSource(readFlash, int64(flash.len), "flash", budget,
      randomAccess = true)
  var p = initYamlParser(budget = budget)
  for e in p.parse(src): discard puts(cstring($e))

main()
