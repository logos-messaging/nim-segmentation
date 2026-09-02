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
## Every field is mandatory. proto3 has no `required`, and it leaves a field
## sitting at its default value off the wire entirely, so a receiver cannot tell
## "absent" from "zero" and must read one as the other. What makes the mandatory
## fields meaningful is therefore enforced after decoding, by `isValid`, rather
## than by presence.

{.push raises: [].}

import results
import protobuf_serialization

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

  # Mirrors the spec's declaration field for field, except that the counts are
  # widened: decoding an out-of-range varint straight into `uint32` truncates it
  # silently, and `uint32(2^32 + 5)` is 5, which `isValid` would wave through.
  SegmentMessagePB {.proto3.} = object
    originalPayloadHash {.fieldNumber: 1.}: seq[byte]
    originalPayloadLength {.fieldNumber: 2, pint.}: uint64
    index {.fieldNumber: 3, pint.}: uint64
    segmentCount {.fieldNumber: 4, pint.}: uint64
    isParity {.fieldNumber: 5.}: bool
    segmentPayload {.fieldNumber: 6.}: seq[byte]

func toPB(m: SegmentMessage): SegmentMessagePB =
  return SegmentMessagePB(
    originalPayloadHash: m.originalPayloadHash,
    originalPayloadLength: m.originalPayloadLength,
    index: uint64(m.index),
    segmentCount: uint64(m.segmentCount),
    isParity: m.isParity,
    segmentPayload: m.segmentPayload,
  )

func fromPB(pb: SegmentMessagePB): SegmentMessage =
  # Clamp rather than convert: the narrowing would wrap, and a wrapped count can
  # land back inside the valid range. Clamping keeps it out of range so that
  # `isValid` rejects it.
  return SegmentMessage(
    originalPayloadHash: pb.originalPayloadHash,
    originalPayloadLength: pb.originalPayloadLength,
    index: uint32(min(pb.index, uint64(uint32.high))),
    segmentCount: uint32(min(pb.segmentCount, uint64(uint32.high))),
    isParity: pb.isParity,
    segmentPayload: pb.segmentPayload,
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
