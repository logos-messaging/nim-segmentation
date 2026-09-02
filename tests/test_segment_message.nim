import unittest2
import results
import segmentation

const testHash = block:
  var h = newSeq[byte](SegmentHashLen)
  for i in 0 ..< SegmentHashLen:
    h[i] = byte(i)
  h

suite "segment message wire format":
  test "data segment round-trips":
    let m = SegmentMessage(
      originalPayloadHash: testHash,
      originalPayloadLength: 1234'u64,
      index: 2'u32,
      segmentCount: 5'u32,
      isParity: false,
      segmentPayload: @[1'u8, 2, 3],
    )
    let encoded = m.encode()
    check encoded.isOk()
    let back = SegmentMessage.decode(encoded.get())
    check back.isOk()
    check back.get() == m

  test "parity segment round-trips":
    let m = SegmentMessage(
      originalPayloadHash: testHash,
      originalPayloadLength: 9'u64,
      index: 0'u32,
      segmentCount: 3'u32,
      isParity: true,
      segmentPayload: @[9'u8, 9, 9, 9],
    )
    let back = SegmentMessage.decode(m.encode().get())
    check back.isOk()
    check back.get() == m

  test "proto3 defaults omitted on the wire still decode":
    # index 0, is_parity false and an empty payload are all proto3 defaults, so
    # a conforming encoder leaves them off entirely.
    let m = SegmentMessage(
      originalPayloadHash: testHash,
      originalPayloadLength: 0'u64,
      index: 0'u32,
      segmentCount: 1'u32,
      isParity: false,
      segmentPayload: @[],
    )
    let encoded = m.encode().get()
    # hash (34 bytes) + segment_count (2 bytes); nothing else is on the wire.
    check encoded.len == 36
    let back = SegmentMessage.decode(encoded)
    check back.isOk()
    check back.get() == m

  test "unknown fields are ignored":
    let m = SegmentMessage(
      originalPayloadHash: testHash,
      originalPayloadLength: 8'u64,
      index: 1'u32,
      segmentCount: 2'u32,
      isParity: false,
      segmentPayload: @[7'u8],
    )
    var extended = m.encode().get()
    # A future field 7, varint-encoded: tag (7 shl 3) or 0, then the value.
    extended.add(0x38'u8)
    extended.add(0x01'u8)
    let back = SegmentMessage.decode(extended)
    check back.isOk()
    check back.get() == m

  test "an out-of-range count is clamped, not wrapped":
    # field 4 (segment_count) carrying 2^32 + 5. Narrowing that straight to
    # uint32 wraps it to 4 -- a perfectly valid count -- so it is clamped to
    # uint32.high instead, staying out of range for isValid to reject.
    var encoded = @[0x0A'u8, 0x20'u8] & testHash
    encoded.add(0x20'u8) # field 4, wire type 0
    var n = uint64(uint32.high) + 5'u64
    while n >= 0x80'u64:
      encoded.add(byte((n and 0x7F'u64) or 0x80'u64))
      n = n shr 7
    encoded.add(byte(n))

    let m = SegmentMessage.decode(encoded)
    check m.isOk()
    check m.get().segmentCount == uint32.high
    check not m.get().isValid(256)

  test "undecodable bytes are an error, not a crash":
    # Field 1 declares a 127-byte length the buffer cannot satisfy.
    check SegmentMessage.decode(@[0x0A'u8, 0x7F]).isErr()

suite "segment message validity":
  const maxTotal = 256

  proc valid(): SegmentMessage =
    return SegmentMessage(
      originalPayloadHash: testHash,
      originalPayloadLength: 10'u64,
      index: 0'u32,
      segmentCount: 2'u32,
      isParity: false,
      segmentPayload: @[1'u8],
    )

  test "a well-formed segment is valid":
    check valid().isValid(maxTotal)

  test "single-segment sets are valid":
    var m = valid()
    m.segmentCount = 1
    m.index = 0
    check m.isValid(maxTotal)

  test "hash must be exactly 32 bytes":
    var short = valid()
    short.originalPayloadHash = testHash[0 ..< 31]
    check not short.isValid(maxTotal)

    var empty = valid()
    empty.originalPayloadHash = @[]
    check not empty.isValid(maxTotal)

  test "segment count must be at least one":
    var m = valid()
    m.segmentCount = 0
    check not m.isValid(maxTotal)

  test "segment count must not exceed maxTotalSegments":
    var m = valid()
    m.segmentCount = uint32(maxTotal) + 1
    m.index = 0
    check not m.isValid(maxTotal)

  test "index must be below segment count":
    var m = valid()
    m.segmentCount = 3
    m.index = 3
    check not m.isValid(maxTotal)

suite "header budget":
  test "maximal metadata stays within SegmentHeaderMaxBytes":
    # The constant that chunk sizing subtracts must bound every non-payload
    # byte, at the largest values each field can take.
    for payloadLen in [0, 1, 64, 200, 100_000, 3_000_000]:
      let m = SegmentMessage(
        originalPayloadHash: testHash,
        originalPayloadLength: uint64(uint32.high),
        index: uint32.high - 1,
        segmentCount: uint32.high,
        isParity: true,
        segmentPayload: newSeq[byte](payloadLen),
      )
      let encoded = m.encode().get()
      check encoded.len - payloadLen <= SegmentHeaderMaxBytes
