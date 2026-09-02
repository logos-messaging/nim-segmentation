import std/[random, sequtils]
import unittest2
import results
import segmentation/parity

proc shard(seed, shardLen: int): seq[byte] =
  var s = newSeq[byte](shardLen)
  for i in 0 ..< shardLen:
    s[i] = byte((seed * 131 + i * 7) and 0xFF)
  return s

suite "shard alignment":
  test "rounds down to a multiple of 64":
    check alignShardLen(64) == 64
    check alignShardLen(127) == 64
    check alignShardLen(128) == 128
    check alignShardLen(102_400 - 64) == 102_336
    check alignShardLen(63) == 0

suite "parity count":
  test "a single data segment gets no parity":
    check parityCountFor(1, 125_000) == 0

  test "rate zero disables parity":
    for k in 1 .. 32:
      check parityCountFor(k, 0) == 0

  test "count is ceil(rate * dataCount)":
    # 0.125 is the rate the spec recommends: one parity per eight data.
    check parityCountFor(2, 125_000) == 1
    check parityCountFor(8, 125_000) == 1
    check parityCountFor(9, 125_000) == 2
    check parityCountFor(16, 125_000) == 2
    check parityCountFor(17, 125_000) == 3

  test "parity stays the minority class":
    # ceil(0.5 * 2) is 1, and the cap keeps it there rather than at 2.
    check parityCountFor(2, 500_000) == 1
    check parityCountFor(4, 900_000) == 3
    for k in 2 .. 64:
      check parityCountFor(k, 990_000) < k

  test "integer arithmetic avoids the float ceil() trap":
    # 0.125 * 8 in floating point can exceed 1.0, which would give 2 here.
    check parityCountFor(8, 125_000) == 1

suite "reed-solomon round trip":
  const shardLen = 128

  test "no parity requested yields no shards":
    let data = @[shard(1, shardLen)]
    check encodeParity(data, 0, shardLen).get().len == 0

  test "unpadded data shard is rejected before reaching leopard":
    var data = @[shard(1, shardLen), shard(2, shardLen)]
    data[1].setLen(shardLen - 1)
    check encodeParity(data, 1, shardLen).isErr()

  test "recovers erased data shards":
    const dataCount = 8
    const parityCount = 3
    var data = newSeq[seq[byte]](dataCount)
    for i in 0 ..< dataCount:
      data[i] = shard(i, shardLen)
    let parityShards = encodeParity(data, parityCount, shardLen)
    check parityShards.isOk()

    var holey = data
    holey[0] = @[]
    holey[4] = @[]
    holey[7] = @[]
    let recovered = decodeParity(holey, parityShards.get(), shardLen)
    check recovered.isOk()
    check recovered.get() == data

  test "surviving shards are preserved, not just the recovered ones":
    const dataCount = 4
    var data = newSeq[seq[byte]](dataCount)
    for i in 0 ..< dataCount:
      data[i] = shard(i + 100, shardLen)
    let parityShards = encodeParity(data, 1, shardLen).get()

    var holey = data
    holey[2] = @[]
    let recovered = decodeParity(holey, parityShards, shardLen).get()
    for i in 0 ..< dataCount:
      check recovered[i] == data[i]

  test "erasures beyond the parity count fail":
    const dataCount = 6
    var data = newSeq[seq[byte]](dataCount)
    for i in 0 ..< dataCount:
      data[i] = shard(i, shardLen)
    let parityShards = encodeParity(data, 1, shardLen).get()

    var holey = data
    holey[0] = @[]
    holey[3] = @[]
    check decodeParity(holey, parityShards, shardLen).isErr()

  test "a mis-sized shard is rejected rather than over-read":
    const dataCount = 4
    var data = newSeq[seq[byte]](dataCount)
    for i in 0 ..< dataCount:
      data[i] = shard(i, shardLen)
    let parityShards = encodeParity(data, 1, shardLen).get()

    var holey = data
    holey[1] = shard(1, shardLen - 8) # short: leopard would read past its end
    check decodeParity(holey, parityShards, shardLen).isErr()

  test "random erasure patterns up to the parity count always recover":
    var rng = initRand(20260902)
    for trial in 0 ..< 40:
      let dataCount = rng.rand(2 .. 24)
      let parityCount = max(1, parityCountFor(dataCount, 250_000))
      var data = newSeq[seq[byte]](dataCount)
      for i in 0 ..< dataCount:
        data[i] = shard(trial * 100 + i, shardLen)
      let parityShards = encodeParity(data, parityCount, shardLen).get()

      var holey = data
      var indices = toSeq(0 ..< dataCount)
      rng.shuffle(indices)
      for i in 0 ..< parityCount:
        holey[indices[i]] = @[]

      let recovered = decodeParity(holey, parityShards, shardLen)
      check recovered.isOk()
      if recovered.isOk():
        check recovered.get() == data
