import std/[algorithm, os, random, sequtils, strutils, times]
import unittest2, results
import segmentation, segmentation/segment_cache

proc ignorePayload(p: ReassembledPayload) {.gcsafe, raises: [].} =
  discard

proc ignoreDropped(
    hash: seq[byte], reason: SegmentSetDropReason
) {.gcsafe, raises: [].} =
  discard

proc ignoreDiscarded(reason: SegmentDiscardReason) {.gcsafe, raises: [].} =
  discard

proc ignoreProgress(hash: seq[byte], held, expected: int) {.gcsafe, raises: [].} =
  discard

proc mkHandler(
    segmentSizeBytes = 320, parityRate = 0.0, maxTotalSegments = 256
): SegmentationHandler =
  return SegmentationHandler
    .new(
      SegmentationConfig.init(
        segmentSizeBytes = segmentSizeBytes,
        parityRate = parityRate,
        maxTotalSegments = maxTotalSegments,
      ),
      onSetDropped = ignoreDropped,
      onSegmentDiscarded = ignoreDiscarded,
      onPayloadReassembled = ignorePayload,
      onSegmentProgress = ignoreProgress,
    )
    .expect("valid config")

proc mkHandler(
    dropped: ref seq[(seq[byte], SegmentSetDropReason)], segmentSizeBytes = 320
): SegmentationHandler =
  ## A handler recording every set drop, for tests that assert on the reason.
  return SegmentationHandler
    .new(
      SegmentationConfig.init(segmentSizeBytes = segmentSizeBytes),
      onSetDropped = proc(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe.} =
        dropped[].add((hash, reason)),
      onSegmentDiscarded = ignoreDiscarded,
      onPayloadReassembled = ignorePayload,
      onSegmentProgress = ignoreProgress,
    )
    .expect("valid config")

proc payloadOf(n: int): seq[byte] =
  var p = newSeq[byte](n)
  for i in 0 ..< n:
    p[i] = byte((i * 37 + 11) and 0xFF)
  return p

proc feed(h: SegmentationHandler, segments: seq[seq[byte]]): Opt[ReassembledPayload] =
  ## Feed every segment, returning the first successful reassembly.
  var delivered = Opt.none(ReassembledPayload)
  for s in segments:
    let r = h.handleIncomingSegment(s).expect("no internal fault")
    if r.isSome() and delivered.isNone():
      delivered = r
  return delivered

