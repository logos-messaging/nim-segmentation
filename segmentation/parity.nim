## Reed-Solomon erasure coding over a payload's data segments, via nim-leopard.
##
## Leopard works on equal-length inputs called shards, and every shard must be
## exactly `shardLen` bytes -- a memory-safety requirement, not just a
## correctness one: leopard's `encode`/`decode` `copyMem` `bufSize` bytes out of
## every non-empty entry regardless of that seq's actual length, so a short shard
## is a heap over-read. The procs here re-check it before calling in.
##
## An erasure is signalled to `decode` by a nil entry in the pointer table, and
## `decode` writes only the erased indices into `recovered`, so `decodeParity`
## merges the surviving shards back in itself.

{.push raises: [].}
import results, leopard

const ShardAlignment* = 64 ## leopard rejects a `bufSize` that is not a multiple of 64.

const
  ShardClassData = "data"
  ShardClassParity = "parity"

func alignShardLen*(n: int): int =
  ## Largest multiple of `ShardAlignment` that is at most `n`. Rounding down can
  ## only shrink a segment, so it can never push one past `segmentSizeBytes`.
  return (n div ShardAlignment) * ShardAlignment

const ParityRateScale* = 1_000_000
  ## Denominator the parity rate is carried over, so `parityRate = 0.125` scales
  ## to 125_000 and the count can be derived in integer arithmetic -- see
  ## `parityCountFor`.

func padTo*(chunk: seq[byte], shardLen: int): seq[byte] =
  ## Zero-pad a chunk up to shard length: leopard reads `shardLen` bytes out of
  ## every non-empty entry regardless of that seq's actual length.
  var padded = newSeq[byte](shardLen)
  for i, b in chunk:
    padded[i] = b
  return padded

func parityCountFor*(dataCount, scaledParityRate: int): int =
  ## `ceil(parityRate * dataCount)`, capped so parity never outnumbers the data.
  ## `scaledParityRate` is the rate numerator over `ParityRateScale`.
  ##
  ## Integer arithmetic is deliberate: in floating point `ceil(0.125 * 8)` can
  ## come out as 2, since the product evaluates to 1.0000000000000002, and two
  ## conforming implementations would then disagree on the parity count.
  ##
  ## The cap at `dataCount` is both what the spec requires ("parity segments
  ## never outnumbering the data ones") and leopard's own `parity > buffers`
  ## rejection. Reed-Solomon recovers from any `dataCount` segments of a set
  ## whichever class they are, so parity equal to the data count is useful
  ## rather than wasteful.
  if dataCount < 1 or scaledParityRate <= 0:
    return 0
  let raw = (dataCount * scaledParityRate + ParityRateScale - 1) div ParityRateScale
  return min(raw, dataCount)

func shardTable(shards: var seq[seq[byte]]): seq[LeoBufferPtr] =
  ## Pointer table over `shards`, nil where a shard is missing -- the erasure
  ## marker leopard's decoder expects. `shards` must outlive the table and must
  ## not be resized while it is in use.
  var table = newSeq[LeoBufferPtr](shards.len)
  for i in 0 ..< shards.len:
    table[i] =
      if shards[i].len > 0:
        cast[LeoBufferPtr](addr shards[i][0])
      else:
        nil
  return table

func asLeoTable(table: var seq[LeoBufferPtr]): ptr UncheckedArray[LeoBufferPtr] =
  ## `table` is never empty at the call sites: both classes are checked for a
  ## zero length first, so indexing element 0 is in bounds.
  return cast[ptr UncheckedArray[LeoBufferPtr]](addr table[0])

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

  if dataShards.len == 0:
    return err("parity.encodeParity: no data shards to encode")

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

  var dataTable = shardTable(data)
  var parityTable = shardTable(parity)

  var encoder = LeoEncoder.init(shardLen, dataShards.len, parityCount).valueOr:
    return err("parity.encodeParity: leopard encoder init failed: " & $error)

  try:
    encoder.encode(asLeoTable(dataTable), asLeoTable(parityTable), data.len, parity.len).isOkOr:
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

  if dataShards.len == 0 or parityShards.len == 0:
    return err("parity.decodeParity: no shards to decode")

  # The shards are copied into locals so the pointer tables below stay valid for
  # the whole call. `recovered` must be pre-sized: decode writes into it with
  # `copyMem`, and only at the erased indices.
  var data = @dataShards
  var parity = @parityShards
  var recovered = newSeq[seq[byte]](dataShards.len)
  for i in 0 ..< dataShards.len:
    recovered[i] = newSeq[byte](shardLen)

  var dataTable = shardTable(data)
  var parityTable = shardTable(parity)
  var recoveredTable = shardTable(recovered)

  var decoder = LeoDecoder.init(shardLen, dataShards.len, parityShards.len).valueOr:
    return err("parity.decodeParity: leopard decoder init failed: " & $error)

  try:
    decoder.decode(
      asLeoTable(dataTable),
      asLeoTable(parityTable),
      asLeoTable(recoveredTable),
      data.len,
      parity.len,
      recovered.len,
    ).isOkOr:
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
