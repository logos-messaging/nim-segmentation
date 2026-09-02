## In-memory cache of partially received segment sets.
##
## A set is keyed by `(original_payload_hash, original_payload_length)` only.
## `segment_count` is deliberately NOT part of the key: it counts one class, so
## keying on it would file a payload's data and parity segments under two
## different sets and parity recovery would never fire.
##
## This module owns storage, dedup, bounds and expiry. Hashing, Reed-Solomon and
## payload assembly live in `reconstruction`.

{.push raises: [].}

import std/[monotimes, tables, times]
import results
import ./segment_message
import ./segment_set

export segment_set, monotimes, tables, times

type AddOutcome* {.pure.} = enum
  Accepted ## Stored; the set may now be reconstructible.
  Ignored ## Discarded per the spec -- duplicate, conflicting counts, or over bounds.

type SegmentCache* = ref object
  sets: Table[string, SegmentSet]
  maxSets: int
  timeout: Duration

func new*(T: type SegmentCache, maxSets: int, timeout: Duration): T =
  return T(sets: initTable[string, SegmentSet](), maxSets: maxSets, timeout: timeout)

func len*(self: SegmentCache): int =
  return self.sets.len

func get*(self: SegmentCache, key: string): SegmentSet =
  return self.sets.getOrDefault(key, nil)

func remove*(self: SegmentCache, key: string) =
  self.sets.del(key)

func sweep*(self: SegmentCache, now: MonoTime) =
  ## Drop sets that have gone `timeout` without a new segment.
  var expired: seq[string]
  for key, s in self.sets:
    if now - s.lastUpdate >= self.timeout:
      expired.add(key)
  for key in expired:
    self.sets.del(key)

func evictOldest(self: SegmentCache) =
  var oldestKey = ""
  var oldest = MonoTime.default
  var first = true
  for key, s in self.sets:
    if first or s.lastUpdate < oldest:
      oldest = s.lastUpdate
      oldestKey = key
      first = false
  if not first:
    self.sets.del(oldestKey)

func recordCount(known: var Opt[uint32], count: uint32): bool =
  ## Fix a class count on first sight; reject a later segment that disagrees.
  if known.isSome():
    return known.unsafeGet() == count
  known = Opt.some(count)
  return true

func add*(
    self: SegmentCache, m: SegmentMessage, maxTotalSegments: int, now: MonoTime
): tuple[outcome: AddOutcome, key: string] =
  ## Store a segment that has already passed `isValid`.
  let key = segmentSetKey(m)

  var s = self.sets.getOrDefault(key, nil)
  if s.isNil():
    if self.sets.len >= self.maxSets:
      evictOldest(self)
    s = SegmentSet.new(now)
    self.sets[key] = s

  let counted =
    if m.isParity:
      recordCount(s.parityCount, m.segmentCount)
    else:
      recordCount(s.dataCount, m.segmentCount)
  if not counted:
    return (AddOutcome.Ignored, key)

  # Once both classes are known the whole set can be bounded, which
  # `segment_count` alone cannot do.
  if s.dataCount.isSome() and s.parityCount.isSome():
    if int(s.dataCount.unsafeGet()) + int(s.parityCount.unsafeGet()) > maxTotalSegments:
      self.sets.del(key)
      return (AddOutcome.Ignored, key)

  # `(is_parity, index)` is unique within a set; a repeat is ignored rather than
  # overwritten, and must not extend the set's life -- the spec expires a set
  # that receives no *further* segments.
  if m.isParity:
    if s.parity.hasKey(m.index):
      return (AddOutcome.Ignored, key)
    s.parity[m.index] = m.segmentPayload
  else:
    if s.data.hasKey(m.index):
      return (AddOutcome.Ignored, key)
    s.data[m.index] = m.segmentPayload

  s.lastUpdate = now
  return (AddOutcome.Accepted, key)

{.pop.}
