import std/[algorithm, random, sequtils, times]
import unittest2
import results
import segmentation
import segmentation/reassembly

proc mkHandler(
    segmentSizeBytes = 256, parityRate = 0.0, maxTotalSegments = 256
): SegmentationHandler =
  return SegmentationHandler
    .new(
      SegmentationConfig.init(
        segmentSizeBytes = segmentSizeBytes,
        parityRate = parityRate,
        maxTotalSegments = maxTotalSegments,
      )
    )
    .expect("valid config")

proc payloadOf(n: int): seq[byte] =
  var p = newSeq[byte](n)
  for i in 0 ..< n:
    p[i] = byte((i * 37 + 11) and 0xFF)
  return p

proc feed(h: SegmentationHandler, segments: seq[seq[byte]]): Opt[ReassemblyResult] =
  ## Feed every segment, returning the first successful reassembly.
  var delivered = Opt.none(ReassemblyResult)
  for s in segments:
    let r = h.handleIncomingSegment(s).expect("no internal fault")
    if r.isSome() and delivered.isNone():
      delivered = r
  return delivered

suite "configuration":
  test "defaults are accepted":
    check SegmentationHandler.new(SegmentationConfig.init()).isOk()

  test "chunk size is aligned and leaves room for the header":
    let h = mkHandler(segmentSizeBytes = 102_400)
    check h.chunkSize == 102_336
    check h.chunkSize mod 64 == 0

  test "invalid configuration is rejected":
    check SegmentationHandler.new(SegmentationConfig.init(segmentSizeBytes = 127)).isErr()
    check SegmentationHandler.new(SegmentationConfig.init(parityRate = 1.0)).isErr()
    check SegmentationHandler.new(SegmentationConfig.init(parityRate = -0.1)).isErr()
    check SegmentationHandler
      .new(SegmentationConfig.init(reconstructionTimeoutSeconds = 0))
      .isErr()
    check SegmentationHandler.new(SegmentationConfig.init(maxTotalSegments = 0)).isErr()

suite "segmentation without parity":
  test "a payload that fits one chunk is still wrapped":
    let h = mkHandler()
    let payload = payloadOf(10)
    let segments = h.performSegmentation(payload).get()
    check segments.len == 1

    let m = SegmentMessage.decode(segments[0]).get()
    check m.segmentCount == 1
    check m.index == 0
    check not m.isParity
    check m.segmentPayload == payload
    # The wrapper is real: the wire bytes are not the bare payload.
    check segments[0] != payload

  test "an empty payload still produces one segment":
    let h = mkHandler()
    let segments = h.performSegmentation(@[]).get()
    check segments.len == 1
    let m = SegmentMessage.decode(segments[0]).get()
    check m.segmentCount == 1
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
    let h = mkHandler(segmentSizeBytes = 256, parityRate = 0.125)
    for size in [1, 63, 192, 193, 1000, 5000]:
      for s in h.performSegmentation(payloadOf(size)).get():
        check s.len <= 256

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
        check m.segmentPayload.len == h.chunkSize
      elif m.index == m.segmentCount - 1:
        check m.segmentPayload.len == 500 - 2 * h.chunkSize
      else:
        check m.segmentPayload.len == h.chunkSize

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
    m.segmentPayload[0] = m.segmentPayload[0] xor 0xFF'u8
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
    liar.segmentCount = 99
    check rx.handleIncomingSegment(liar.encode().get()).get().isNone()
    # The genuine segment 3 is still accepted afterwards.
    check rx.feed(segments[3 .. ^1]).get().payload == payloadOf(1000)

suite "segment cache bounds and expiry":
  proc segmentFor(hashByte: byte, index, count: uint32): SegmentMessage =
    var h = newSeq[byte](SegmentHashLen)
    h[0] = hashByte
    return SegmentMessage(
      originalPayloadHash: h,
      originalPayloadLength: 100'u64,
      index: index,
      segmentCount: count,
      isParity: false,
      segmentPayload: @[1'u8],
    )

  test "a set idle past the timeout is dropped":
    let cache = SegmentCache.new(10, initDuration(seconds = 30))
    let start = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), 256, start)
    check cache.len == 1

    cache.sweep(start + initDuration(seconds = 29))
    check cache.len == 1
    cache.sweep(start + initDuration(seconds = 31))
    check cache.len == 0

  test "a duplicate does not extend a set's life":
    let cache = SegmentCache.new(10, initDuration(seconds = 30))
    let start = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), 256, start)

    let dup = cache.add(segmentFor(1, 0, 4), 256, start + initDuration(seconds = 20))
    check dup.outcome == Ignored

    cache.sweep(start + initDuration(seconds = 31))
    check cache.len == 0

  test "the least recently updated set is evicted first":
    let cache = SegmentCache.new(2, initDuration(seconds = 300))
    let start = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), 256, start)
    discard cache.add(segmentFor(2, 0, 4), 256, start + initDuration(seconds = 1))
    check cache.len == 2

    discard cache.add(segmentFor(3, 0, 4), 256, start + initDuration(seconds = 2))
    check cache.len == 2
    check cache.get(setKey(segmentFor(1, 0, 4))).isNil()
    check not cache.get(setKey(segmentFor(3, 0, 4))).isNil()

  test "a set whose two classes exceed maxTotalSegments is dropped":
    let cache = SegmentCache.new(10, initDuration(seconds = 300))
    let now = getMonoTime()
    discard cache.add(segmentFor(1, 0, 4), 6, now)
    check cache.len == 1

    var parity = segmentFor(1, 0, 3)
    parity.isParity = true
    check cache.add(parity, 6, now).outcome == Ignored
    check cache.len == 0

suite "round-trip properties":
  test "random sizes, rates and erasure patterns all round-trip":
    var rng = initRand(20260902)
    for trial in 0 ..< 60:
      let parityRate = sample(rng, @[0.0, 0.125, 0.25, 0.5])
      let tx = mkHandler(segmentSizeBytes = 256, parityRate = parityRate)
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
        mkHandler(segmentSizeBytes = 256, parityRate = parityRate).feed(kept)
      check delivered.isSome()
      if delivered.isSome():
        check delivered.get().payload == payload
