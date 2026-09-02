## Message segmentation and reconstruction, per LIP-243.
##
## Splits an application payload into transmittable segments and reassembles it
## on reception, optionally adding Reed-Solomon parity segments so a set can be
## recovered despite partial loss.
##
## Spec: https://github.com/logos-co/logos-lips -- messaging/application/raw/segmentation.md

{.push raises: [].}

import std/[math, monotimes, tables, times]
import results
import nimcrypto/keccak
import ./segment_message
import ./parity
import ./reassembly

export segment_message, results

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

static:
  # `new` rejects anything below MinSegmentSizeBytes, so this is what keeps the
  # chunk size positive for every config it does accept.
  doAssert alignShardLen(MinSegmentSizeBytes - SegmentHeaderMaxBytes) >= ShardAlignment

type
  SegmentationConfig* = object
    segmentSizeBytes*: int
    parityRate*: float
    reconstructionTimeoutSeconds*: int
    maxTotalSegments*: int
    maxSegmentSets*: int

  SegmentationHandler* = ref object
    config: SegmentationConfig
    scaledParityRate: int
    chunkSize: int
    cache: SegmentCache

  ReassemblyResult* = object
    payload*: seq[byte]
    originalPayloadHash*: seq[byte]

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

proc new*(T: type SegmentationHandler, config: SegmentationConfig): Result[T, string] =
  if config.segmentSizeBytes < MinSegmentSizeBytes:
    return err(
      "segmentation.new: segmentSizeBytes below the minimum: " & $config.segmentSizeBytes &
        " < " & $MinSegmentSizeBytes
    )
  if config.parityRate < 0.0 or config.parityRate >= 1.0:
    return err(
      "segmentation.new: parityRate out of range: " & $config.parityRate &
        " not in [0, 1)"
    )
  if config.reconstructionTimeoutSeconds <= 0:
    return err(
      "segmentation.new: reconstructionTimeoutSeconds not positive: " &
        $config.reconstructionTimeoutSeconds
    )
  if config.maxTotalSegments < 1 or config.maxTotalSegments > MaxSupportedTotalSegments:
    return err(
      "segmentation.new: maxTotalSegments out of range: " & $config.maxTotalSegments &
        " not in [1, " & $MaxSupportedTotalSegments & "]"
    )
  if config.maxSegmentSets < 1:
    return
      err("segmentation.new: maxSegmentSets not positive: " & $config.maxSegmentSets)

  # Rounded to a multiple of 64 unconditionally, not only when this node emits
  # parity: it costs at most 63 bytes per segment and guarantees a receiver can
  # Reed-Solomon decode a set even when its own parityRate is 0.
  let chunkSize = alignShardLen(config.segmentSizeBytes - SegmentHeaderMaxBytes)

  return ok(
    T(
      config: config,
      scaledParityRate: int(round(config.parityRate * float(ParityRateScale))),
      chunkSize: chunkSize,
      cache: SegmentCache.new(
        config.maxSegmentSets,
        initDuration(seconds = config.reconstructionTimeoutSeconds),
      ),
    )
  )

func chunkSize*(self: SegmentationHandler): int =
  return self.chunkSize

func pendingSets*(self: SegmentationHandler): int =
  return self.cache.len

func padTo(chunk: seq[byte], shardLen: int): seq[byte] =
  var padded = newSeq[byte](shardLen)
  for i, b in chunk:
    padded[i] = b
  return padded

