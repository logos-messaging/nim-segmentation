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
    ## Concurrent partial sets retained; bounds how many payloads may be in
    ## flight at once.

  DefaultMaxBufferedBytes* = 32 * 1024 * 1024
    ## Ceiling on the segment payload bytes held across all incomplete sets, and
    ## the bound that actually caps memory. `maxSegmentSets` alone would leave it
    ## at `maxSegmentSets * maxTotalSegments * segmentSizeBytes` -- 2.5 GB at the
    ## defaults. 32 MiB holds roughly thirty 1 MiB payloads mid-flight.

  SegmentHeaderMaxBytes* = 128
    ## Upper bound on everything a serialized `SegmentMessage` carries besides
    ## the chunk itself, at the largest value each field can take:
    ##
    ## | field | bytes |
    ## |---|---|
    ## | 1 `original_payload_hash` | tag 1 + len 1 + 32 = 34 |
    ## | 2 `original_payload_length` | 1 + 5 |
    ## | 3 `index` | 1 + 5 |
    ## | 4 `data_segment_count` | 1 + 5 |
    ## | 5 `parity_segment_count` | 1 + 5 |
    ## | 6 `is_parity` | 1 + 1 |
    ## | 7 `payload` tag + length | 1 + 5 |
    ## | | **66** |
    ##
    ## Rounded up to a multiple of `ShardAlignment` so that a 64-aligned
    ## `segmentSizeBytes` yields a chunk size needing no further rounding.

  MinSegmentSizeBytes* = 192
    ## `SegmentHeaderMaxBytes` plus one whole shard; below this the chunk size
    ## rounds down to zero. The `static` block in `segmentation_handler` holds
    ## the two constants to that relationship.

  MaxSupportedTotalSegments* = 65_536 ## leopard rejects `buffers + parity` above this.

type SegmentationConfig* = object ## Tunables for a `SegmentationHandler`.
  segmentSizeBytes*: int
  parityRate*: float
  reconstructionTimeoutSeconds*: int
  maxTotalSegments*: int
  maxSegmentSets*: int
  maxBufferedBytes*: int

func init*(
    T: type SegmentationConfig,
    segmentSizeBytes: int = DefaultSegmentSizeBytes,
    parityRate: float = DefaultParityRate,
    reconstructionTimeoutSeconds: int = DefaultReconstructionTimeoutSeconds,
    maxTotalSegments: int = DefaultMaxTotalSegments,
    maxSegmentSets: int = DefaultMaxSegmentSets,
    maxBufferedBytes: int = DefaultMaxBufferedBytes,
): T =
  ## Every field defaults, so a caller names only what it wants to change.
  ## Validation happens in `SegmentationHandler.new`, not here.
  return T(
    segmentSizeBytes: segmentSizeBytes,
    parityRate: parityRate,
    reconstructionTimeoutSeconds: reconstructionTimeoutSeconds,
    maxTotalSegments: maxTotalSegments,
    maxSegmentSets: maxSegmentSets,
    maxBufferedBytes: maxBufferedBytes,
  )

{.pop.}
