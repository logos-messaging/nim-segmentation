## Tunables for a `SegmentationHandler`.
##
## All participants in an application must agree on `maxTotalSegments`, and on
## a `segmentSizeBytes` their transport can carry.

{.push raises: [].}

const
  DefaultSegmentSizeBytes* = 102_400
  DefaultParityRate* = 0.0
  DefaultReconstructionTimeoutSeconds* = 300
  DefaultMaxTotalSegments* = 256
  DefaultMaxSegmentSets* = 100

  SegmentHeaderMaxBytes* = 64
    ## Upper bound on everything a serialized `SegmentMessage` carries besides
    ## the chunk itself: 34 bytes for the 32-byte hash, 6 each for the three
    ## varint fields, 2 for the bool and up to 6 for the payload tag and length
    ## prefix -- 58, rounded up to a multiple of `ShardAlignment`.

  MinSegmentSizeBytes* = 128 ## Below this the chunk size rounds down to zero.

  MaxSupportedTotalSegments* = 65_536 ## leopard rejects `buffers + parity` above this.

type SegmentationConfig* = object
  segmentSizeBytes*: int
  parityRate*: float
  reconstructionTimeoutSeconds*: int
  maxTotalSegments*: int
  maxSegmentSets*: int

func init*(
    T: type SegmentationConfig,
    segmentSizeBytes: int = DefaultSegmentSizeBytes,
    parityRate: float = DefaultParityRate,
    reconstructionTimeoutSeconds: int = DefaultReconstructionTimeoutSeconds,
    maxTotalSegments: int = DefaultMaxTotalSegments,
    maxSegmentSets: int = DefaultMaxSegmentSets,
): T =
  return T(
    segmentSizeBytes: segmentSizeBytes,
    parityRate: parityRate,
    reconstructionTimeoutSeconds: reconstructionTimeoutSeconds,
    maxTotalSegments: maxTotalSegments,
    maxSegmentSets: maxSegmentSets,
  )

{.pop.}
