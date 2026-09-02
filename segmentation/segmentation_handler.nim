## The stateful entry point: segments outgoing payloads and reassembles incoming
## ones.
##
## The handler's methods live here rather than in the package module so that its
## fields stay private -- nothing outside can reach into the cache or rewrite the
## chunk size.

{.push raises: [].}
import std/[math, monotimes, times]
import results, nimcrypto/keccak
import
  ./parity,
  ./segment_set,
  ./reassembled_payload,
  ./segment_cache,
  ./segment_events,
  ./segment_message,
  ./segmentation_config

export
  reassembled_payload, segmentation_config, segment_events, segment_message, results

static:
  # `new` rejects anything below MinSegmentSizeBytes, so this is what keeps the
  # chunk size positive for every config it does accept.
  doAssert alignShardLen(MinSegmentSizeBytes - SegmentHeaderMaxBytes) >= ShardAlignment

type SegmentationHandler* = ref object
  ## Segments outgoing payloads and reassembles incoming ones. Holds the
  ## partially received sets, so one instance is needed per peer-facing channel.
  config: SegmentationConfig
  scaledParityRate: int
  chunkSize: int
  cache: SegmentCache
  # The cache reports the drops it owns; HashMismatch is detected here, after a
  # set has already been handed back, so the handler needs the callback too.
  onSetDropped: SegmentSetDroppedHandler
  onSegmentDiscarded: SegmentDiscardedHandler
  onPayloadReassembled: PayloadReassembledHandler

proc new*(
    T: type SegmentationHandler,
    config: SegmentationConfig,
    onSetDropped: SegmentSetDroppedHandler,
    onSegmentDiscarded: SegmentDiscardedHandler,
    onPayloadReassembled: PayloadReassembledHandler,
): Result[T, string] =
  ## Validate `config` and derive the chunk size from it. Fails rather than
  ## clamping, so a misconfiguration surfaces at construction and not on the
  ## first send.
  ##
  ## The callbacks report every reception outcome: `onPayloadReassembled` when a
  ## payload completes, `onSetDropped` once per abandoned payload, and
  ## `onSegmentDiscarded` per rejected segment.
  ##
  ## All three are required and must be non-nil. Reception discards far more than
  ## it delivers, and a set that expires, is evicted or fails its hash check has
  ## no other channel -- so a consumer that had not wired `onSetDropped` would
  ## lose payloads silently. Deciding to ignore an outcome is fine; it just has
  ## to be a decision, written as an explicit no-op rather than an omission.
  ##
  ## `onPayloadReassembled` carries the same payload the call returns; use one or
  ## the other, not both.
  if config.segmentSizeBytes < MinSegmentSizeBytes:
    return err(
      "segmentation_handler.new: segmentSizeBytes below the minimum: " &
        $config.segmentSizeBytes & " < " & $MinSegmentSizeBytes
    )
  if config.parityRate < 0.0 or config.parityRate >= 1.0:
    return err(
      "segmentation_handler.new: parityRate out of range: " & $config.parityRate &
        " not in [0, 1)"
    )
  if config.reconstructionTimeoutSeconds <= 0:
    return err(
      "segmentation_handler.new: reconstructionTimeoutSeconds not positive: " &
        $config.reconstructionTimeoutSeconds
    )
  if config.maxTotalSegments < 1 or config.maxTotalSegments > MaxSupportedTotalSegments:
    return err(
      "segmentation_handler.new: maxTotalSegments out of range: " &
        $config.maxTotalSegments & " not in [1, " & $MaxSupportedTotalSegments & "]"
    )
  if config.maxBufferedBytes < config.segmentSizeBytes:
    return err(
      "segmentation_handler.new: maxBufferedBytes below segmentSizeBytes: " &
        $config.maxBufferedBytes & " < " & $config.segmentSizeBytes
    )
  if onSetDropped.isNil():
    return err("segmentation_handler.new: onSetDropped must not be nil")
  if onSegmentDiscarded.isNil():
    return err("segmentation_handler.new: onSegmentDiscarded must not be nil")
  if onPayloadReassembled.isNil():
    return err("segmentation_handler.new: onPayloadReassembled must not be nil")
  if config.maxSegmentSets < 1:
    return err(
      "segmentation_handler.new: maxSegmentSets not positive: " & $config.maxSegmentSets
    )

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
        config.maxBufferedBytes,
        initDuration(seconds = config.reconstructionTimeoutSeconds),
        onSetDropped,
      ),
      onSetDropped: onSetDropped,
      onSegmentDiscarded: onSegmentDiscarded,
      onPayloadReassembled: onPayloadReassembled,
    )
  )

