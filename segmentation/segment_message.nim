## A single segment, per LIP-243 "Message Segmentation and Reconstruction".
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
import results, protobuf_serialization
import ./segment_message_pb

export results

const SegmentHashLen* = 32
  ## Keccak256 digest length, the only accepted `originalPayloadHash` length.

type SegmentMessage* = object ## One segment of a payload, data or parity.
  originalPayloadHash*: seq[byte]
  originalPayloadLength*: uint64
  index*: uint32
  segmentCount*: uint32
  isParity*: bool
  segmentPayload*: seq[byte]

func init*(
    T: type SegmentMessage,
    originalPayloadHash: seq[byte],
    originalPayloadLength: uint64,
    index: uint32,
    segmentCount: uint32,
    isParity: bool,
    segmentPayload: seq[byte],
): T =
  ## Every field is mandatory, so none is defaulted. The parameter order follows
  ## the spec's field numbering.
  return T(
    originalPayloadHash: originalPayloadHash,
    originalPayloadLength: originalPayloadLength,
    index: index,
    segmentCount: segmentCount,
    isParity: isParity,
    segmentPayload: segmentPayload,
  )

func init(T: type SegmentMessage, pb: SegmentMessagePB): T =
  ## Narrow the mirror's widened counts back to the spec's `uint32`.
  ##
  ## Clamp rather than convert: the narrowing would wrap, and a wrapped count can
  ## land back inside the valid range. Clamping keeps it out of range so that
  ## `isValid` rejects it.
  return T.init(
    originalPayloadHash = pb.originalPayloadHash,
    originalPayloadLength = pb.originalPayloadLength,
    index = uint32(min(pb.index, uint64(uint32.high))),
    segmentCount = uint32(min(pb.segmentCount, uint64(uint32.high))),
    isParity = pb.isParity,
    segmentPayload = pb.segmentPayload,
  )

func toPB(self: SegmentMessage): SegmentMessagePB =
  return SegmentMessagePB.init(
    originalPayloadHash = self.originalPayloadHash,
    originalPayloadLength = self.originalPayloadLength,
    index = uint64(self.index),
    segmentCount = uint64(self.segmentCount),
    isParity = self.isParity,
    segmentPayload = self.segmentPayload,
  )

func segmentSetKey*(self: SegmentMessage): string =
  ## Identity of the segment set this message belongs to: the spec groups two
  ## messages together only when their `original_payload_hash` and
  ## `original_payload_length` both match. Encoded as the 32 hash bytes followed
  ## by the length, little-endian.
  ##
  ## `segment_count` is deliberately absent -- it counts one class, so including
  ## it would file a payload's data and parity segments under two identities.
  var key = newString(self.originalPayloadHash.len + 8)
  for i, b in self.originalPayloadHash:
    key[i] = char(b)
  var n = self.originalPayloadLength
  for i in 0 ..< 8:
    key[self.originalPayloadHash.len + i] = char(byte(n and 0xFF'u64))
    n = n shr 8
  return key

func isValid*(self: SegmentMessage, maxTotalSegments: int): bool =
  ## The spec's three validity rules. An invalid segment message is discarded.
  if self.originalPayloadHash.len != SegmentHashLen:
    return false
  if self.segmentCount < 1'u32 or self.segmentCount > uint32(maxTotalSegments):
    return false
  if self.index >= self.segmentCount:
    return false
  return true

proc encode*(self: SegmentMessage): Result[seq[byte], string] =
  ## Serialize to the proto3 wire format. The caller sends the result as one
  ## transport message.
  try:
    return ok(Protobuf.encode(self.toPB()))
  except CatchableError as e:
    return err("segment_message.encode: protobuf encoding failed: " & e.msg)

proc decodeBytes(data: seq[byte]): Result[SegmentMessage, string] =
  try:
    return ok(SegmentMessage.init(Protobuf.decode(data, SegmentMessagePB)))
  except CatchableError as e:
    return err("segment_message.decode: protobuf decoding failed: " & e.msg)

proc decode*(T: type SegmentMessage, data: seq[byte]): Result[SegmentMessage, string] =
  ## Parse one received segment message. Succeeding says only that the bytes were
  ## well-formed protobuf; call `isValid` before trusting the fields.
  # Delegates to a concrete proc: this one is generic over `T`, so instantiating
  # `Protobuf.decode` here would resolve its `mixin Reader` at the call site,
  # which need not import protobuf_serialization.
  return decodeBytes(data)

{.pop.}
