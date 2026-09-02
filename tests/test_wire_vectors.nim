## Golden wire vectors.
##
## These byte strings are the contract with every other implementation of
## LIP-243. A refactor that changes them changes the protocol, so they are
## pinned here rather than being recomputed from the code under test.
import std/strutils
import unittest2, results
import segmentation

const
  hashHex = "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"

  # hash(f1) | length 500(f2) | index 1(f3) | data count 3(f4) | payload(f7).
  # parity_segment_count is unset (no parity) and is_parity is false, so proto3
  # leaves both off the wire.
  dataHex = "0A20" & hashHex & "10F403" & "1801" & "2003" & "3A03AABBCC"

  # hash(f1) | length 500(f2) | data count 3(f4) | parity count 1(f5) |
  # is_parity(f6) | payload(f7). index is 0 and therefore omitted.
  parityHex = "0A20" & hashHex & "10F403" & "2003" & "2801" & "3001" & "3A021122"

  # Only the hash and a data-segment count of 1 survive; every other field is at
  # its proto3 default, and parity_segment_count is unset.
  minimalHex = "0A20" & hashHex & "2001"

proc bytes(hex: string): seq[byte] =
  var b = newSeq[byte](hex.len div 2)
  for i in 0 ..< b.len:
    b[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
  return b

let testHash = bytes(hashHex)

suite "wire vectors":
  test "data segment":
    let m = SegmentMessage.init(
      originalPayloadHash = testHash,
      originalPayloadLength = 500'u64,
      index = 1'u32,
      dataSegmentCount = 3'u32,
      paritySegmentCount = 0,
      isParity = false,
      segmentPayload = @[0xAA'u8, 0xBB, 0xCC],
    )
    check m.encode().get() == bytes(dataHex)
    check SegmentMessage.decode(bytes(dataHex)).get() == m

  test "parity segment":
    let m = SegmentMessage.init(
      originalPayloadHash = testHash,
      originalPayloadLength = 500'u64,
      index = 0'u32,
      dataSegmentCount = 3'u32,
      paritySegmentCount = 1'u32,
      isParity = true,
      segmentPayload = @[0x11'u8, 0x22],
    )
    check m.encode().get() == bytes(parityHex)
    check SegmentMessage.decode(bytes(parityHex)).get() == m

  test "all-default segment":
    let m = SegmentMessage.init(
      originalPayloadHash = testHash,
      originalPayloadLength = 0'u64,
      index = 0'u32,
      dataSegmentCount = 1'u32,
      paritySegmentCount = 0,
      isParity = false,
      segmentPayload = @[],
    )
    check m.encode().get() == bytes(minimalHex)
    check SegmentMessage.decode(bytes(minimalHex)).get() == m

  test "fields are emitted in ascending field number":
    let encoded = bytes(dataHex)
    var tags: seq[int]
    var i = 0
    while i < encoded.len:
      let field = int(encoded[i]) shr 3
      let wire = int(encoded[i]) and 0x07
      tags.add(field)
      inc i
      case wire
      of 0: # varint
        while i < encoded.len and (encoded[i] and 0x80'u8) != 0:
          inc i
        inc i
      of 2: # length-delimited
        let length = int(encoded[i])
        inc i
        i += length
      else:
        checkpoint("unexpected wire type " & $wire)
        fail()
    check tags == @[1, 2, 3, 4, 7]
