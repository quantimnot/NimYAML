#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## The identity of a ref, as a key of sets and tables.
##
## Several algorithms must tell *this* node from an equal one: the anchors
## of a graph being represented, cycles met while comparing or walking a
## DOM, the nodes a patch has copied. A `ref` itself is no such key,
## since a type may define ``==`` by value (`YamlNode` does), so the
## library used to key them by ``cast[pointer](x)``.
##
## That cast does not exist on the JavaScript backend. A JavaScript pointer
## is a pair of a base and an index, and casting a ref to it generates code
## that does not even parse. What JavaScript does have is the object
## itself, which is what a ref is there, and which can be compared with
## ``===``. So an `Identity` is the address natively and the object on
## JavaScript, and a hash of it is the address natively and, on
## JavaScript, a number given to the object the first time it is hashed,
## as `std/hashes` does for pointers.
##
## Rejected: hashing refs with ``-d:nimPreviewHashRef``, which changes
## ``hash`` for every ref of a program that imports the library and still
## leaves the value equality of types like `YamlNode` in the way; and a
## counter field in each node, which only the library's own types could
## have, where the representer meets refs of any type.

import std/hashes

when defined(js):
  type Identity* = distinct RootRef
    ## The identity of a ref: the same for the same object, different for
    ## any other, whatever ``==`` of its type says.

  proc identity*[T: ref](x: T): Identity {.inline.} =
    Identity(cast[RootRef](x))

  proc toRef*[T: ref](i: Identity): T {.inline.} =
    ## The ref whose identity ``i`` is.
    cast[T](RootRef(i))

  proc `==`*(a, b: Identity): bool {.inline.} =
    system.`==`(RootRef(a), RootRef(b))

  proc isNil*(i: Identity): bool {.inline.} = RootRef(i).isNil

  var lastIdentity = 0

  proc hash*(i: Identity): Hash =
    # The number is a property that is neither enumerable nor writable, so
    # that it changes nothing a program can see of the object but this.
    var number = 0
    {.emit: """
    if (`i` !== null) {
      if (!Object.prototype.hasOwnProperty.call(`i`, "__nimyamlIdentity"))
        Object.defineProperty(`i`, "__nimyamlIdentity",
            {value: ++`lastIdentity`});
      `number` = `i`.__nimyamlIdentity;
    }""".}
    hash(number)
else:
  type Identity* = distinct pointer
    ## The identity of a ref: the same for the same object, different for
    ## any other, whatever ``==`` of its type says.

  proc identity*[T: ref](x: T): Identity {.inline.} =
    Identity(cast[pointer](x))

  proc toRef*[T: ref](i: Identity): T {.inline.} =
    ## The ref whose identity ``i`` is.
    cast[T](pointer(i))

  proc `==`*(a, b: Identity): bool {.borrow.}

  proc isNil*(i: Identity): bool {.inline.} = pointer(i).isNil

  proc hash*(i: Identity): Hash {.inline.} = hash(pointer(i))

const noIdentity* = Identity(nil)
  ## The identity of ``nil``.