func chunkSize*(self: SegmentationHandler): int =
  ## Payload bytes carried by one data segment: `segmentSizeBytes` less the wire
  ## header, rounded down to a multiple of `ShardAlignment`.
  return self.chunkSize

func pendingSets*(self: SegmentationHandler): int =
  ## Segment sets currently held incomplete. Mainly for tests and metrics.
  return self.cache.len

func bufferedBytes*(self: SegmentationHandler): int =
  ## Segment payload bytes held across those sets, against `maxBufferedBytes`.
  return self.cache.bufferedBytes

# `new` rejects nil callbacks, so these need no guard.
proc notifyDiscarded(self: SegmentationHandler, reason: SegmentDiscardReason) =
  self.onSegmentDiscarded(reason)

proc notifySetDropped(
    self: SegmentationHandler, s: SegmentSet, reason: SegmentSetDropReason
) =
  self.onSetDropped(s.originalPayloadHash, reason)

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
      "segmentation_handler.performSegmentation: too many segments for maxTotalSegments: " &
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
      ?SegmentMessage
        .init(
          originalPayloadHash = hash,
          originalPayloadLength = uint64(payload.len),
          index = uint32(i),
          segmentCount = uint32(dataCount),
          isParity = false,
          segmentPayload = chunk,
        )
        .encode()
    )

    # Data segments go on the wire at their true length; only the encoder sees
    # the zero-padded copy of the short last chunk.
    if parityCount > 0:
      dataShards.add(padTo(chunk, self.chunkSize))

  if parityCount > 0:
    let parityShards = ?encodeParity(dataShards, parityCount, self.chunkSize)
    for i, shard in parityShards:
      segments.add(
        ?SegmentMessage
          .init(
            originalPayloadHash = hash,
            originalPayloadLength = uint64(payload.len),
            index = uint32(i),
            segmentCount = uint32(parityCount),
            isParity = true,
            segmentPayload = shard,
          )
          .encode()
      )

  return ok(segments)

proc handleIncomingSegment*(
    self: SegmentationHandler, segmentBytes: seq[byte]
): Result[Opt[ReassembledPayload], string] =
  ## Take one received segment message. `ok(Opt.none)` covers both "stored, set
  ## still incomplete" and every spec-level discard -- undecodable, invalid,
  ## duplicate, over bounds, or a set that failed its hash check. `err` is
  ## reserved for internal faults, so callers never have to treat it as routine.
  let now = getMonoTime()
  # Nothing else would call this in a synchronous API.
  self.cache.sweep(now)

  let m = SegmentMessage.decode(segmentBytes).valueOr:
    self.notifyDiscarded(SegmentDiscardReason.Undecodable)
    return ok(Opt.none(ReassembledPayload))

  if not m.isValid(self.config.maxTotalSegments):
    self.notifyDiscarded(SegmentDiscardReason.Invalid)
    return ok(Opt.none(ReassembledPayload))
  if m.segmentPayload.len > self.config.segmentSizeBytes:
    self.notifyDiscarded(SegmentDiscardReason.Oversized)
    return ok(Opt.none(ReassembledPayload))

  let (outcome, key, discardReason) =
    self.cache.add(m, self.config.maxTotalSegments, now)
  if outcome == AddOutcome.Ignored:
    let reason = discardReason.valueOr:
      SegmentDiscardReason.Invalid
    self.notifyDiscarded(reason)
    return ok(Opt.none(ReassembledPayload))

  let s = self.cache.get(key)
  if s.isNil() or not s.isReconstructible():
    return ok(Opt.none(ReassembledPayload))

  let assembled = s.assemble().valueOr:
    # The spec leaves hash-failure behaviour undefined. Drop the set: keeping it
    # would let one bad shard wedge reconstruction until the timeout.
    self.cache.remove(key)
    self.notifySetDropped(s, SegmentSetDropReason.HashMismatch)
    return ok(Opt.none(ReassembledPayload))

  let payload = assembled.valueOr:
    return ok(Opt.none(ReassembledPayload))

  self.cache.remove(key)
  let reassembled = ReassembledPayload.init(
    payload = payload, originalPayloadHash = m.originalPayloadHash
  )
  self.onPayloadReassembled(reassembled)
  return ok(Opt.some(reassembled))

proc cleanupSegments*(self: SegmentationHandler) =
  ## Drop segment sets that have gone `reconstructionTimeoutSeconds` without a
  ## new segment.
  self.cache.sweep(getMonoTime())

{.pop.}
