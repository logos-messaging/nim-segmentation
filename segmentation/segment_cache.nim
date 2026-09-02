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
import ./segment_events, ./segment_message, ./segment_set

export segment_events, segment_set, monotimes, tables, times

type AddOutcome* {.pure.} = enum
  Accepted ## Stored; the set may now be reconstructible.
  Ignored ## Discarded per the spec -- duplicate, conflicting counts, or over bounds.

type SegmentCache* = ref object
  sets: Table[string, SegmentSet]
  maxSets: int
  timeout: Duration
  onSetDropped: SegmentSetDroppedHandler

func new*(
    T: type SegmentCache,
    maxSets: int,
    timeout: Duration,
    onSetDropped: SegmentSetDroppedHandler = nil,
): T =
  ## `onSetDropped` fires for every set this cache abandons: expiry, eviction and
  ## the both-classes-known bound. `nil` disables it.
  return T(
    sets: initTable[string, SegmentSet](),
    maxSets: maxSets,
    timeout: timeout,
    onSetDropped: onSetDropped,
  )

proc notifyDropped(self: SegmentCache, s: SegmentSet, reason: SegmentSetDropReason) =
  if not self.onSetDropped.isNil():
    self.onSetDropped(s.originalPayloadHash, reason)

func len*(self: SegmentCache): int =
  return self.sets.len

func get*(self: SegmentCache, key: string): SegmentSet =
  return self.sets.getOrDefault(key, nil)

func remove*(self: SegmentCache, key: string) =
  self.sets.del(key)

proc sweep*(self: SegmentCache, now: MonoTime) =
  ## Drop sets that have gone `timeout` without a new segment, notifying for each.
  var expired: seq[string]
  for key, s in self.sets:
    if now - s.lastUpdate >= self.timeout:
      expired.add(key)
  for key in expired:
    let s = self.sets.getOrDefault(key, nil)
    self.sets.del(key)
    if not s.isNil():
      self.notifyDropped(s, SegmentSetDropReason.Expired)

proc evictOldest(self: SegmentCache) =
  var oldestKey = ""
  var oldest = MonoTime.default
  var first = true
  for key, s in self.sets:
    if first or s.lastUpdate < oldest:
      oldest = s.lastUpdate
      oldestKey = key
      first = false
  if not first:
    let s = self.sets.getOrDefault(oldestKey, nil)
    self.sets.del(oldestKey)
    if not s.isNil():
      self.notifyDropped(s, SegmentSetDropReason.Evicted)

func recordCount(known: var Opt[uint32], count: uint32): bool =
  ## Fix a class count on first sight; reject a later segment that disagrees.
  if known.isSome():
    return known.unsafeGet() == count
  known = Opt.some(count)
  return true

proc add*(
    self: SegmentCache, m: SegmentMessage, maxTotalSegments: int, now: MonoTime
): tuple[outcome: AddOutcome, key: string, discardReason: Opt[SegmentDiscardReason]] =
  ## Store a segment that has already passed `isValid`.
  let key = segmentSetKey(m)

  var s = self.sets.getOrDefault(key, nil)
  if s.isNil():
    if self.sets.len >= self.maxSets:
      evictOldest(self)
    s = SegmentSet.new(m.originalPayloadHash, m.originalPayloadLength, now)
    self.sets[key] = s

  let counted =
    if m.isParity:
      recordCount(s.parityCount, m.segmentCount)
    else:
      recordCount(s.dataCount, m.segmentCount)
  if not counted:
    return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.CountMismatch))

  # Once both classes are known the whole set can be bounded, which
  # `segment_count` alone cannot do.
  if s.dataCount.isSome() and s.parityCount.isSome():
    if int(s.dataCount.unsafeGet()) + int(s.parityCount.unsafeGet()) > maxTotalSegments:
      self.sets.del(key)
      self.notifyDropped(s, SegmentSetDropReason.OverBounds)
      return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.Invalid))

  # `(is_parity, index)` is unique within a set; a repeat is ignored rather than
  # overwritten, and must not extend the set's life -- the spec expires a set
  # that receives no *further* segments.
  if m.isParity:
    if s.parity.hasKey(m.index):
      return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.Duplicate))
    s.parity[m.index] = m.segmentPayload
  else:
    if s.data.hasKey(m.index):
      return (AddOutcome.Ignored, key, Opt.some(SegmentDiscardReason.Duplicate))
    s.data[m.index] = m.segmentPayload

  s.lastUpdate = now
  return (AddOutcome.Accepted, key, Opt.none(SegmentDiscardReason))

{.pop.}
