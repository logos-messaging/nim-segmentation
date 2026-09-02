## proto3 mirror of `SegmentMessage`.
##
## Holds the field annotations so the domain type stays free of them, and nothing
## else: the conversions and the codec are operations on `SegmentMessage`, so
## they live with it. That keeps the dependency one-way -- `segment_message`
## imports this module, never the reverse.

{.push raises: [].}
import protobuf_serialization

type SegmentMessagePB* {.proto3.} = object
  ## Mirrors the spec's declaration field for field, except that the counts are
  ## widened: decoding an out-of-range varint straight into `uint32` truncates it
  ## silently, and `uint32(2^32 + 5)` is 5, which `isValid` would wave through.
  originalPayloadHash* {.fieldNumber: 1.}: seq[byte]
  originalPayloadLength* {.fieldNumber: 2, pint.}: uint64
  index* {.fieldNumber: 3, pint.}: uint64
  segmentCount* {.fieldNumber: 4, pint.}: uint64
  isParity* {.fieldNumber: 5.}: bool
  segmentPayload* {.fieldNumber: 6.}: seq[byte]

func init*(
    T: type SegmentMessagePB,
    originalPayloadHash: seq[byte],
    originalPayloadLength: uint64,
    index: uint64,
    segmentCount: uint64,
    isParity: bool,
    segmentPayload: seq[byte],
): T =
  return T(
    originalPayloadHash: originalPayloadHash,
    originalPayloadLength: originalPayloadLength,
    index: index,
    segmentCount: segmentCount,
    isParity: isParity,
    segmentPayload: segmentPayload,
  )

{.pop.}