suite "configuration":
  test "defaults are accepted":
    check SegmentationHandler
      .new(
        SegmentationConfig.init(),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isOk()

  test "chunk size is aligned and leaves room for the header":
    let h = mkHandler(segmentSizeBytes = 102_400)
    check h.chunkSize == 102_400 - SegmentHeaderMaxBytes
    check h.chunkSize == 102_272
    check h.chunkSize mod 64 == 0

  test "invalid configuration is rejected":
    check SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 127),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isErr()
    check SegmentationHandler
      .new(
        SegmentationConfig.init(parityRate = 1.1),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isErr()
    check SegmentationHandler
      .new(
        SegmentationConfig.init(parityRate = -0.1),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isErr()
    check SegmentationHandler
      .new(
        SegmentationConfig.init(reconstructionTimeoutSeconds = 0),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isErr()
    check SegmentationHandler
      .new(
        SegmentationConfig.init(maxTotalSegments = 0),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isErr()

    # The upper bound is what leopard can actually encode, so one over it must
    # fail at construction rather than at the first oversized payload.
    let overMax = SegmentationHandler.new(
      SegmentationConfig.init(maxTotalSegments = MaxSupportedTotalSegments + 1),
      ignoreDropped,
      ignoreDiscarded,
      ignorePayload,
      ignoreProgress,
    )
    check overMax.isErr()
    check overMax.error.contains("maxTotalSegments")

    check SegmentationHandler
      .new(
        SegmentationConfig.init(maxTotalSegments = MaxSupportedTotalSegments),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isOk()

    let noSets = SegmentationHandler.new(
      SegmentationConfig.init(maxSegmentSets = 0),
      ignoreDropped,
      ignoreDiscarded,
      ignorePayload,
      ignoreProgress,
    )
    check noSets.isErr()
    check noSets.error.contains("maxSegmentSets")

suite "callbacks are mandatory":
  test "a nil callback is rejected at construction":
    # Ignoring an outcome must be a decision written as an explicit no-op, not an
    # omission -- otherwise a consumer loses dropped payloads silently.
    check SegmentationHandler
      .new(
        SegmentationConfig.init(), nil, ignoreDiscarded, ignorePayload, ignoreProgress
      )
      .isErr()
    check SegmentationHandler
      .new(SegmentationConfig.init(), ignoreDropped, nil, ignorePayload, ignoreProgress)
      .isErr()
    check SegmentationHandler
      .new(
        SegmentationConfig.init(), ignoreDropped, ignoreDiscarded, nil, ignoreProgress
      )
      .isErr()
    check SegmentationHandler
      .new(
        SegmentationConfig.init(), ignoreDropped, ignoreDiscarded, ignorePayload, nil
      )
      .isErr()

  test "the error names the missing callback":
    let e = SegmentationHandler.new(
      SegmentationConfig.init(), nil, ignoreDiscarded, ignorePayload, ignoreProgress
    ).error
    check e.contains("onSetDropped")

  test "explicit no-ops are accepted":
    check SegmentationHandler
      .new(
        SegmentationConfig.init(),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isOk()

suite "segmentation without parity":
  test "a payload that fits one chunk is still wrapped":
    let h = mkHandler()
    let payload = payloadOf(10)
    let segments = h.performSegmentation(payload).get()
    check segments.len == 1

    let m = SegmentMessage.decode(segments[0]).get()
    check m.dataSegmentCount == 1
    check m.index == 0
    check not m.isParity
    check m.payload == payload
    # The wrapper is real: the wire bytes are not the bare payload.
    check segments[0] != payload

  test "an empty payload still produces one segment":
    let h = mkHandler()
    let segments = h.performSegmentation(@[]).get()
    check segments.len == 1
    let m = SegmentMessage.decode(segments[0]).get()
    check m.dataSegmentCount == 1
    check m.originalPayloadLength == 0

    check h.feed(segments).get().payload.len == 0

  test "a multi-chunk payload round-trips":
    let h = mkHandler()
    let payload = payloadOf(1000) # chunkSize is 192, so six segments
    let segments = h.performSegmentation(payload).get()
    check segments.len == 6

    let delivered = mkHandler().feed(segments)
    check delivered.isSome()
    check delivered.get().payload == payload

  test "every segment fits segmentSizeBytes":
    let h = mkHandler(segmentSizeBytes = 320, parityRate = 0.125)
    for size in [1, 63, 192, 193, 1000, 5000]:
      for s in h.performSegmentation(payloadOf(size)).get():
        check s.len <= 320

  test "a payload that is an exact multiple of the chunk size round-trips":
    let h = mkHandler()
    let payload = payloadOf(h.chunkSize * 3)
    let segments = h.performSegmentation(payload).get()
    check segments.len == 3
    check mkHandler().feed(segments).get().payload == payload

  test "segments arriving out of order round-trip":
    let h = mkHandler()
    let payload = payloadOf(1000)
    var segments = h.performSegmentation(payload).get()
    var rng = initRand(7)
    rng.shuffle(segments)
    check mkHandler().feed(segments).get().payload == payload

  test "an incomplete set delivers nothing":
    let h = mkHandler()
    let segments = h.performSegmentation(payloadOf(1000)).get()
    let rx = mkHandler()
    check rx.feed(segments[0 ..< segments.len - 1]).isNone()
    check rx.pendingSets() == 1

  test "duplicate segments are ignored":
    let h = mkHandler()
    let payload = payloadOf(1000)
    let segments = h.performSegmentation(payload).get()
    let rx = mkHandler()

    # Every segment twice, the last one withheld: still incomplete.
    var doubled: seq[seq[byte]]
    for s in segments[0 ..< segments.len - 1]:
      doubled.add(s)
      doubled.add(s)
    check rx.feed(doubled).isNone()

    check rx.handleIncomingSegment(segments[^1]).get().get().payload == payload

  test "a payload needing more segments than allowed is rejected":
    let h = mkHandler(maxTotalSegments = 4)
    check h.performSegmentation(payloadOf(h.chunkSize * 4)).isOk()
    check h.performSegmentation(payloadOf(h.chunkSize * 4 + 1)).isErr()

  test "the sender bound accounts for parity too":
    # 4 data chunks plus one parity segment is 5, above the limit of 4.
    let h = mkHandler(parityRate = 0.125, maxTotalSegments = 4)
    check h.performSegmentation(payloadOf(h.chunkSize * 4)).isErr()
    check h.performSegmentation(payloadOf(h.chunkSize * 3)).isOk()

suite "segmentation with parity":
  test "parity segments are emitted and labelled":
    let h = mkHandler(parityRate = 0.125)
    let segments = h.performSegmentation(payloadOf(1000)).get()
    check segments.len == 7 # six data plus one parity

    var dataCount = 0
    var parityCount = 0
    for s in segments:
      if SegmentMessage.decode(s).get().isParity:
        inc parityCount
      else:
        inc dataCount
    check dataCount == 6
    check parityCount == 1

  test "data segments keep their true length, parity shards are full":
    let h = mkHandler(parityRate = 0.5)
    let payload = payloadOf(500) # 192 + 192 + 116
    let segments = h.performSegmentation(payload).get()
    for s in segments:
      let m = SegmentMessage.decode(s).get()
      if m.isParity:
        check m.payload.len == h.chunkSize
      elif m.index == m.dataSegmentCount - 1:
        check m.payload.len == 500 - 2 * h.chunkSize
      else:
        check m.payload.len == h.chunkSize

  test "a lost data segment is recovered through parity":
    let h = mkHandler(parityRate = 0.125)
    let payload = payloadOf(1000)
    let segments = h.performSegmentation(payload).get()

    # Drop the second data segment; the parity segment stands in for it.
    var lossy = segments
    lossy.delete(1)
    let delivered = mkHandler(parityRate = 0.125).feed(lossy)
    check delivered.isSome()
    check delivered.get().payload == payload

  test "a lost final (short) data segment is recovered through parity":
    let h = mkHandler(parityRate = 0.125)
    let payload = payloadOf(1000)
    let segments = h.performSegmentation(payload).get()

    var lossy = segments
    lossy.delete(5) # the short last data segment
    let delivered = mkHandler(parityRate = 0.125).feed(lossy)
    check delivered.isSome()
    check delivered.get().payload == payload

  test "losses beyond the parity count deliver nothing":
    let h = mkHandler(parityRate = 0.125)
    let segments = h.performSegmentation(payloadOf(1000)).get()

    var lossy = segments
    lossy.delete(3)
    lossy.delete(1)
    check mkHandler(parityRate = 0.125).feed(lossy).isNone()

  test "a receiver with parity disabled still decodes a parity-bearing set":
    # The chunk size is 64-aligned regardless of the local parityRate, so a
    # receiver that never emits parity can still decode with it.
    let h = mkHandler(parityRate = 0.125)
    let payload = payloadOf(1000)
    var lossy = h.performSegmentation(payload).get()
    lossy.delete(2)
    check mkHandler(parityRate = 0.0).feed(lossy).get().payload == payload

suite "integrity":
  proc corrupt(segment: seq[byte]): seq[byte] =
    var m = SegmentMessage.decode(segment).get()
    m.payload[0] = m.payload[0] xor 0xFF'u8
    return m.encode().get()

  test "a corrupted segment fails the hash check and delivers nothing":
    let h = mkHandler()
    let segments = h.performSegmentation(payloadOf(1000)).get()
    var tampered = segments
    tampered[2] = corrupt(segments[2])
    check mkHandler().feed(tampered).isNone()

  test "a set that fails its hash check is dropped, and can be resent":
    let h = mkHandler()
    let payload = payloadOf(1000)
    let segments = h.performSegmentation(payload).get()
    let rx = mkHandler()

    var tampered = segments
    tampered[2] = corrupt(segments[2])
    check rx.feed(tampered).isNone()
    check rx.pendingSets() == 0

    check rx.feed(segments).get().payload == payload

  test "an invalid segment is discarded rather than errored":
    let h = mkHandler()
    var m = SegmentMessage.decode(h.performSegmentation(payloadOf(10)).get()[0]).get()
    m.originalPayloadHash.setLen(31)
    let r = h.handleIncomingSegment(m.encode().get())
    check r.isOk()
    check r.get().isNone()
    check h.pendingSets() == 0

  test "undecodable bytes are discarded rather than errored":
    let h = mkHandler()
    let r = h.handleIncomingSegment(@[0x0A'u8, 0x7F])
    check r.isOk()
    check r.get().isNone()

  test "a segment claiming a count that disagrees with its set is ignored":
    let h = mkHandler()
    let segments = h.performSegmentation(payloadOf(1000)).get()
    let rx = mkHandler()
    check rx.feed(segments[0 ..< 3]).isNone()

    var liar = SegmentMessage.decode(segments[3]).get()
    liar.dataSegmentCount = 99
    check rx.handleIncomingSegment(liar.encode().get()).get().isNone()
    # The genuine segment 3 is still accepted afterwards.
    check rx.feed(segments[3 .. ^1]).get().payload == payloadOf(1000)

suite "segment cache bounds and expiry":
  proc segmentFor(hashByte: byte, index, count: uint32): SegmentMessage =
    var h = newSeq[byte](SegmentHashLen)
    h[0] = hashByte
    return SegmentMessage.init(
      originalPayloadHash = h,
      originalPayloadLength = 100'u64,
      index = index,
      dataSegmentCount = count,
      paritySegmentCount = 0,
      isParity = false,
      payload = @[1'u8],
    )

  test "a set idle past the timeout is dropped":
    let cache = SegmentCache.new(10, 1024 * 1024, initDuration(seconds = 30))
    let start = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), start)
    check cache.len == 1

    cache.sweep(start + initDuration(seconds = 29))
    check cache.len == 1
    cache.sweep(start + initDuration(seconds = 31))
    check cache.len == 0

  test "a duplicate does not extend a set's life":
    let cache = SegmentCache.new(10, 1024 * 1024, initDuration(seconds = 30))
    let start = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), start)

    let dup = cache.add(segmentFor(1, 0, 4), start + initDuration(seconds = 20))
    check dup.outcome == AddOutcome.Ignored

    cache.sweep(start + initDuration(seconds = 31))
    check cache.len == 0

  test "the least recently updated set is evicted first":
    let cache = SegmentCache.new(2, 1024 * 1024, initDuration(seconds = 300))
    let start = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), start)
    discard cache.add(segmentFor(2, 0, 4), start + initDuration(seconds = 1))
    check cache.len == 2

    discard cache.add(segmentFor(3, 0, 4), start + initDuration(seconds = 2))
    check cache.len == 2
    check cache.get(segmentSetKey(segmentFor(1, 0, 4))).isNil()
    check not cache.get(segmentSetKey(segmentFor(3, 0, 4))).isNil()

  test "a segment disagreeing on the counts is discarded, not admitted":
    # The spec calls these different sets; keying on the counts would let one
    # sender open unbounded sets under a single hash, so the segment is dropped.
    let cache = SegmentCache.new(10, 1024 * 1024, initDuration(seconds = 300))
    let now = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), now)
    check cache.len == 1

    var disagreeing = segmentFor(1, 1, 5)
    let r = cache.add(disagreeing, now)
    check r.outcome == AddOutcome.Ignored
    check r.discardReason == Opt.some(SegmentDiscardReason.CountMismatch)
    check cache.len == 1
    check cache.get(segmentSetKey(segmentFor(1, 0, 4))).heldSegments() == 1

suite "round-trip properties":
  test "random sizes, rates and erasure patterns all round-trip":
    var rng = initRand(20260902)
    for trial in 0 ..< 60:
      let parityRate = sample(rng, @[0.0, 0.125, 0.25, 0.5])
      let tx = mkHandler(segmentSizeBytes = 320, parityRate = parityRate)
      let payload = payloadOf(rng.rand(0 .. 3000))
      var segments = tx.performSegmentation(payload).get()

      let dataCount =
        segments.filterIt(not SegmentMessage.decode(it).get().isParity).len
      let parityCount = segments.len - dataCount

      # Drop as many data segments as parity can cover, then shuffle.
      var kept = segments
      if parityCount > 0:
        var indices = toSeq(0 ..< dataCount)
        rng.shuffle(indices)
        let drop = indices[0 ..< parityCount].sorted(Descending)
        for i in drop:
          kept.delete(i)
      rng.shuffle(kept)

      let delivered =
        mkHandler(segmentSizeBytes = 320, parityRate = parityRate).feed(kept)
      check delivered.isSome()
      if delivered.isSome():
        check delivered.get().payload == payload

suite "reception events":
  proc handlerWithEvents(
      dropped: ref seq[(seq[byte], SegmentSetDropReason)],
      discarded: ref seq[SegmentDiscardReason],
      segmentSizeBytes = 320,
      parityRate = 0.0,
      maxTotalSegments = 256,
      reconstructionTimeoutSeconds = 300,
      maxBufferedBytes = DefaultMaxBufferedBytes,
  ): SegmentationHandler =
    return SegmentationHandler
      .new(
        SegmentationConfig.init(
          segmentSizeBytes = segmentSizeBytes,
          parityRate = parityRate,
          maxTotalSegments = maxTotalSegments,
          reconstructionTimeoutSeconds = reconstructionTimeoutSeconds,
          maxBufferedBytes = maxBufferedBytes,
        ),
        onSetDropped = proc(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe.} =
          dropped[].add((hash, reason)),
        onSegmentDiscarded = proc(reason: SegmentDiscardReason) {.gcsafe.} =
          discarded[].add(reason),
        onPayloadReassembled = ignorePayload,
        onSegmentProgress = ignoreProgress,
      )
      .expect("valid config")

  test "undecodable bytes are reported":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded)
    check h.handleIncomingSegment(@[0x0A'u8, 0x7F]).get().isNone()
    check discarded[] == @[SegmentDiscardReason.Undecodable]

  test "an invalid segment is reported":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded)
    var m = SegmentMessage.decode(h.performSegmentation(payloadOf(10)).get()[0]).get()
    m.originalPayloadHash.setLen(31)
    check h.handleIncomingSegment(m.encode().get()).get().isNone()
    check discarded[] == @[SegmentDiscardReason.Invalid]

  test "an oversized segment is reported":
    # A peer can declare a chunk larger than segmentSizeBytes in an otherwise
    # well-formed message; the guard runs after isValid has passed it.
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded, segmentSizeBytes = 320)

    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 9
    let oversized = SegmentMessage.init(
      originalPayloadHash = hash,
      originalPayloadLength = 321,
      index = 0,
      dataSegmentCount = 1,
      paritySegmentCount = 0,
      isParity = false,
      payload = payloadOf(321), # one byte over segmentSizeBytes
    )
    check h.handleIncomingSegment(oversized.encode().get()).get().isNone()
    check discarded[] == @[SegmentDiscardReason.Oversized]
    check dropped[].len == 0
    check h.pendingSets() == 0

  test "a duplicate segment is reported":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded)
    let segments = h.performSegmentation(payloadOf(1000)).get()
    check h.handleIncomingSegment(segments[0]).get().isNone()
    check discarded[].len == 0
    check h.handleIncomingSegment(segments[0]).get().isNone()
    check discarded[] == @[SegmentDiscardReason.Duplicate]

  test "a set that fails its hash check reports HashMismatch with the hash":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded)
    let payload = payloadOf(1000)
    let segments = mkHandler().performSegmentation(payload).get()
    let expectedHash = SegmentMessage.decode(segments[0]).get().originalPayloadHash

    var tampered = segments
    var m = SegmentMessage.decode(segments[2]).get()
    m.payload[0] = m.payload[0] xor 0xFF'u8
    tampered[2] = m.encode().get()

    check h.feed(tampered).isNone()
    check dropped[].len == 1
    check dropped[][0][0] == expectedHash
    check dropped[][0][1] == SegmentSetDropReason.HashMismatch
    check h.pendingSets() == 0

  test "an expired set reports Expired when swept":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded, reconstructionTimeoutSeconds = 1)
    let segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    check h.feed(segments[0 ..< 3]).isNone()
    check h.pendingSets() == 1
    check dropped[].len == 0

    sleep(1100)
    h.cleanupSegments()
    check h.pendingSets() == 0
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Expired

  test "eviction reports Evicted":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320, maxSegmentSets = 1),
        onSetDropped = proc(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe.} =
          dropped[].add((hash, reason)),
        onSegmentDiscarded = ignoreDiscarded,
        onPayloadReassembled = ignorePayload,
        onSegmentProgress = ignoreProgress,
      )
      .expect("valid config")

    let first = mkHandler().performSegmentation(payloadOf(1000)).get()
    let second = mkHandler().performSegmentation(payloadOf(2000)).get()
    check h.feed(first[0 ..< 2]).isNone()
    check h.feed(second[0 ..< 2]).isNone()

    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Evicted
    check h.pendingSets() == 1

  test "a segment that cannot fit the byte budget reports CacheFull":
    # The budget holds one 192-byte chunk but not two, and the set being built is
    # never evicted to free room for its own segment, so that set goes too.
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded, maxBufferedBytes = 320)

    let segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    let expectedHash = SegmentMessage.decode(segments[0]).get().originalPayloadHash
    check h.handleIncomingSegment(segments[0]).get().isNone()
    check h.bufferedBytes() == h.chunkSize
    check discarded[].len == 0

    check h.handleIncomingSegment(segments[1]).get().isNone()
    check discarded[] == @[SegmentDiscardReason.CacheFull]
    check dropped[] == @[(expectedHash, SegmentSetDropReason.Evicted)]
    check h.pendingSets() == 0
    check h.bufferedBytes() == 0

  test "no-op callbacks leave discard and delivery unaffected":
    let h = mkHandler()
    check h.handleIncomingSegment(@[0x0A'u8, 0x7F]).get().isNone()
    check h.feed(mkHandler().performSegmentation(payloadOf(1000)).get()).isSome()

  test "a segment over maxTotalSegments is rejected before a set exists":
    # Both counts ride on every segment, so the sum is bounded by isValid. The
    # set is never created, so this is a discard rather than a set drop.
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let discarded = new seq[SegmentDiscardReason]
    let h = handlerWithEvents(dropped, discarded, maxTotalSegments = 4)

    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 7
    let over = SegmentMessage.init(
      originalPayloadHash = hash,
      originalPayloadLength = 300,
      index = 0,
      dataSegmentCount = 3,
      paritySegmentCount = 3, # 3 + 3 exceeds the limit of 4
      isParity = false,
      payload = @[1'u8],
    )
    check h.handleIncomingSegment(over.encode().get()).get().isNone()
    check discarded[] == @[SegmentDiscardReason.Invalid]
    check dropped[].len == 0
    check h.pendingSets() == 0

  test "a completed payload is reported once, with its hash":
    let reassembled = new seq[ReassembledPayload]
    let payload = payloadOf(1000)
    let segments = mkHandler().performSegmentation(payload).get()
    let expectedHash = SegmentMessage.decode(segments[0]).get().originalPayloadHash

    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320),
        onSetDropped = ignoreDropped,
        onSegmentDiscarded = ignoreDiscarded,
        onPayloadReassembled = proc(p: ReassembledPayload) {.gcsafe.} =
          reassembled[].add(p),
        onSegmentProgress = ignoreProgress,
      )
      .expect("valid config")

    let delivered = h.feed(segments)
    check delivered.isSome()
    check reassembled[].len == 1
    check reassembled[][0].payload == payload
    check reassembled[][0].originalPayloadHash == expectedHash
    # The callback and the return value are one event, not two.
    check reassembled[][0].payload == delivered.get().payload

  test "a set that never completes reports nothing":
    let reassembled = new seq[ReassembledPayload]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320),
        onSetDropped = ignoreDropped,
        onSegmentDiscarded = ignoreDiscarded,
        onPayloadReassembled = proc(p: ReassembledPayload) {.gcsafe.} =
          reassembled[].add(p),
        onSegmentProgress = ignoreProgress,
      )
      .expect("valid config")
    let segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    check h.feed(segments[0 ..< segments.len - 1]).isNone()
    check reassembled[].len == 0

  test "a corrupted set reports the drop, never the payload":
    let reassembled = new seq[ReassembledPayload]
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320),
        onSetDropped = proc(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe.} =
          dropped[].add((hash, reason)),
        onSegmentDiscarded = ignoreDiscarded,
        onPayloadReassembled = proc(p: ReassembledPayload) {.gcsafe.} =
          reassembled[].add(p),
        onSegmentProgress = ignoreProgress,
      )
      .expect("valid config")

    var segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    var m = SegmentMessage.decode(segments[2]).get()
    m.payload[0] = m.payload[0] xor 0xFF'u8
    segments[2] = m.encode().get()

    check h.feed(segments).isNone()
    check reassembled[].len == 0
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.HashMismatch

