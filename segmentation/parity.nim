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

export results

const ShardAlignment* = 64 ## leopard rejects a `bufSize` that is not a multiple of 64.

func alignShardLen*(n: int): int =
  ## Largest multiple of `ShardAlignment` that is at most `n`. Rounding down can
  ## only shrink a segment, so it can never push one past `segmentSizeBytes`.
  return (n div ShardAlignment) * ShardAlignment

func parityCountFor*(dataCount: int, parityRatePpm: int): int =
  ## `ceil(parityRate * dataCount)`, capped so parity stays the minority class.
  ##
  ## The rate arrives as parts-per-million so the count is computed in integer
  ## arithmetic: `ceil(0.125 * 8)` in floating point can come out as 2, which
  ## would make two conforming implementations disagree on the parity count.
  ##
  ## The `dataCount - 1` cap satisfies both the spec ("parity MUST remain the
  ## minority class") and leopard's own `parity > buffers` rejection, and leaves
  ## a single data segment with no parity.
  if dataCount <= 1 or parityRatePpm <= 0:
    return 0
  let raw = (dataCount * parityRatePpm + 999_999) div 1_000_000
  return min(raw, dataCount - 1)

func checkShards(
    shards: openArray[seq[byte]], shardLen: int, what: string
): Result[void, string] =
  for i, s in shards:
    if s.len > 0 and s.len != shardLen:
      return err(
        "malformed " & what & " shard " & $i & ": expected " & $shardLen & " bytes, got " &
          $s.len
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
        "data shard " & $i & " is not padded to " & $shardLen & " bytes (got " & $s.len &
          ")"
      )

  var data = @dataShards
  var parity = newSeq[seq[byte]](parityCount)
  for i in 0 ..< parityCount:
    parity[i] = newSeq[byte](shardLen)

  let encRes = LeoEncoder.init(shardLen, dataShards.len, parityCount)
  if encRes.isErr:
    return err("failed to init Reed-Solomon encoder: " & $encRes.error)

  var encoder = encRes.get()
  try:
    let encoded = encoder.encode(data, parity)
    if encoded.isErr:
      return err("Reed-Solomon encoding failed: " & $encoded.error)
  finally:
    # No working destructor upstream, so the aligned buffers leak on any early
    # return unless freed here.
    encoder.free()

  return ok(parity)

proc decodeParity*(
    dataShards, parityShards: openArray[seq[byte]], shardLen: int
): Result[seq[seq[byte]], string] =
  ## Recover the full set of data shards. Both arrays are passed at full length
  ## with holes -- an empty seq marks a missing shard -- never compacted.
  ## Returns every data shard at exactly `shardLen` bytes.
  ?checkShards(dataShards, shardLen, "data")
  ?checkShards(parityShards, shardLen, "parity")

  var holey = @dataShards
  var parity = @parityShards
  var recovered = newSeq[seq[byte]](dataShards.len)
  for i in 0 ..< dataShards.len:
    recovered[i] = newSeq[byte](shardLen)

  let decRes = LeoDecoder.init(shardLen, dataShards.len, parityShards.len)
  if decRes.isErr:
    return err("failed to init Reed-Solomon decoder: " & $decRes.error)

  var decoder = decRes.get()
  try:
    let decoded = decoder.decode(holey, parity, recovered)
    if decoded.isErr:
      return err("Reed-Solomon decoding failed: " & $decoded.error)
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
