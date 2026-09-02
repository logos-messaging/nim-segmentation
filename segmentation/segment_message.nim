## Wire format for a single segment, per LIP-243 "Message Segmentation and
## Reconstruction".
##
## ```protobuf
## message SegmentMessage {
##   bytes  original_payload_hash   = 1;  // Keccak256 of the original payload, 32 bytes
##   uint32 original_payload_length = 2;  // length in bytes of the original payload
##   uint32 index                   = 3;  // position within this segment's own class
##   uint32 segment_count           = 4;  // number of items of the given class
##   bool   is_parity               = 5;  // selects the class the two fields above refer to
##   bytes  segment_payload         = 6;  // data chunk or parity shard
## }
## ```
##
## proto3 omits default values, so `index`, `is_parity`, `original_payload_length`
## and an empty `segment_payload` all legitimately arrive absent. Treating any of
## them as missing rather than as the default would reject the first segment of
## every message from a conforming peer.

{.push raises: [].}

import results
import protobuf_serialization
import protobuf_serialization/pkg/results as pb_results

export results

const SegmentHashLen* = 32
  ## Keccak256 digest length, the only accepted `originalPayloadHash` length.

type
  SegmentMessage* = object
    originalPayloadHash*: seq[byte]
    originalPayloadLength*: uint64
    index*: uint32
    segmentCount*: uint32
    isParity*: bool
    segmentPayload*: seq[byte]

  # `uint64` where the spec says `uint32`: the varint is byte-identical below
  # 2^32, so this stays wire-compatible while keeping out-of-range values.
  SegmentMessagePB {.proto3.} = object
    originalPayloadHash {.fieldNumber: 1.}: Opt[seq[byte]]
    originalPayloadLength {.fieldNumber: 2, pint.}: Opt[uint64]
    index {.fieldNumber: 3, pint.}: Opt[uint64]
    segmentCount {.fieldNumber: 4, pint.}: Opt[uint64]
    isParity {.fieldNumber: 5.}: Opt[bool]
    segmentPayload {.fieldNumber: 6.}: Opt[seq[byte]]

func optBytes(b: seq[byte]): Opt[seq[byte]] =
  ## Present only when non-empty, so empty optionals stay off the wire.
  if b.len > 0:
    return Opt.some(b)
  return Opt.none(seq[byte])

func optNum(n: uint64): Opt[uint64] =
  ## proto3 leaves zero-valued scalars off the wire.
  if n != 0:
    return Opt.some(n)
  return Opt.none(uint64)

func toPB(m: SegmentMessage): SegmentMessagePB =
  return SegmentMessagePB(
    originalPayloadHash: optBytes(m.originalPayloadHash),
    originalPayloadLength: optNum(m.originalPayloadLength),
    index: optNum(uint64(m.index)),
    segmentCount: optNum(uint64(m.segmentCount)),
    isParity: (if m.isParity: Opt.some(true) else: Opt.none(bool)),
    segmentPayload: optBytes(m.segmentPayload),
  )

func fromPB(pb: SegmentMessagePB): SegmentMessage =
  # Saturate rather than wrap: `uint32(2^32 + 5)` is 5, which would pass
  # `isValid`; clamping to uint32.high keeps it out of range so it is rejected.
  let idx = pb.index.valueOr(0'u64)
  let count = pb.segmentCount.valueOr(0'u64)
  return SegmentMessage(
    originalPayloadHash: pb.originalPayloadHash.valueOr(@[]),
    originalPayloadLength: pb.originalPayloadLength.valueOr(0'u64),
    index: uint32(min(idx, uint64(uint32.high))),
    segmentCount: uint32(min(count, uint64(uint32.high))),
    isParity: pb.isParity.valueOr(false),
    segmentPayload: pb.segmentPayload.valueOr(@[]),
  )

func isValid*(m: SegmentMessage, maxTotalSegments: int): bool =
  ## The spec's three validity rules. An invalid segment message is discarded.
  if m.originalPayloadHash.len != SegmentHashLen:
    return false
  if m.segmentCount < 1'u32 or m.segmentCount > uint32(maxTotalSegments):
    return false
  if m.index >= m.segmentCount:
    return false
  return true

proc encode*(m: SegmentMessage): Result[seq[byte], string] =
  try:
    return ok(Protobuf.encode(m.toPB))
  except CatchableError as e:
    return err("failed to encode segment message: " & e.msg)

proc decodeBytes(data: seq[byte]): Result[SegmentMessage, string] =
  try:
    return ok(Protobuf.decode(data, SegmentMessagePB).fromPB)
  except CatchableError as e:
    return err("failed to decode segment message: " & e.msg)

proc decode*(T: type SegmentMessage, data: seq[byte]): Result[SegmentMessage, string] =
  # Delegates to a concrete proc: this one is generic over `T`, so instantiating
  # `Protobuf.decode` here would resolve its `mixin Reader` at the call site,
  # which need not import protobuf_serialization.
  return decodeBytes(data)

{.pop.}
