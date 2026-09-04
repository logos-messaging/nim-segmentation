## A single segment, per LIP-243 "Message Segmentation and Reconstruction".
##
## ```protobuf
## message SegmentMessage {
##   bytes           original_payload_hash   = 1;  // Keccak256 of the original payload, 32 bytes
##   uint32          original_payload_length = 2;  // length in bytes of the original payload
##   uint32          index                   = 3;  // zero-based position within this segment's own class
##   uint32          data_segment_count      = 4;  // number of data segments
##   optional uint32 parity_segment_count    = 5;  // number of parity segments, unset if no parity
##   bool            is_parity               = 6;  // false for a data segment, true for a parity one
##   bytes           payload         = 7;  // this segment's data chunk or parity shard
## }
## ```
##
## Every segment carries both class counts, so a receiver knows the shape of the
## whole set from the first segment it sees, whichever class that is.
##
## Only `parity_segment_count` is `optional`: unset means the sender emitted no
## parity. Every other field has implicit presence -- proto3 leaves a default
## value off the wire, so "absent" and "zero" are indistinguishable, and what
## makes those fields meaningful is enforced after decoding by `isValid`.

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
  dataSegmentCount*: uint32
  paritySegmentCount*: uint32 ## Zero when the sender emitted no parity.
  isParity*: bool
  payload*: seq[byte]

func init*(
    T: type SegmentMessage,
    originalPayloadHash: seq[byte],
    originalPayloadLength: uint64,
    index: uint32,
    dataSegmentCount: uint32,
    paritySegmentCount: uint32,
    isParity: bool,
    payload: seq[byte],
): T =
  ## Every field is mandatory, so none is defaulted. The parameter order follows
  ## the spec's field numbering. A `paritySegmentCount` of zero is the spec's
  ## unset `parity_segment_count`.
  return T(
    originalPayloadHash: originalPayloadHash,
    originalPayloadLength: originalPayloadLength,
    index: index,
    dataSegmentCount: dataSegmentCount,
    paritySegmentCount: paritySegmentCount,
    isParity: isParity,
    payload: payload,
  )

func init(T: type SegmentMessage, pb: SegmentMessagePB): T =
  ## Narrow the mirror's widened counts back to the spec's `uint32`.
  ##
  ## Clamp rather than convert: the narrowing would wrap, and a wrapped count can
  ## land back inside the valid range, while clamping keeps it out of range for
  ## `isValid` to reject.
  return T.init(
    originalPayloadHash = pb.originalPayloadHash,
    originalPayloadLength = pb.originalPayloadLength,
    index = uint32(min(pb.index, uint64(uint32.high))),
    dataSegmentCount = uint32(min(pb.dataSegmentCount, uint64(uint32.high))),
    paritySegmentCount =
      uint32(min(pb.paritySegmentCount.valueOr(0'u64), uint64(uint32.high))),
    isParity = pb.isParity,
    payload = pb.payload,
  )

func toPB(self: SegmentMessage): SegmentMessagePB =
  return SegmentMessagePB.init(
    originalPayloadHash = self.originalPayloadHash,
    originalPayloadLength = self.originalPayloadLength,
    index = uint64(self.index),
    dataSegmentCount = uint64(self.dataSegmentCount),
    paritySegmentCount =
      if self.paritySegmentCount == 0:
        Opt.none(uint64)
      else:
        Opt.some(uint64(self.paritySegmentCount)),
    isParity = self.isParity,
    payload = self.payload,
  )

func segmentSetKey*(self: SegmentMessage): string =
  ## Identity of the segment set this message belongs to: the spec groups two
  ## messages together only when their `original_payload_hash` and
  ## `original_payload_length` both match. Encoded as the 32 hash bytes followed
  ## by the length, little-endian.
  ##
  ## The counts are deliberately absent. The spec treats segments disagreeing on
  ## them as different sets, but keying on them would let one sender open an
  ## unbounded number of sets under a single hash; a disagreeing segment is
  ## discarded instead, which the cache reports as `CountMismatch`.
  var key = newString(self.originalPayloadHash.len + 8)
  for i, b in self.originalPayloadHash:
    key[i] = char(b)
  var n = self.originalPayloadLength
  for i in 0 ..< 8:
    key[self.originalPayloadHash.len + i] = char(byte(n and 0xFF'u64))
    n = n shr 8
  return key

func isValid*(self: SegmentMessage, maxTotalSegments: int): bool =
  ## The spec's validity rules. An invalid segment message is discarded.
  if self.originalPayloadHash.len != SegmentHashLen:
    return false
  if self.dataSegmentCount < 1'u32:
    return false
  # Both counts ride on every segment, so the whole set is bounded here rather
  # than only once segments of both classes have arrived.
  if uint64(self.dataSegmentCount) + uint64(self.paritySegmentCount) >
      uint64(maxTotalSegments):
    return false
  let classCount = if self.isParity: self.paritySegmentCount else: self.dataSegmentCount
  if self.index >= classCount:
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
