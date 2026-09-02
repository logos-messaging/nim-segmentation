## Reed-Solomon erasure coding over a payload's data segments, via nim-leopard.
##
## Leopard works on equal-length inputs called shards. Callers must hand every
## shard at exactly `shardLen` bytes -- this is a memory-safety requirement, not
## just a correctness one: leopard's `encode`/`decode` `copyMem` `bufSize` bytes
## out of every non-empty entry regardless of that seq's actual length, so a
## short shard is a heap over-read. The procs here re-check it before calling in.
##
## An erasure is signalled to `decode` by an empty seq, and `decode` writes only
## the erased indices into `recovered` -- surviving shards are never copied
## there, so `decodeParity` merges the two itself.

{.push raises: [].}

import results
import leopard

const ShardAlignment* = 64 ## leopard rejects a `bufSize` that is not a multiple of 64.

const
  ShardClassData = "data"
  ShardClassParity = "parity"

func alignShardLen*(n: int): int =
  ## Largest multiple of `ShardAlignment` that is at most `n`. Rounding down can
  ## only shrink a segment, so it can never push one past `segmentSizeBytes`.
  return (n div ShardAlignment) * ShardAlignment

const ParityRateScale* = 1_000_000
  ## Denominator the parity rate is carried over, so `parityRate = 0.125` is
  ## scaled to 125_000. Keeping it a rational lets the count be derived in
  ## integer arithmetic -- see `parityCountFor`.

func parityCountFor*(dataCount, scaledParityRate: int): int =
  ## `ceil(parityRate * dataCount)`, capped so parity stays the minority class.
  ## `scaledParityRate` is the rate numerator over `ParityRateScale`.
  ##
  ## Integer arithmetic is deliberate: `ceil(0.125 * 8)` in floating point can
  ## come out as 2, because the product evaluates to 1.0000000000000002. Two
  ## conforming implementations would then disagree on the parity count.
  ##
  ## The `dataCount - 1` cap satisfies both the spec ("parity MUST remain the
  ## minority class") and leopard's own `parity > buffers` rejection, and leaves
  ## a single data segment with no parity.
  if dataCount <= 1 or scaledParityRate <= 0:
    return 0
  let raw = (dataCount * scaledParityRate + ParityRateScale - 1) div ParityRateScale
  return min(raw, dataCount - 1)

func checkShards(
    shards: openArray[seq[byte]], shardLen: int, what: string
): Result[void, string] =
  for i, s in shards:
    if s.len > 0 and s.len != shardLen:
      return err(
        "parity.checkShards: malformed shard: " & what & " index " & $i & " is " & $s.len &
          " bytes, expected " & $shardLen
      )
  return ok()

proc encodeParity*(
    dataShards: openArray[seq[byte]], parityCount, shardLen: int
): Result[seq[seq[byte]], string] =
  ## Produce `parityCount` parity shards from a complete set of data shards.
  ## Every data shard must already be padded to `shardLen`.
  if parityCount <= 0:
    return ok(newSeq[seq[byte]]())

  for i, s in dataShards:
    if s.len != shardLen:
      return err(
        "parity.encodeParity: unpadded data shard: index " & $i & " is " & $s.len &
          " bytes, expected " & $shardLen
      )

  var data = @dataShards
  var parity = newSeq[seq[byte]](parityCount)
  for i in 0 ..< parityCount:
    parity[i] = newSeq[byte](shardLen)

  var encoder = LeoEncoder.init(shardLen, dataShards.len, parityCount).valueOr:
    return err("parity.encodeParity: leopard encoder init failed: " & $error)

  try:
    encoder.encode(data, parity).isOkOr:
      return err("parity.encodeParity: leopard encode failed: " & $error)
  finally:
    # No working destructor upstream, so the aligned buffers leak on any early
    # return unless freed here.
    encoder.free()

  return ok(parity)

proc decodeParity*(
    dataShards, parityShards: openArray[seq[byte]], shardLen: int
): Result[seq[seq[byte]], string] =
  ## Recover the full set of data shards. Both arrays are passed at full length
  ## with holes -- an empty seq marks a missing shard -- never compacted, so
  ## index `i` always refers to shard `i`. Returns every data shard at exactly
  ## `shardLen` bytes.
  ?checkShards(dataShards, shardLen, ShardClassData)
  ?checkShards(parityShards, shardLen, ShardClassParity)

  # leopard takes its inputs as `var openArray`, so the caller's shards are
  # copied into locals it can bind to. `recovered` must be pre-sized: decode
  # writes into it with `copyMem`, and only at the erased indices.
  var data = @dataShards
  var parity = @parityShards
  var recovered = newSeq[seq[byte]](dataShards.len)
  for i in 0 ..< dataShards.len:
    recovered[i] = newSeq[byte](shardLen)

  var decoder = LeoDecoder.init(shardLen, dataShards.len, parityShards.len).valueOr:
    return err("parity.decodeParity: leopard decoder init failed: " & $error)

  try:
    decoder.decode(data, parity, recovered).isOkOr:
      return err("parity.decodeParity: leopard decode failed: " & $error)
  finally:
    decoder.free()

  var shards = newSeq[seq[byte]](dataShards.len)
  for i in 0 ..< dataShards.len:
    shards[i] =
      if dataShards[i].len > 0:
        dataShards[i]
      else:
        recovered[i]
  return ok(shards)

{.pop.}