suite "buffered-byte bound":
  test "bytes are tracked as segments arrive and released on delivery":
    let h = mkHandler()
    let payload = payloadOf(1000)
    let segments = mkHandler().performSegmentation(payload).get()
    check h.bufferedBytes() == 0

    discard h.handleIncomingSegment(segments[0])
    check h.bufferedBytes() == h.chunkSize
    discard h.handleIncomingSegment(segments[1])
    check h.bufferedBytes() == 2 * h.chunkSize

    check h.feed(segments).isSome()
    check h.bufferedBytes() == 0
    check h.pendingSets() == 0

  test "expiry releases the bytes":
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(
          segmentSizeBytes = 320, reconstructionTimeoutSeconds = 1
        ),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .expect("valid config")
    discard h.feed(mkHandler().performSegmentation(payloadOf(1000)).get()[0 ..< 2])
    check h.bufferedBytes() > 0
    sleep(1100)
    h.cleanupSegments()
    check h.bufferedBytes() == 0

  test "the byte bound evicts the least recently updated set":
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(
          segmentSizeBytes = 320, maxSegmentSets = 100, maxBufferedBytes = 500
        ),
        onSetDropped = proc(hash: seq[byte], reason: SegmentSetDropReason) {.gcsafe.} =
          dropped[].add((hash, reason)),
        onSegmentDiscarded = ignoreDiscarded,
        onPayloadReassembled = ignorePayload,
        onSegmentProgress = ignoreProgress,
      )
      .expect("valid config")

    # Two chunks of 192 fit in 500; the third forces an eviction.
    for i in 0 .. 2:
      let segs = mkHandler().performSegmentation(payloadOf(1000 + i)).get()
      discard h.handleIncomingSegment(segs[0])

    check h.bufferedBytes() <= 500
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Evicted
    check h.pendingSets() == 2

  test "maxBufferedBytes below segmentSizeBytes is rejected":
    check SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 1024, maxBufferedBytes = 512),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .isErr()

  test "the cap holds under a flood of distinct payloads":
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320, maxBufferedBytes = 2000),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        ignoreProgress,
      )
      .expect("valid config")
    for i in 0 ..< 50:
      let segs = mkHandler().performSegmentation(payloadOf(1000 + i)).get()
      discard h.handleIncomingSegment(segs[0])
      check h.bufferedBytes() <= 2000

