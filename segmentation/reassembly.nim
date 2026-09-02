## In-memory cache of partially received segment sets.
##
## A set is keyed by `(original_payload_hash, original_payload_length)` only.
## `segment_count` is deliberately NOT part of the key: it counts one class, so
## keying on it would file a payload's data and parity segments under two
## different sets and parity recovery would never fire. The two class counts are
## held separately instead, each fixed by the first segment of its class.
##
## This module owns storage, dedup, bounds and expiry. Hashing, Reed-Solomon and
## payload assembly live in `segmentation.nim`.

{.push raises: [].}

import std/[monotimes, tables, times]
import results
import ./segment_message

export monotimes, tables

type
  SegmentSet* = ref object
    dataCount*: Opt[uint32]
    parityCount*: Opt[uint32]
    data*: Table[uint32, seq[byte]]
    parity*: Table[uint32, seq[byte]]
    lastUpdate*: MonoTime

  AddOutcome* = enum
    Accepted ## Stored; the set may now be reconstructible.
    Ignored ## Discarded per the spec -- duplicate, conflicting counts, or over bounds.

  SegmentCache* = ref object
    sets: Table[string, SegmentSet]
    maxSets: int
    timeout: Duration

func new*(T: type SegmentCache, maxSets: int, timeout: Duration): T =
  return T(sets: initTable[string, SegmentSet](), maxSets: maxSets, timeout: timeout)

func new*(T: type SegmentSet, now: MonoTime): T =
  return T(
    data: initTable[uint32, seq[byte]](),
    parity: initTable[uint32, seq[byte]](),
    lastUpdate: now,
  )

func setKey*(m: SegmentMessage): string =
  ## The 32 hash bytes followed by the payload length, little-endian.
  var key = newString(m.originalPayloadHash.len + 8)
  for i, b in m.originalPayloadHash:
    key[i] = char(b)
  var n = m.originalPayloadLength
  for i in 0 ..< 8:
    key[m.originalPayloadHash.len + i] = char(byte(n and 0xFF'u64))
    n = n shr 8
  return key

func len*(cache: SegmentCache): int =
  return cache.sets.len

func get*(cache: SegmentCache, key: string): SegmentSet =
  return cache.sets.getOrDefault(key, nil)

func remove*(cache: SegmentCache, key: string) =
  cache.sets.del(key)

func heldSegments*(s: SegmentSet): int =
  return s.data.len + s.parity.len

func isReconstructible*(s: SegmentSet): bool =
  ## Either every data segment has arrived, or data and parity together reach
  ## the data-segment count. Both need the data count, which is why parity must
  ## stay the minority class -- a receiver always sees a data segment first.
  let dataCount = s.dataCount.valueOr:
    return false
  if uint32(s.data.len) >= dataCount:
    return true
  return uint32(s.data.len + s.parity.len) >= dataCount

func sweep*(cache: SegmentCache, now: MonoTime) =
  ## Drop sets that have gone `timeout` without a new segment.
  var expired: seq[string]
  for key, s in cache.sets:
    if now - s.lastUpdate >= cache.timeout:
      expired.add(key)
  for key in expired:
    cache.sets.del(key)

func evictOldest(cache: SegmentCache) =
  var oldestKey = ""
  var oldest = MonoTime.default
  var first = true
  for key, s in cache.sets:
    if first or s.lastUpdate < oldest:
      oldest = s.lastUpdate
      oldestKey = key
      first = false
  if not first:
    cache.sets.del(oldestKey)

func recordCount(known: var Opt[uint32], count: uint32): bool =
  ## Fix a class count on first sight; reject a later segment that disagrees.
  if known.isSome():
    return known.unsafeGet() == count
  known = Opt.some(count)
  return true

func add*(
    cache: SegmentCache, m: SegmentMessage, maxTotalSegments: int, now: MonoTime
): tuple[outcome: AddOutcome, key: string] =
  ## Store a segment that has already passed `isValid`.
  let key = setKey(m)

  var s = cache.sets.getOrDefault(key, nil)
  if s.isNil():
    if cache.sets.len >= cache.maxSets:
      evictOldest(cache)
    s = SegmentSet.new(now)
    cache.sets[key] = s

  let counted =
    if m.isParity:
      recordCount(s.parityCount, m.segmentCount)
    else:
      recordCount(s.dataCount, m.segmentCount)
  if not counted:
    return (Ignored, key)

  # Once both classes are known the whole set can be bounded, which
  # `segment_count` alone cannot do.
  if s.dataCount.isSome() and s.parityCount.isSome():
    if int(s.dataCount.unsafeGet()) + int(s.parityCount.unsafeGet()) > maxTotalSegments:
      cache.sets.del(key)
      return (Ignored, key)

  # `(is_parity, index)` is unique within a set; a repeat is ignored rather than
  # overwritten, and must not extend the set's life -- the spec expires a set
  # that receives no *further* segments.
  if m.isParity:
    if s.parity.hasKey(m.index):
      return (Ignored, key)
    s.parity[m.index] = m.segmentPayload
  else:
    if s.data.hasKey(m.index):
      return (Ignored, key)
    s.data[m.index] = m.segmentPayload

  s.lastUpdate = now
  return (Accepted, key)

{.pop.}
