## Tunables for a `SegmentationHandler`.
##
## All participants in an application must agree on `maxTotalSegments`, and on
## a `segmentSizeBytes` their transport can carry.

{.push raises: [].}

const
  DefaultSegmentSizeBytes* = 102_400
    ## Fits the 150 KiB cap of Logos Delivery with room to spare.

  DefaultParityRate* = 0.0 ## Parity off, as the spec defaults it.

  DefaultReconstructionTimeoutSeconds* = 300
    ## How long a set may go without a new segment before it is dropped.

  DefaultMaxTotalSegments* = 256
    ## The spec's RECOMMENDED value, and Leopard-RS' 8-bit field ceiling.

  DefaultMaxSegmentSets* = 100
    ## Concurrent partial sets retained; bounds what one sender can make a
    ## receiver buffer.

  SegmentHeaderMaxBytes* = 64
    ## Upper bound on everything a serialized `SegmentMessage` carries besides
    ## the chunk itself: 34 bytes for the 32-byte hash, 6 each for the three
    ## varint fields, 2 for the bool and up to 6 for the payload tag and length
    ## prefix -- 58, rounded up to a multiple of `ShardAlignment`.

  MinSegmentSizeBytes* = 128 ## Below this the chunk size rounds down to zero.

  MaxSupportedTotalSegments* = 65_536 ## leopard rejects `buffers + parity` above this.

type SegmentationConfig* = object ## Tunables for a `SegmentationHandler`.
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
  ## Every field defaults, so a caller names only what it wants to change.
  ## Validation happens in `SegmentationHandler.new`, not here.
  return T(
    segmentSizeBytes: segmentSizeBytes,
    parityRate: parityRate,
    reconstructionTimeoutSeconds: reconstructionTimeoutSeconds,
    maxTotalSegments: maxTotalSegments,
    maxSegmentSets: maxSegmentSets,
  )

{.pop.}
