## One partially received segment set: the segments of a single payload, and the
## rebuilding of that payload once enough of them have arrived.
##
## The two class counts are held separately, each fixed by the first segment of
## its class, because `segment_count` on the wire counts only its own class.

{.push raises: [].}
import std/[monotimes, tables]
import results, nimcrypto/keccak
import ./parity

export monotimes, tables, results

type SegmentSet* = ref object
  ## Carries the identity it was filed under, so a set can name its payload when
  ## it is delivered or abandoned.
  originalPayloadHash*: seq[byte]
  originalPayloadLength*: uint64
  dataCount*: Opt[uint32]
  parityCount*: Opt[uint32]
  data*: Table[uint32, seq[byte]]
  parity*: Table[uint32, seq[byte]]
  lastUpdate*: MonoTime

func new*(
    T: type SegmentSet,
    originalPayloadHash: seq[byte],
    originalPayloadLength: uint64,
    now: MonoTime,
): T =
  ## Identity comes from the first segment filed here; every later segment of the
  ## set carries the same pair, which is what `segmentSetKey` keys on.
  return T(
    originalPayloadHash: originalPayloadHash,
    originalPayloadLength: originalPayloadLength,
    data: initTable[uint32, seq[byte]](),
    parity: initTable[uint32, seq[byte]](),
    lastUpdate: now,
  )

func heldSegments*(self: SegmentSet): int =
  return self.data.len + self.parity.len

func isReconstructible*(self: SegmentSet): bool =
  ## Either every data segment has arrived, or data and parity together reach
  ## the data-segment count. Both need the data count, which is why parity must
  ## stay the minority class -- a receiver always sees a data segment first.
  let dataCount = self.dataCount.valueOr:
    return false
  if uint32(self.data.len) >= dataCount:
    return true
  return uint32(self.data.len + self.parity.len) >= dataCount

func shardLengthOf(self: SegmentSet, dataCount: int): Result[int, string] =
  ## Parity shards are always exactly shard-length; so is any data segment but
  ## the last. Take the length from the parity class and cross-check the data
  ## one, which catches a malformed set before it reaches the decoder.
  var shardLen = -1
  for _, p in self.parity:
    if shardLen < 0:
      shardLen = p.len
    elif p.len != shardLen:
      return err(
        "segment_set.shardLengthOf: parity shards disagree on length: " & $p.len &
          " and " & $shardLen
      )
  if shardLen < 0:
    return
      err("segment_set.shardLengthOf: no parity shard to take the shard length from")
  for idx, d in self.data:
    if int(idx) < dataCount - 1 and d.len != shardLen:
      return err(
        "segment_set.shardLengthOf: data shard disagrees with the parity shard length: index " &
          $idx & " is " & $d.len & " bytes, expected " & $shardLen
      )
  return ok(shardLen)

proc recoverThroughParity(
    self: SegmentSet, dataCount, payloadLen: int
): Result[Opt[seq[byte]], string] =
  let parityClassCount = self.parityCount.valueOr:
    return ok(Opt.none(seq[byte]))
  let parityCount = int(parityClassCount)
  let shardLen = ?shardLengthOf(self, dataCount)

  # A peer that chose an unaligned chunk size cannot be decoded here; wait for
  # its data segments instead of dropping the set.
  if shardLen mod ShardAlignment != 0 or shardLen == 0:
    return ok(Opt.none(seq[byte]))

  # Cheap geometry check on the claimed length, so a hostile set is dropped
  # before any of it is assembled.
  if payloadLen > dataCount * shardLen or payloadLen <= (dataCount - 1) * shardLen:
    return err(
      "segment_set.recoverThroughParity: declared payload length does not fit the shard geometry: " &
        $payloadLen & " bytes over " & $dataCount & " shards of " & $shardLen
    )

  var data = newSeq[seq[byte]](dataCount)
  for i in 0 ..< dataCount:
    if self.data.hasKey(uint32(i)):
      data[i] = padTo(self.data.getOrDefault(uint32(i)), shardLen)
    # A missing shard stays an empty seq, which is the erasure marker.

  var parityShards = newSeq[seq[byte]](parityCount)
  for idx, p in self.parity:
    if int(idx) < parityCount:
      parityShards[int(idx)] = p

  let shards = ?decodeParity(data, parityShards, shardLen)

  var assembled = newSeq[byte]()
  for shard in shards:
    assembled.add(shard)
  return ok(Opt.some(assembled))

proc assemble*(self: SegmentSet): Result[Opt[seq[byte]], string] =
  ## Rebuild the original payload. `ok(none)` means "not yet"; `err` means the
  ## set is unusable and is dropped.
  let payloadLen = int(self.originalPayloadLength)
  let dataClassCount = self.dataCount.valueOr:
    return ok(Opt.none(seq[byte]))
  let dataCount = int(dataClassCount)

  var complete = true
  for i in 0 ..< dataCount:
    if not self.data.hasKey(uint32(i)):
      complete = false
      break

  var assembled: seq[byte]
  if complete:
    # No decoder needed, and no shard-alignment requirement either.
    for i in 0 ..< dataCount:
      assembled.add(self.data.getOrDefault(uint32(i)))
  else:
    assembled = (?recoverThroughParity(self, dataCount, payloadLen)).valueOr:
      return ok(Opt.none(seq[byte]))

  if assembled.len < payloadLen:
    return err(
      "segment_set.assemble: assembled payload shorter than declared: " & $assembled.len &
        " < " & $payloadLen
    )
  assembled.setLen(payloadLen)

  if @(keccak256.digest(assembled).data) != self.originalPayloadHash:
    return err(
      "segment_set.assemble: reconstructed payload does not match the declared hash"
    )
  return ok(Opt.some(assembled))

{.pop.}
