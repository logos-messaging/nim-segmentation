## Manual end-to-end check: segment a 1 MiB payload with parity, drop as many
## data segments as parity can cover, shuffle the rest, and require an exact
## round trip. Run with `nim c -r -d:release tools/roundtrip_demo.nim`.
##
## Doubles as the shortest complete example of wiring the reception callbacks.
## Note the whole thing lives in a proc: the callbacks are `{.gcsafe.}`, so they
## may close over locals but not over mutable module-level globals.
import std/[algorithm, monotimes, random, sequtils, times]
import results
import segmentation

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

proc main() =
  let payload = block:
    var rng = initRand(42)
    var p = newSeq[byte](1024 * 1024)
    for i in 0 ..< p.len:
      p[i] = byte(rng.rand(255))
    p

  # This handler only sends, so its reception callbacks are explicit no-ops --
  # a decision, rather than an omission.
  let tx = SegmentationHandler
    .new(
      SegmentationConfig.init(parityRate = 0.125),
      onSetDropped = ignoreDropped,
      onSegmentDiscarded = ignoreDiscarded,
      onPayloadReassembled = ignorePayload,
      onSegmentProgress = ignoreProgress,
    )
    .expect("config")

  let start = getMonoTime()
  let segments = tx.performSegmentation(payload).get()
  echo "payload      : ", payload.len, " bytes"
  echo "chunk size   : ", tx.chunkSize
  echo "segments     : ", segments.len
  echo "largest wire : ",
    segments.mapIt(it.len).max(), " (limit ", DefaultSegmentSizeBytes, ")"

  let dataCount = segments.filterIt(not SegmentMessage.decode(it).get().isParity).len
  let parityCount = segments.len - dataCount
  echo "data/parity  : ", dataCount, "/", parityCount

  var rng = initRand(7)
  var kept = segments
  var idx = toSeq(0 ..< dataCount)
  rng.shuffle(idx)
  for i in idx[0 ..< parityCount].sorted(SortOrder.Descending):
    kept.delete(i)
  rng.shuffle(kept)
  echo "dropped      : ", parityCount, " data segments, then shuffled"

  let events = new seq[string]
  let rx = SegmentationHandler
    .new(
      SegmentationConfig.init(parityRate = 0.125),
      onSetDropped = proc(
          hash: seq[byte], reason: SegmentSetDropReason
      ) {.gcsafe, raises: [].} =
        events[].add("dropped:" & $reason),
      onSegmentDiscarded = proc(reason: SegmentDiscardReason) {.gcsafe, raises: [].} =
        events[].add("discarded:" & $reason),
      onPayloadReassembled = proc(p: ReassembledPayload) {.gcsafe, raises: [].} =
        events[].add("reassembled:" & $p.payload.len & " bytes"),
      onSegmentProgress = proc(
          hash: seq[byte], held, expected: int
      ) {.gcsafe, raises: [].} =
        events[].add("progress:" & $held & "/" & $expected),
    )
    .expect("config")

  var delivered: seq[byte]
  for s in kept:
    let r = rx.handleIncomingSegment(s).expect("no internal fault")
    if r.isSome():
      delivered = r.get().payload

  doAssert delivered == payload, "round trip mismatch"
  doAssert rx.pendingSets() == 0, "set not released after delivery"
  echo "buffered     : ", rx.bufferedBytes(), " bytes held at the end"
  echo "events       : ", events[]
  echo "elapsed      : ", (getMonoTime() - start).inMilliseconds, " ms"
  echo "OK: 1 MiB payload recovered exactly after parity-covered loss + shuffle"

main()