proc performSegmentation*(
    self: SegmentationHandler, payload: seq[byte]
): Result[seq[seq[byte]], string] =
  ## Split `payload` into wire-ready segment messages. A payload that fits one
  ## chunk is still wrapped, as `segment_count == 1`.
  let hash = @(keccak256.digest(payload).data)

  # ceil(0 / chunkSize) is 0, which would violate `segment_count >= 1`.
  let dataCount =
    if payload.len == 0:
      1
    else:
      ceilDiv(payload.len, self.chunkSize)
  let parityCount = parityCountFor(dataCount, self.scaledParityRate)

  # The bound is on the sum, so the true data-chunk ceiling is below
  # maxTotalSegments whenever parity is on.
  if dataCount + parityCount > self.config.maxTotalSegments:
    return err(
      "segmentation.performSegmentation: too many segments for maxTotalSegments: " &
        $dataCount & " data + " & $parityCount & " parity > " &
        $self.config.maxTotalSegments
    )

  var segments = newSeq[seq[byte]]()
  var dataShards = newSeq[seq[byte]]()

  for i in 0 ..< dataCount:
    let start = i * self.chunkSize
    let stop = min(start + self.chunkSize, payload.len)
    let chunk =
      if start < stop:
        payload[start ..< stop]
      else:
        newSeq[byte]()

    segments.add(
      ?SegmentMessage(
        originalPayloadHash: hash,
        originalPayloadLength: uint64(payload.len),
        index: uint32(i),
        segmentCount: uint32(dataCount),
        isParity: false,
        segmentPayload: chunk,
      ).encode()
    )

    # Data segments go on the wire at their true length; only the encoder sees
    # the zero-padded copy of the short last chunk.
    if parityCount > 0:
      dataShards.add(padTo(chunk, self.chunkSize))

  if parityCount > 0:
    let parityShards = ?encodeParity(dataShards, parityCount, self.chunkSize)
    for i, shard in parityShards:
      segments.add(
        ?SegmentMessage(
          originalPayloadHash: hash,
          originalPayloadLength: uint64(payload.len),
          index: uint32(i),
          segmentCount: uint32(parityCount),
          isParity: true,
          segmentPayload: shard,
        ).encode()
      )

  return ok(segments)

func shardLengthOf(s: SegmentSet, dataCount: int): Result[int, string] =
  ## Parity shards are always exactly shard-length; so is any data segment but
  ## the last. Take the length from the parity class and cross-check the data
  ## one, which catches a malformed set before it reaches the decoder.
  var shardLen = -1
  for _, p in s.parity:
    if shardLen < 0:
      shardLen = p.len
    elif p.len != shardLen:
      return err(
        "segmentation.shardLengthOf: parity shards disagree on length: " & $p.len &
          " and " & $shardLen
      )
  if shardLen < 0:
    return
      err("segmentation.shardLengthOf: no parity shard to take the shard length from")
  for idx, d in s.data:
    if int(idx) < dataCount - 1 and d.len != shardLen:
      return err(
        "segmentation.shardLengthOf: data shard disagrees with the parity shard length: index " &
          $idx & " is " & $d.len & " bytes, expected " & $shardLen
      )
  return ok(shardLen)

proc recoverThroughParity(
    s: SegmentSet, dataCount, payloadLen: int
): Result[Opt[seq[byte]], string] =
  let parityClassCount = s.parityCount.valueOr:
    return ok(Opt.none(seq[byte]))
  let parityCount = int(parityClassCount)
  let shardLen = ?shardLengthOf(s, dataCount)

  # A peer that chose an unaligned chunk size cannot be decoded here; wait for
  # its data segments instead of dropping the set.
  if shardLen mod ShardAlignment != 0 or shardLen == 0:
    return ok(Opt.none(seq[byte]))

  # Cheap geometry check on the claimed length, so a hostile set is dropped
  # before any of it is assembled.
  if payloadLen > dataCount * shardLen or payloadLen <= (dataCount - 1) * shardLen:
    return err(
      "segmentation.recoverThroughParity: declared payload length does not fit the shard geometry: " &
        $payloadLen & " bytes over " & $dataCount & " shards of " & $shardLen
    )

  var data = newSeq[seq[byte]](dataCount)
  for i in 0 ..< dataCount:
    if s.data.hasKey(uint32(i)):
      # Re-pad to shard length: leopard reads shardLen bytes out of every
      # non-empty entry regardless of its actual length.
      data[i] = padTo(s.data.getOrDefault(uint32(i)), shardLen)
    # A missing shard stays an empty seq, which is the erasure marker.

  var parityShards = newSeq[seq[byte]](parityCount)
  for idx, p in s.parity:
    if int(idx) < parityCount:
      parityShards[int(idx)] = p

  let shards = ?decodeParity(data, parityShards, shardLen)

  var assembled = newSeq[byte]()
  for shard in shards:
    assembled.add(shard)
  return ok(Opt.some(assembled))

