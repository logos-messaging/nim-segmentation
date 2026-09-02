## Manual end-to-end check: segment a 1 MiB payload with parity, drop as many
## data segments as parity can cover, shuffle the rest, and require an exact
## round trip. Run with `nim c -r -d:release tools/roundtrip_demo.nim`.

import std/[algorithm, monotimes, random, sequtils, times]
import results
import segmentation

let payload = block:
  var rng = initRand(42)
  var p = newSeq[byte](1024 * 1024)
  for i in 0 ..< p.len:
    p[i] = byte(rng.rand(255))
  p

let tx =
  SegmentationHandler.new(SegmentationConfig.init(parityRate = 0.125)).expect("config")
let start = getMonoTime()
var segments = tx.performSegmentation(payload).get()
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

let rx =
  SegmentationHandler.new(SegmentationConfig.init(parityRate = 0.125)).expect("config")
var delivered: seq[byte]
for s in kept:
  let r = rx.handleIncomingSegment(s).expect("no internal fault")
  if r.isSome():
    delivered = r.get().payload

doAssert delivered == payload, "round trip mismatch"
doAssert rx.pendingSets() == 0, "set not released after delivery"
echo "elapsed      : ", (getMonoTime() - start).inMilliseconds, " ms"
echo "OK: 1 MiB payload recovered exactly after parity-covered loss + shuffle"