suite "progress reporting":
  test "progress is reported per stored segment, with the expected count":
    let seen = new seq[(int, int)]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        onSegmentProgress = proc(
            hash: seq[byte], held, expected: int
        ) {.gcsafe, raises: [].} =
          seen[].add((held, expected)),
      )
      .expect("valid config")

    let segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    check segments.len == 6
    check h.feed(segments).isSome()
    check seen[] == @[(1, 6), (2, 6), (3, 6), (4, 6), (5, 6), (6, 6)]

  test "progress carries the payload hash":
    let hashes = new seq[seq[byte]]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        onSegmentProgress = proc(
            hash: seq[byte], held, expected: int
        ) {.gcsafe, raises: [].} =
          hashes[].add(hash),
      )
      .expect("valid config")
    let segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    let expected = SegmentMessage.decode(segments[0]).get().originalPayloadHash
    discard h.handleIncomingSegment(segments[0])
    check hashes[] == @[expected]

  test "a parity segment arriving first already knows the data count":
    let seen = new seq[(int, int)]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320, parityRate = 0.5),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        onSegmentProgress = proc(
            hash: seq[byte], held, expected: int
        ) {.gcsafe, raises: [].} =
          seen[].add((held, expected)),
      )
      .expect("valid config")

    let segments =
      mkHandler(parityRate = 0.5).performSegmentation(payloadOf(1000)).get()
    let parity = segments.filterIt(SegmentMessage.decode(it).get().isParity)
    check parity.len > 0
    # Every segment carries data_segment_count, so the shape of the set is known
    # from the first one to arrive whichever class it belongs to.
    discard h.handleIncomingSegment(parity[0])
    check seen[] == @[(1, 6)]

  test "a discarded segment reports no progress":
    let seen = new seq[(int, int)]
    let h = SegmentationHandler
      .new(
        SegmentationConfig.init(segmentSizeBytes = 320),
        ignoreDropped,
        ignoreDiscarded,
        ignorePayload,
        onSegmentProgress = proc(
            hash: seq[byte], held, expected: int
        ) {.gcsafe, raises: [].} =
          seen[].add((held, expected)),
      )
      .expect("valid config")
    let segments = mkHandler().performSegmentation(payloadOf(1000)).get()
    discard h.handleIncomingSegment(segments[0])
    discard h.handleIncomingSegment(segments[0]) # duplicate
    discard h.handleIncomingSegment(@[0x0A'u8, 0x7F]) # undecodable
    check seen[] == @[(1, 6)]

suite "assembled length":
  proc rebuild(
      payload: seq[byte], declaredLen: int, chunks: seq[seq[byte]]
  ): seq[seq[byte]] =
    ## Data segments carrying `chunks` but declaring `payload`'s real hash and
    ## `declaredLen` as the length -- i.e. a set the hash check alone cannot catch.
    let hash = SegmentMessage
      .decode(mkHandler().performSegmentation(payload).get()[0])
      .get().originalPayloadHash
    var built: seq[seq[byte]]
    for i, c in chunks:
      built.add(
        SegmentMessage
          .init(
            originalPayloadHash = hash,
            originalPayloadLength = uint64(declaredLen),
            index = uint32(i),
            dataSegmentCount = uint32(chunks.len),
            paritySegmentCount = 0,
            isParity = false,
            payload = c,
          )
          .encode()
          .get()
      )
    return built

  test "data segments summing above the declared length are rejected":
    # The concatenation truncates down to a payload whose hash DOES match, so
    # only the length check stands between this and a delivery. Data segments
    # travel at their true length, so a longer sum means a malformed set.
    let payload = payloadOf(100)
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)

    let padded = payload[50 ..< 100] & newSeq[byte](20)
    check h.feed(rebuild(payload, 100, @[payload[0 ..< 50], padded])).isNone()
    check dropped[].len == 1
    # Not a hash failure: reporting HashMismatch here would signal the poisoning
    # attack for a set that simply never assembled.
    check dropped[][0][1] == SegmentSetDropReason.Malformed
    check h.pendingSets() == 0

  test "data segments summing below the declared length are rejected":
    let payload = payloadOf(200)
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(rebuild(payload, 200, @[payload[0 ..< 50], payload[50 ..< 100]]))
      .isNone()
    check dropped[].len == 1
    # A set that never assembled: HashMismatch here would falsely signal the
    # payload-poisoning attack.
    check dropped[][0][1] == SegmentSetDropReason.Malformed
    check h.pendingSets() == 0

  test "the parity path truncates the padding decoding reintroduces":
    # The last data segment is short; recovering it brings back shard-length
    # bytes, which must be trimmed before the hash is checked.
    let tx = mkHandler(parityRate = 0.125)
    let payload = payloadOf(1000) # 5 * 192 + 40, so the last chunk is short
    var segments = tx.performSegmentation(payload).get()
    let dataCount = segments.filterIt(not SegmentMessage.decode(it).get().isParity).len
    check payload.len < dataCount * tx.chunkSize

    segments.delete(dataCount - 1) # drop the short last data segment
    let delivered = mkHandler(parityRate = 0.125).feed(segments)
    check delivered.isSome()
    check delivered.get().payload == payload
    check delivered.get().payload.len == 1000

suite "malformed shard lengths":
  proc crafted(
      hash: seq[byte],
      declaredLen, dataCount, parityCount: int,
      index: uint32,
      isParity: bool,
      payload: seq[byte],
  ): seq[byte] =
    return SegmentMessage
      .init(
        originalPayloadHash = hash,
        originalPayloadLength = uint64(declaredLen),
        index = index,
        dataSegmentCount = uint32(dataCount),
        paritySegmentCount = uint32(parityCount),
        isParity = isParity,
        payload = payload,
      )
      .encode()
      .get()

  test "a data segment longer than the shard length is rejected, not padded":
    # The parity class fixes the shard length, and every data segment is padded
    # into a buffer of that size before decoding. An over-long last data segment
    # used to escape the cross-check and be written past the end of that buffer.
    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 9
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(
        @[
          crafted(hash, 100, 2, 1, 1'u32, false, payloadOf(200)),
          crafted(hash, 100, 2, 1, 0'u32, true, payloadOf(64)),
        ]
      )
      .isNone()
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Malformed
    check h.pendingSets() == 0

  test "a non-last data segment disagreeing with the shard length is rejected":
    # Only the last data segment may be short, so any other length disagreement
    # is a set that never assembled -- not the poisoning attack HashMismatch means.
    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 10
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(
        @[
          crafted(hash, 100, 2, 1, 0'u32, false, payloadOf(200)),
          crafted(hash, 100, 2, 1, 0'u32, true, payloadOf(64)),
        ]
      )
      .isNone()
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Malformed
    check h.pendingSets() == 0

  test "parity shards disagreeing on length are rejected":
    # The shard length is taken from the parity class, so two parity shards that
    # disagree leave the set unassemblable: Malformed, never a hash failure.
    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 11
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(
        @[
          crafted(hash, 100, 2, 2, 0'u32, true, payloadOf(64)),
          crafted(hash, 100, 2, 2, 1'u32, true, payloadOf(128)),
        ]
      )
      .isNone()
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Malformed
    check h.pendingSets() == 0

  test "a declared length that does not fit the shard geometry is rejected":
    # 1000 bytes cannot come out of two 64-byte shards. The declared length lies
    # about the shape of the set, so the drop is Malformed rather than a hash
    # failure -- nothing was ever assembled to hash.
    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 12
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(
        @[
          crafted(hash, 1000, 2, 1, 0'u32, false, payloadOf(64)),
          crafted(hash, 1000, 2, 1, 0'u32, true, payloadOf(64)),
        ]
      )
      .isNone()
    check dropped[].len == 1
    check dropped[][0][1] == SegmentSetDropReason.Malformed
    check h.pendingSets() == 0

  test "a one-data-segment set has its data shard checked too":
    # With a single data segment the "all but the last" rule covers no index at
    # all, so the check has to reach the last shard as well.
    let s = SegmentSet.new(
      originalPayloadHash = newSeq[byte](SegmentHashLen),
      originalPayloadLength = 40'u64,
      dataCount = 1,
      parityCount = 1,
      now = getMonoTime(),
    )
    s.data[1'u32] = payloadOf(200)
    s.parity[0'u32] = payloadOf(64)

    let r = s.assemble()
    check r.isErr()
    check "shardLengthOf" in r.error

  test "an unaligned shard length holds the set instead of dropping it":
    # 100-byte parity shards come from a peer whose chunk size is not a multiple
    # of ShardAlignment: undecodable here, but its data segments can still
    # complete the set, so the set is held rather than dropped.
    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 13
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(
        @[
          crafted(hash, 200, 2, 1, 1'u32, false, payloadOf(100)),
          crafted(hash, 200, 2, 1, 0'u32, true, payloadOf(100)),
        ]
      )
      .isNone()
    check dropped[].len == 0
    check h.pendingSets() == 1

  test "an empty parity shard holds the set instead of dropping it":
    # A zero-length parity shard makes the shard length zero, which is aligned
    # yet just as undecodable -- the other half of the same guard.
    var hash = newSeq[byte](SegmentHashLen)
    hash[0] = 14
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h.feed(@[crafted(hash, 100, 1, 1, 0'u32, true, newSeq[byte]())]).isNone()
    check dropped[].len == 0
    check h.pendingSets() == 1

  test "a set held over an unaligned shard length still completes":
    # Holding is only worth it because the data segments alone assemble.
    let payload = payloadOf(200)
    let hash = SegmentMessage
      .decode(mkHandler().performSegmentation(payload).get()[0])
      .get().originalPayloadHash
    let dropped = new seq[(seq[byte], SegmentSetDropReason)]
    let h = mkHandler(dropped)
    check h
      .feed(
        @[
          crafted(hash, 200, 2, 1, 1'u32, false, payload[100 ..< 200]),
          crafted(hash, 200, 2, 1, 0'u32, true, payloadOf(100)),
        ]
      )
      .isNone()
    check h.pendingSets() == 1

    let delivered =
      h.feed(@[crafted(hash, 200, 2, 1, 0'u32, false, payload[0 ..< 100])])
    check delivered.isSome()
    check delivered.get().payload == payload
    check dropped[].len == 0
    check h.pendingSets() == 0

suite "empty payload with parity":
  test "an empty payload is recovered when its only data segment is lost":
    # A zero-length payload needs no shard bytes at all, and travels as a single
    # empty data segment -- the one legitimate set the geometry check must not
    # read as an inconsistent one.
    let tx = mkHandler(parityRate = 0.125)
    let segments = tx.performSegmentation(@[]).get()
    check segments.len == 2 # one empty data segment plus one parity shard

    var lossy = segments
    lossy.delete(0)
    check SegmentMessage.decode(lossy[0]).get().isParity

    let rx = mkHandler(parityRate = 0.125)
    let delivered = rx.feed(lossy)
    check delivered.isSome()
    check delivered.get().payload.len == 0
    check delivered.get().originalPayloadHash ==
      SegmentMessage.decode(segments[0]).get().originalPayloadHash
    check rx.pendingSets() == 0