proc assemble(
    s: SegmentSet, hash: seq[byte], payloadLen: int
): Result[Opt[seq[byte]], string] =
  ## `ok(none)` means "not yet"; `err` means the set is unusable and is dropped.
  let dataClassCount = s.dataCount.valueOr:
    return ok(Opt.none(seq[byte]))
  let dataCount = int(dataClassCount)

  var complete = true
  for i in 0 ..< dataCount:
    if not s.data.hasKey(uint32(i)):
      complete = false
      break

  var assembled: seq[byte]
  if complete:
    # No decoder needed, and no shard-alignment requirement either.
    for i in 0 ..< dataCount:
      assembled.add(s.data.getOrDefault(uint32(i)))
  else:
    assembled = (?recoverThroughParity(s, dataCount, payloadLen)).valueOr:
      return ok(Opt.none(seq[byte]))

  if assembled.len < payloadLen:
    return err(
      "segmentation.assemble: assembled payload shorter than declared: " & $assembled.len &
        " < " & $payloadLen
    )
  assembled.setLen(payloadLen)

  if @(keccak256.digest(assembled).data) != hash:
    return err(
      "segmentation.assemble: reconstructed payload does not match the declared hash"
    )
  return ok(Opt.some(assembled))

proc handleIncomingSegment*(
    self: SegmentationHandler, segmentBytes: seq[byte]
): Result[Opt[ReassemblyResult], string] =
  ## Take one received segment message. `ok(Opt.none)` covers both "stored, set
  ## still incomplete" and every spec-level discard -- undecodable, invalid,
  ## duplicate, over bounds, or a set that failed its hash check. `err` is
  ## reserved for internal faults, so callers never have to treat it as routine.
  let now = getMonoTime()
  # Nothing else would call this in a synchronous API.
  self.cache.sweep(now)

  let m = SegmentMessage.decode(segmentBytes).valueOr:
    return ok(Opt.none(ReassemblyResult))

  if not m.isValid(self.config.maxTotalSegments):
    return ok(Opt.none(ReassemblyResult))
  if m.segmentPayload.len > self.config.segmentSizeBytes:
    return ok(Opt.none(ReassemblyResult))

  let (outcome, key) = self.cache.add(m, self.config.maxTotalSegments, now)
  if outcome == Ignored:
    return ok(Opt.none(ReassemblyResult))

  let s = self.cache.get(key)
  if s.isNil() or not s.isReconstructible():
    return ok(Opt.none(ReassemblyResult))

  let assembled = assemble(s, m.originalPayloadHash, int(m.originalPayloadLength)).valueOr:
    # The spec leaves hash-failure behaviour undefined. Drop the set: keeping it
    # would let one bad shard wedge reconstruction until the timeout.
    self.cache.remove(key)
    return ok(Opt.none(ReassemblyResult))

  let payload = assembled.valueOr:
    return ok(Opt.none(ReassemblyResult))

  self.cache.remove(key)
  return ok(
    Opt.some(
      ReassemblyResult(payload: payload, originalPayloadHash: m.originalPayloadHash)
    )
  )

proc cleanupSegments*(self: SegmentationHandler) =
  ## Drop segment sets that have gone `reconstructionTimeoutSeconds` without a
  ## new segment.
  self.cache.sweep(getMonoTime())

{.pop.}
